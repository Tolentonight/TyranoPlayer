import Foundation
import UIKit
import zlib

@MainActor
final class GameImporter: ObservableObject {
    @Published private(set) var games: [Game] = []
    @Published var isImporting: Bool = false
    @Published var importProgress: Double = 0.0
    @Published var importStatusText: String = "准备中…"
    @Published var errorMessage: String?
    @Published var toastMessage: String?

    private let fileManager = FileManager.default
    private let metadataFileName = "games_metadata.json"

    var gamesBaseURL: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let gamesDir = docs.appendingPathComponent("Games", isDirectory: true)
        if !fileManager.fileExists(atPath: gamesDir.path) {
            try? fileManager.createDirectory(at: gamesDir, withIntermediateDirectories: true)
        }
        return gamesDir
    }

    private var metadataURL: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(metadataFileName)
    }

    init() {
        loadMetadata()
        // 启动时自动创建一个说明文件，这样在系统「文件」App 的「我的 iPhone -> TyranoPlayer -> Games」就能立刻看到文件夹
        let readmeURL = gamesBaseURL.appendingPathComponent("把游戏文件夹放进这里.txt")
        if !fileManager.fileExists(atPath: readmeURL.path) {
            try? "你可以直接在系统「文件」App 中把解压好的 Tyrano 游戏文件夹移动或复制到本 Games 目录下，然后回到 TyranoPlayer 点击左上角刷新按钮即可秒速识别！".write(to: readmeURL, atomically: true, encoding: .utf8)
        }
        scanSandboxGamesDirectory(silentIfNone: true)
    }

    /// 直接扫描沙盒 Documents/Games/ 目录（用户在系统「文件」App 中把游戏直接放进「我的 iPhone/TyranoPlayer/Games」后无需复制即可秒导入）
    func scanSandboxGamesDirectory(silentIfNone: Bool = false) {
        guard let subdirs = try? fileManager.contentsOfDirectory(
            at: gamesBaseURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var newlyAdded = 0
        for dirURL in subdirs {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: dirURL.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let folderName = dirURL.lastPathComponent
            if games.contains(where: { $0.folderName == folderName }) { continue }

            try? Self.preprocessArchives(in: dirURL)
            if let engineDir = Self.findTyranoRootDirectory(in: dirURL) {
                let indexURL = engineDir.appendingPathComponent("index.html")
                let relEntry = Self.relativePath(from: dirURL, to: indexURL)
                let title = Self.extractHTMLTitle(from: indexURL)
                    ?? Self.extractPackageJSONTitle(in: engineDir)
                    ?? folderName
                let cover = Self.findCoverImage(in: engineDir, rootURL: dirURL)
                let newGame = Game(
                    id: UUID(),
                    title: title,
                    folderName: folderName,
                    relativeEntryPath: relEntry,
                    relativeCoverPath: cover,
                    coverUpdatedAt: Date(),
                    importedAt: Date()
                )
                games.insert(newGame, at: 0)
                newlyAdded += 1
            }
        }

        if newlyAdded > 0 {
            saveMetadata()
            showToast("从沙盒目录发现并导入了 \(newlyAdded) 款游戏！")
        } else if !silentIfNone {
            showToast("扫描完成，未在 TyranoPlayer/Games 下发现新游戏")
        }
    }

    func loadMetadata() {
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            games = []
            return
        }
        do {
            let data = try Data(contentsOf: metadataURL)
            let decoded = try JSONDecoder().decode([Game].self, from: data)
            games = decoded.filter { item in
                fileManager.fileExists(atPath: item.rootDirectoryURL(in: gamesBaseURL).path)
            }
            saveMetadata()
        } catch {
            games = []
        }
    }

    private func saveMetadata() {
        if let data = try? JSONEncoder().encode(games) {
            try? data.write(to: metadataURL, options: .atomic)
        }
    }

    func importGame(from sourceURL: URL) async {
        isImporting = true
        importProgress = 0.02
        importStatusText = "正在读取所选目录/文件…"
        errorMessage = nil
        defer { isImporting = false }

        let baseDir = gamesBaseURL

        do {
            let newItem = try await Task.detached(priority: .userInitiated) { [weak self] in
                try Self.performImport(
                    from: sourceURL,
                    gamesBaseURL: baseDir,
                    onProgress: { fraction, status in
                        Task { @MainActor [weak self] in
                            self?.importProgress = min(max(fraction, 0.0), 1.0)
                            self?.importStatusText = status
                        }
                    }
                )
            }.value

            games.insert(newItem, at: 0)
            saveMetadata()
            showToast("已导入「\(newItem.title)」")
        } catch let error as LocalizedError {
            errorMessage = error.errorDescription ?? error.localizedDescription
        } catch {
            errorMessage = "导入失败：\(error.localizedDescription)"
        }
    }

    func updateGameInfo(
        game: Game,
        newTitle: String,
        newCoverImageData: Data?,
        resetToDefaultCover: Bool
    ) {
        guard let idx = games.firstIndex(where: { $0.id == game.id }) else { return }
        var updated = games[idx]

        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            updated.title = trimmed
        }

        let rootURL = updated.rootDirectoryURL(in: gamesBaseURL)
        let customCoverName = "custom_cover.jpg"
        let customCoverURL = rootURL.appendingPathComponent(customCoverName)

        if let data = newCoverImageData, let img = UIImage(data: data), let jpeg = img.jpegData(compressionQuality: 0.85) {
            try? jpeg.write(to: customCoverURL, options: .atomic)
            updated.relativeCoverPath = customCoverName
            updated.coverUpdatedAt = Date()
        } else if resetToDefaultCover {
            try? fileManager.removeItem(at: customCoverURL)
            let engineDir = updated.engineBaseDirectoryURL(in: gamesBaseURL)
            updated.relativeCoverPath = Self.findCoverImage(in: engineDir, rootURL: rootURL)
            updated.coverUpdatedAt = Date()
        }

        games[idx] = updated
        saveMetadata()
        showToast("已更新「\(updated.title)」")
    }

    func rescanGame(_ game: Game) async {
        guard let idx = games.firstIndex(where: { $0.id == game.id }) else { return }
        isImporting = true
        importProgress = 0.1
        importStatusText = "正在重新扫描「\(game.title)」…"
        defer { isImporting = false }

        let rootURL = game.rootDirectoryURL(in: gamesBaseURL)

        do {
            let scanned = try await Task.detached(priority: .userInitiated) { [weak self] () -> (String, String?) in
                try Self.preprocessArchives(in: rootURL) { frac, msg in
                    Task { @MainActor [weak self] in
                        self?.importProgress = 0.1 + frac * 0.7
                        self?.importStatusText = msg
                    }
                }
                guard let engineDir = Self.findTyranoRootDirectory(in: rootURL) else {
                    throw GameImportError.notTyranoGame
                }
                let indexURL = engineDir.appendingPathComponent("index.html")
                let relEntry = Self.relativePath(from: rootURL, to: indexURL)
                let autoCover = Self.findCoverImage(in: engineDir, rootURL: rootURL)
                return (relEntry, autoCover)
            }.value

            var updated = games[idx]
            updated.relativeEntryPath = scanned.0
            if updated.relativeCoverPath != "custom_cover.jpg" {
                updated.relativeCoverPath = scanned.1
            }
            updated.coverUpdatedAt = Date()
            games[idx] = updated
            saveMetadata()
            showToast("重新扫描成功")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteGame(_ game: Game) {
        let dirURL = game.rootDirectoryURL(in: gamesBaseURL)
        try? fileManager.removeItem(at: dirURL)
        games.removeAll { $0.id == game.id }
        saveMetadata()
        showToast("已删除「\(game.title)」")
    }

    private func showToast(_ text: String) {
        toastMessage = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if self.toastMessage == text {
                self.toastMessage = nil
            }
        }
    }

    // MARK: - 后台导入、纯原生 ZIP / ASAR 解包与目录扫描

    nonisolated private static func performImport(
        from initialSourceURL: URL,
        gamesBaseURL: URL,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) throws -> Game {
        let fm = FileManager.default
        var sourceURL = initialSourceURL
        let hasAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { sourceURL.stopAccessingSecurityScopedResource() }
        }

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: sourceURL.path, isDirectory: &isDir) else {
            throw GameImportError.securityScopeDenied
        }

        // 如果用户点选的是游戏文件夹内部的 index.html（或任意非压缩包文件），自动向上推导父文件夹作为导入源
        let pickedExt = sourceURL.pathExtension.lowercased()
        let parentDir = sourceURL.deletingLastPathComponent()
        let parentHasAccess = parentDir.startAccessingSecurityScopedResource()
        defer {
            if parentHasAccess { parentDir.stopAccessingSecurityScopedResource() }
        }
        if !isDir.boolValue && !["zip", "nw", "asar", "7z", "rar"].contains(pickedExt) {
            sourceURL = parentDir
            isDir = ObjCBool(true)
        }

        // 如果用户选中的文件夹本身就已经在沙盒 Games 目录内，直接原地注册，免去重复拷贝
        if isDir.boolValue && sourceURL.standardizedFileURL.path.hasPrefix(gamesBaseURL.standardizedFileURL.path + "/") {
            onProgress(0.4, "检测到已在沙盒目录内，正在直接注册…")
            try? preprocessArchives(in: sourceURL, onProgress: onProgress)
            guard let engineDir = findTyranoRootDirectory(in: sourceURL) else {
                throw GameImportError.notTyranoGame
            }
            let indexURL = engineDir.appendingPathComponent("index.html")
            let relEntry = relativePath(from: sourceURL, to: indexURL)
            let title = extractHTMLTitle(from: indexURL)
                ?? extractPackageJSONTitle(in: engineDir)
                ?? sourceURL.lastPathComponent
            let cover = findCoverImage(in: engineDir, rootURL: sourceURL)
            onProgress(1.0, "导入完成！")
            return Game(
                id: UUID(),
                title: title,
                folderName: sourceURL.lastPathComponent,
                relativeEntryPath: relEntry,
                relativeCoverPath: cover,
                coverUpdatedAt: Date(),
                importedAt: Date()
            )
        }

        let gameUUID = UUID()
        let folderName = gameUUID.uuidString
        let destinationRootURL = gamesBaseURL.appendingPathComponent(folderName, isDirectory: true)
        try? fm.removeItem(at: destinationRootURL)

        let rawTitle = sourceURL.deletingPathExtension().lastPathComponent

        if isDir.boolValue {
            onProgress(0.05, "正在复制游戏文件夹…")
            try copyDirectoryWithProgress(from: sourceURL, to: destinationRootURL) { frac, msg in
                onProgress(0.05 + frac * 0.60, msg)
            }
        } else {
            let ext = sourceURL.pathExtension.lowercased()
            switch ext {
            case "zip", "nw":
                try NativeZipExtractor.extract(zipURL: sourceURL, to: destinationRootURL) { frac, msg in
                    onProgress(0.05 + frac * 0.60, msg)
                }
            case "asar":
                try NativeAsarExtractor.extract(asarURL: sourceURL, to: destinationRootURL) { frac, msg in
                    onProgress(0.05 + frac * 0.60, msg)
                }
            default:
                throw GameImportError.unsupportedArchiveFormat(ext.isEmpty ? "未知文件" : ext)
            }
        }

        onProgress(0.68, "正在检查 TyranoScript 结构…")
        var validEngineDir = findTyranoRootDirectory(in: destinationRootURL)
        if validEngineDir == nil {
            do {
                try preprocessArchives(in: destinationRootURL) { frac, msg in
                    onProgress(0.68 + frac * 0.22, msg)
                }
            } catch {
                try? fm.removeItem(at: destinationRootURL)
                throw error
            }
            validEngineDir = findTyranoRootDirectory(in: destinationRootURL)
        }

        guard let engineDir = validEngineDir else {
            try? fm.removeItem(at: destinationRootURL)
            throw GameImportError.notTyranoGame
        }

        onProgress(0.94, "正在读取标题与封面…")
        let indexURL = engineDir.appendingPathComponent("index.html")
        let relativeEntryPath = relativePath(from: destinationRootURL, to: indexURL)
        let detectedTitle = extractHTMLTitle(from: indexURL)
            ?? extractPackageJSONTitle(in: engineDir)
            ?? rawTitle
        let coverRelativePath = findCoverImage(in: engineDir, rootURL: destinationRootURL)

        onProgress(1.0, "导入完成！")
        return Game(
            id: gameUUID,
            title: detectedTitle.isEmpty ? rawTitle : detectedTitle,
            folderName: folderName,
            relativeEntryPath: relativeEntryPath,
            relativeCoverPath: coverRelativePath,
            coverUpdatedAt: Date(),
            importedAt: Date()
        )
    }

    nonisolated private static func copyDirectoryWithProgress(
        from sourceRootURL: URL,
        to destinationRootURL: URL,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) throws {
        let fm = FileManager.default
        guard let countEnum = fm.enumerator(at: sourceRootURL, includingPropertiesForKeys: nil) else {
            try fm.copyItem(at: sourceRootURL, to: destinationRootURL)
            return
        }
        var allItems: [URL] = []
        for case let url as URL in countEnum {
            allItems.append(url)
        }
        let total = max(1, allItems.count)
        try fm.createDirectory(at: destinationRootURL, withIntermediateDirectories: true)

        for (idx, itemURL) in allItems.enumerated() {
            let relPath = relativePath(from: sourceRootURL, to: itemURL)
            guard !relPath.isEmpty else { continue }
            let targetURL = destinationRootURL.appendingPathComponent(relPath)

            var isDir: ObjCBool = false
            if fm.fileExists(atPath: itemURL.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    try fm.createDirectory(at: targetURL, withIntermediateDirectories: true)
                } else {
                    try fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? fm.removeItem(at: targetURL)
                    try fm.copyItem(at: itemURL, to: targetURL)
                }
            }
            if idx % 15 == 0 || idx + 1 == total {
                onProgress(Double(idx + 1) / Double(total), "正在复制 (\(idx + 1)/\(total))…")
            }
        }
    }

    nonisolated private static func preprocessArchives(
        in rootURL: URL,
        onProgress: (@Sendable (Double, String) -> Void)? = nil
    ) throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }

        var asarFiles: [URL] = []
        var nwFiles: [URL] = []

        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent == "__MACOSX" {
                enumerator.skipDescendants()
                continue
            }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fileURL.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            let ext = fileURL.pathExtension.lowercased()
            let name = fileURL.lastPathComponent.lowercased()
            if ext == "asar" {
                asarFiles.append(fileURL)
            } else if name == "package.nw" || ext == "nw" {
                nwFiles.append(fileURL)
            }
        }

        for asarURL in asarFiles {
            let extractDir = asarURL.deletingLastPathComponent()
                .appendingPathComponent("asar_extracted_\(asarURL.deletingPathExtension().lastPathComponent)", isDirectory: true)
            try? fm.removeItem(at: extractDir)
            try NativeAsarExtractor.extract(asarURL: asarURL, to: extractDir, onProgress: onProgress)
            try? fm.removeItem(at: asarURL)
        }

        for nwURL in nwFiles {
            let extractDir = nwURL.deletingLastPathComponent().appendingPathComponent("nw_extracted", isDirectory: true)
            try? fm.removeItem(at: extractDir)
            try NativeZipExtractor.extract(zipURL: nwURL, to: extractDir, onProgress: onProgress)
            try? fm.removeItem(at: nwURL)
        }
    }

    nonisolated private static func findTyranoRootDirectory(in rootURL: URL) -> URL? {
        let fm = FileManager.default
        func isTyranoDirectory(_ dirURL: URL) -> Bool {
            let indexPath = dirURL.appendingPathComponent("index.html").path
            var isTyranoDir: ObjCBool = false
            let tyranoPath = dirURL.appendingPathComponent("tyrano").path
            return fm.fileExists(atPath: indexPath)
                && fm.fileExists(atPath: tyranoPath, isDirectory: &isTyranoDir)
                && isTyranoDir.boolValue
        }

        if isTyranoDirectory(rootURL) { return rootURL }
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }

        for case let candidateURL as URL in enumerator {
            if candidateURL.lastPathComponent == "__MACOSX" {
                enumerator.skipDescendants()
                continue
            }
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidateURL.path, isDirectory: &isDir), isDir.boolValue, isTyranoDirectory(candidateURL) {
                return candidateURL
            }
        }
        return nil
    }

    nonisolated private static func extractHTMLTitle(from indexURL: URL) -> String? {
        guard let html = try? String(contentsOf: indexURL, encoding: .utf8),
              let start = html.range(of: "<title>", options: .caseInsensitive),
              let end = html.range(of: "</title>", options: .caseInsensitive, range: start.upperBound..<html.endIndex) else {
            return nil
        }
        let title = String(html[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty || ["tyranoscript", "document", "loading"].contains(title.lowercased()) {
            return nil
        }
        return title
    }

    nonisolated private static func extractPackageJSONTitle(in engineDir: URL) -> String? {
        let pkgURL = engineDir.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: pkgURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let win = json["window"] as? [String: Any], let t = win["title"] as? String, !t.isEmpty {
            return t
        }
        if let name = json["productName"] as? String ?? json["name"] as? String, !name.isEmpty, name.lowercased() != "tyranoscript" {
            return name
        }
        return nil
    }

    nonisolated private static func findCoverImage(in engineDir: URL, rootURL: URL) -> String? {
        let candidates = [
            "icon.png", "cover.png", "cover.jpg",
            "data/bgimage/title.jpg", "data/bgimage/title.png",
            "data/image/title.png", "data/image/title.jpg"
        ]
        for candidate in candidates {
            let fileURL = engineDir.appendingPathComponent(candidate)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                return relativePath(from: rootURL, to: fileURL)
            }
        }
        return nil
    }

    nonisolated private static func relativePath(from base: URL, to target: URL) -> String {
        let baseComps = base.standardizedFileURL.pathComponents
        let targetComps = target.standardizedFileURL.pathComponents
        let common = zip(baseComps, targetComps).prefix(while: { $0 == $1 }).count
        return targetComps.dropFirst(common).joined(separator: "/")
    }
}

// MARK: - 零第三方依赖：纯 Swift + 系统 zlib 原生 ZIP 解压器（免 SPM 外部包编译烦恼）

enum NativeZipExtractor {
    nonisolated static func extract(
        zipURL: URL,
        to destinationURL: URL,
        onProgress: (@Sendable (Double, String) -> Void)? = nil
    ) throws {
        let fm = FileManager.default
        let data = try Data(contentsOf: zipURL, options: .mappedIfSafe)
        try fm.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        // 查找 End of Central Directory (EOCD: 0x06054b50)
        guard data.count >= 22 else {
            throw GameImportError.unzipFailed("无效的 ZIP 文件")
        }
        let maxComment = min(data.count - 22, 65535)
        var eocdOffset: Int?
        for back in 0...maxComment {
            let pos = data.count - 22 - back
            if readUInt32(data, at: pos) == 0x06054b50 {
                eocdOffset = pos
                break
            }
        }
        guard let eocd = eocdOffset else {
            throw GameImportError.unzipFailed("未找到 ZIP 中央目录结束标记")
        }

        let totalEntries = Int(readUInt16(data, at: eocd + 10))
        let cdOffset = Int(readUInt32(data, at: eocd + 16))
        var cursor = cdOffset

        for index in 0..<max(1, totalEntries) {
            guard cursor + 46 <= data.count, readUInt32(data, at: cursor) == 0x02014b50 else { break }

            let compressionMethod = readUInt16(data, at: cursor + 10)
            let compressedSize = Int(readUInt32(data, at: cursor + 20))
            let uncompressedSize = Int(readUInt32(data, at: cursor + 24))
            let nameLen = Int(readUInt16(data, at: cursor + 28))
            let extraLen = Int(readUInt16(data, at: cursor + 30))
            let commentLen = Int(readUInt16(data, at: cursor + 32))
            let localHeaderOffset = Int(readUInt32(data, at: cursor + 42))

            let nameRange = (cursor + 46)..<(cursor + 46 + nameLen)
            guard nameRange.upperBound <= data.count else { break }
            let entryName = String(data: data.subdata(in: nameRange), encoding: .utf8)
                ?? String(data: data.subdata(in: nameRange), encoding: .isoLatin1)
                ?? "file_\(index)"

            cursor += 46 + nameLen + extraLen + commentLen

            // 跳过 __MACOSX 与目录穿越
            if entryName.hasPrefix("__MACOSX/") || entryName.contains("..") {
                continue
            }

            let outURL = destinationURL.appendingPathComponent(entryName)
            if entryName.hasSuffix("/") {
                try fm.createDirectory(at: outURL, withIntermediateDirectories: true)
                continue
            }

            guard localHeaderOffset + 30 <= data.count,
                  readUInt32(data, at: localHeaderOffset) == 0x04034b50 else {
                continue
            }
            let localNameLen = Int(readUInt16(data, at: localHeaderOffset + 26))
            let localExtraLen = Int(readUInt16(data, at: localHeaderOffset + 28))
            let payloadStart = localHeaderOffset + 30 + localNameLen + localExtraLen
            let payloadEnd = payloadStart + compressedSize
            guard payloadEnd <= data.count else { continue }

            try fm.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let compressedSlice = data.subdata(in: payloadStart..<payloadEnd)

            if compressionMethod == 0 {
                try compressedSlice.write(to: outURL)
            } else if compressionMethod == 8 {
                let decompressed = try inflateRawDeflate(compressedSlice, expectedSize: uncompressedSize)
                try decompressed.write(to: outURL)
            } else {
                throw GameImportError.unzipFailed("不支持的 ZIP 压缩算法 (\(compressionMethod))")
            }

            if index % 15 == 0 || index + 1 == totalEntries {
                let frac = Double(index + 1) / Double(max(1, totalEntries))
                onProgress?(frac, "正在解压 ZIP (\(index + 1)/\(totalEntries))…")
            }
        }
    }

    nonisolated private static func inflateRawDeflate(_ input: Data, expectedSize: Int) throws -> Data {
        if input.isEmpty { return Data() }
        var stream = z_stream()
        let status = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else {
            throw GameImportError.unzipFailed("zlib 初始化失败")
        }
        defer { inflateEnd(&stream) }

        let capacity = max(expectedSize, input.count * 2, 4096)
        var output = Data(count: capacity)
        var totalOut = 0

        try input.withUnsafeBytes { rawInput in
            guard let baseIn = rawInput.bindMemory(to: Bytef.self).baseAddress else { return }
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: baseIn)
            stream.avail_in = uInt(input.count)

            while true {
                if totalOut >= output.count {
                    output.count += max(input.count, 65536)
                }
                let outCount = output.count
                let res: Int32 = output.withUnsafeMutableBytes { rawOutput in
                    let baseOut = rawOutput.bindMemory(to: Bytef.self).baseAddress!
                    stream.next_out = baseOut.advanced(by: totalOut)
                    stream.avail_out = uInt(outCount - totalOut)
                    return zlib.inflate(&stream, Z_SYNC_FLUSH)
                }
                totalOut = Int(stream.total_out)
                if res == Z_STREAM_END { break }
                if res != Z_OK && res != Z_BUF_ERROR {
                    throw GameImportError.unzipFailed("zlib 解压数据损坏 (\(res))")
                }
                if stream.avail_in == 0 && stream.avail_out > 0 { break }
            }
        }
        output.count = totalOut
        return output
    }

    nonisolated private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self).littleEndian }
    }

    nonisolated private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian }
    }
}

// MARK: - 零第三方依赖：纯 Swift Electron app.asar 解包器

enum NativeAsarExtractor {
    nonisolated static func extract(
        asarURL: URL,
        to destinationURL: URL,
        onProgress: (@Sendable (Double, String) -> Void)? = nil
    ) throws {
        let fm = FileManager.default
        let handle = try FileHandle(forReadingFrom: asarURL)
        defer { try? handle.close() }

        guard let prefixData = try handle.read(upToCount: 16), prefixData.count == 16 else {
            throw GameImportError.asarExtractionFailed("头部不足 16 字节")
        }

        let headerSizePickle = prefixData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian }
        let headerSize = prefixData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian }
        let jsonSize = prefixData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self).littleEndian }

        guard headerSizePickle == 4, jsonSize > 0, jsonSize <= 100_000_000 else {
            throw GameImportError.asarExtractionFailed("非标准或已加密的 ASAR 头")
        }

        guard let jsonData = try handle.read(upToCount: Int(jsonSize)),
              let rootDict = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw GameImportError.asarExtractionFailed("无法解析 ASAR JSON 目录树")
        }

        let totalFiles = max(1, countFiles(in: rootDict))
        var extracted = 0
        let payloadBaseOffset = UInt64(8) + UInt64(headerSize)
        try fm.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        try extractNode(
            node: rootDict,
            currentURL: destinationURL,
            fileHandle: handle,
            payloadBaseOffset: payloadBaseOffset,
            totalFiles: totalFiles,
            extractedFiles: &extracted,
            onProgress: onProgress
        )
    }

    nonisolated private static func countFiles(in node: [String: Any]) -> Int {
        if let files = node["files"] as? [String: Any] {
            return files.values.compactMap { $0 as? [String: Any] }.reduce(0) { $0 + countFiles(in: $1) }
        }
        return 1
    }

    nonisolated private static func extractNode(
        node: [String: Any],
        currentURL: URL,
        fileHandle: FileHandle,
        payloadBaseOffset: UInt64,
        totalFiles: Int,
        extractedFiles: inout Int,
        onProgress: (@Sendable (Double, String) -> Void)?
    ) throws {
        let fm = FileManager.default
        if let files = node["files"] as? [String: Any] {
            try fm.createDirectory(at: currentURL, withIntermediateDirectories: true)
            for (name, val) in files {
                guard let child = val as? [String: Any] else { continue }
                try extractNode(
                    node: child,
                    currentURL: currentURL.appendingPathComponent(name),
                    fileHandle: fileHandle,
                    payloadBaseOffset: payloadBaseOffset,
                    totalFiles: totalFiles,
                    extractedFiles: &extractedFiles,
                    onProgress: onProgress
                )
            }
            return
        }

        defer {
            extractedFiles += 1
            if extractedFiles % 15 == 0 || extractedFiles == totalFiles {
                onProgress?(Double(extractedFiles) / Double(totalFiles), "正在解包 ASAR (\(extractedFiles)/\(totalFiles))…")
            }
        }

        guard let sizeVal = parseUInt64(node["size"]),
              let offsetVal = parseUInt64(node["offset"]) else { return }

        try fm.createDirectory(at: currentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: currentURL.path, contents: nil)
        guard sizeVal > 0 else { return }

        let outHandle = try FileHandle(forWritingTo: currentURL)
        defer { try? outHandle.close() }

        try fileHandle.seek(toOffset: payloadBaseOffset + offsetVal)
        var remaining = Int(sizeVal)
        while remaining > 0 {
            let chunkLen = min(1_048_576, remaining)
            guard let chunk = try fileHandle.read(upToCount: chunkLen), !chunk.isEmpty else { break }
            try outHandle.write(contentsOf: chunk)
            remaining -= chunk.count
        }
    }

    nonisolated private static func parseUInt64(_ raw: Any?) -> UInt64? {
        if let s = raw as? String { return UInt64(s) }
        if let n = raw as? NSNumber { return n.uint64Value }
        if let i = raw as? Int, i >= 0 { return UInt64(i) }
        return nil
    }
}
