
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



    var backupsBaseURL: URL {

        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]

        let backupsDir = docs.appendingPathComponent("Backups", isDirectory: true)

        if !fileManager.fileExists(atPath: backupsDir.path) {

            try? fileManager.createDirectory(at: backupsDir, withIntermediateDirectories: true)

        }

        return backupsDir

    }



    private var metadataURL: URL {

        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]

        return docs.appendingPathComponent(metadataFileName)

    }



    init() {

        loadMetadata()

        let readmeURL = gamesBaseURL.appendingPathComponent("把游戏文件夹放进这里.txt")

        if !fileManager.fileExists(atPath: readmeURL.path) {

            try? "你可以直接在系统「文件」App 中把解压好的 Tyrano 游戏文件夹移动或复制到本 Games 目录下，然后回到 TyranoPlayer 点击左上角刷新按钮即可秒速识别！".write(to: readmeURL, atomically: true, encoding: .utf8)

        }

        _ = backupsBaseURL

        scanSandboxGamesDirectory(silentIfNone: true)

    }



    // MARK: - 存档统计、本地备份导出与恢复



    func saveEntryCount(for game: Game) -> Int {

        let storeURL = game.nativeSaveStoreURL(in: gamesBaseURL)

        guard let data = try? Data(contentsOf: storeURL),

              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {

            return 0

        }

        return dict.count

    }



    func exportSaveBackup(for game: Game) -> URL? {

        let storeURL = game.nativeSaveStoreURL(in: gamesBaseURL)

        var entries: [String: String] = [:]

        if let data = try? Data(contentsOf: storeURL),

           let loaded = try? JSONSerialization.jsonObject(with: data) as? [String: String] {

            entries = loaded

        }



        // 仅导出当前游戏独立沙盒内的原生持久化存档，不读取原包内残留的 Windows .sav/.dat 文件



        let package = SaveBackupPackage(

            schemaVersion: 1,

            gameTitle: game.title,

            gameFolderName: game.folderName,

            exportedAt: Date(),

            storageEntries: entries

        )



        let df = DateFormatter()

        df.dateFormat = "yyyyMMdd_HHmmss"

        let safeTitle = game.title.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")

        let fileName = "\(safeTitle)_存档备份_\(df.string(from: Date())).tyranosave.json"

        let outURL = backupsBaseURL.appendingPathComponent(fileName)



        do {

            let encoder = JSONEncoder()

            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

            let data = try encoder.encode(package)

            try data.write(to: outURL, options: .atomic)

            AppLogger.shared.append(level: .log, category: "BACKUP", message: "已导出「\(game.title)」存档备份: \(outURL.lastPathComponent) (共 \(entries.count) 项)")

            showToast("存档已备份至 Backups 目录！")

            return outURL

        } catch {

            AppLogger.shared.append(level: .error, category: "BACKUP", message: "导出存档失败: \(error.localizedDescription)")

            errorMessage = "导出存档备份失败：\(error.localizedDescription)"

            return nil

        }

    }



    func restoreSaveBackup(from backupURL: URL, for game: Game) {

        let hasAccess = backupURL.startAccessingSecurityScopedResource()

        defer { if hasAccess { backupURL.stopAccessingSecurityScopedResource() } }



        do {

            let data = try Data(contentsOf: backupURL)

            var restoredEntries: [String: String] = [:]



            if let pkg = try? JSONDecoder().decode(SaveBackupPackage.self, from: data) {

                restoredEntries = pkg.storageEntries

            } else if let rawDict = try JSONSerialization.jsonObject(with: data) as? [String: String] {

                restoredEntries = rawDict

            } else {

                throw GameImportError.backupRestoreFailed("无法识别的存档备份文件格式")

            }



            let storeURL = game.nativeSaveStoreURL(in: gamesBaseURL)

            let serialized = try JSONSerialization.data(withJSONObject: restoredEntries, options: [.prettyPrinted])

            try serialized.write(to: storeURL, options: .atomic)



            // 恢复的存档统一保存在独立 Saves/tyrano_saves.json 中，保持游戏原包目录只读



            objectWillChange.send()

            AppLogger.shared.append(level: .log, category: "BACKUP", message: "已恢复「\(game.title)」存档备份 (\(restoredEntries.count) 项)")

            showToast("成功恢复 \(restoredEntries.count) 项存档数据！")

        } catch {

            AppLogger.shared.append(level: .error, category: "BACKUP", message: "恢复存档失败: \(error.localizedDescription)")

            errorMessage = "恢复存档失败：\(error.localizedDescription)"

        }

    }



    /// 直接扫描沙盒 Documents/Games/ 目录

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

                Self.initializeCleanSaveStoreIfNeeded(for: newGame, in: gamesBaseURL)

                games.insert(newGame, at: 0)

                newlyAdded += 1

                AppLogger.shared.append(level: .log, category: "SCAN", message: "从沙盒发现游戏: \(title) (\(relEntry))")

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

        AppLogger.shared.append(level: .log, category: "IMPORT", message: "开始导入: \(sourceURL.path)")



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

            AppLogger.shared.append(level: .log, category: "IMPORT", message: "导入成功: \(newItem.title) -> \(newItem.relativeEntryPath)")

            showToast("已导入「\(newItem.title)」")

        } catch let error as LocalizedError {

            let msg = error.errorDescription ?? error.localizedDescription

            AppLogger.shared.append(level: .error, category: "IMPORT", message: msg)

            errorMessage = msg

        } catch {

            AppLogger.shared.append(level: .error, category: "IMPORT", message: error.localizedDescription)

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

            Self.initializeCleanSaveStoreIfNeeded(for: updated, in: gamesBaseURL)

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

        AppLogger.shared.append(level: .log, category: "LIBRARY", message: "已删除游戏: \(game.title)")

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



    // MARK: - 后台导入、全新独立存档初始化与安全校验



    /// 初始化全新的独立存档空间（不迁移任何不兼容的 Windows 版 savedata/.sav/.dat 旧存档，防止乱码与崩溃）

    nonisolated private static func initializeCleanSaveStoreIfNeeded(for game: Game, in gamesBaseURL: URL) {

        let fm = FileManager.default

        let storeURL = game.nativeSaveStoreURL(in: gamesBaseURL)

        if !fm.fileExists(atPath: storeURL.path) {

            try? "{}".data(using: .utf8)?.write(to: storeURL, options: .atomic)

        }

    }



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



        let pickedExt = sourceURL.pathExtension.lowercased()

        let parentDir = sourceURL.deletingLastPathComponent()

        let parentHasAccess = parentDir.startAccessingSecurityScopedResource()

        defer {

            if parentHasAccess { parentDir.stopAccessingSecurityScopedResource() }

        }

        if !isDir.boolValue && !["zip", "nw", "asar", "exe", "7z", "rar"].contains(pickedExt) {

            sourceURL = parentDir

            isDir = ObjCBool(true)

        }



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

            let game = Game(

                id: UUID(),

                title: title,

                folderName: sourceURL.lastPathComponent,

                relativeEntryPath: relEntry,

                relativeCoverPath: cover,

                coverUpdatedAt: Date(),

                importedAt: Date()

            )

            initializeCleanSaveStoreIfNeeded(for: game, in: gamesBaseURL)

            onProgress(1.0, "导入完成！")

            return game

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

            case "exe":

                try SecurityValidator.validatePEExecutableHeader(at: sourceURL)

                if (try? NativeZipExtractor.extract(zipURL: sourceURL, to: destinationRootURL, onProgress: { frac, msg in

                    onProgress(0.05 + frac * 0.60, msg)

                })) == nil {

                    try NativeAsarExtractor.extractEmbeddedAsar(from: sourceURL, to: destinationRootURL) { frac, msg in

                        onProgress(0.05 + frac * 0.60, msg)

                    }

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



        onProgress(0.94, "正在读取标题、封面与初始存档…")

        let indexURL = engineDir.appendingPathComponent("index.html")

        let relativeEntryPath = relativePath(from: destinationRootURL, to: indexURL)

        let detectedTitle = extractHTMLTitle(from: indexURL)

            ?? extractPackageJSONTitle(in: engineDir)

            ?? rawTitle

        let coverRelativePath = findCoverImage(in: engineDir, rootURL: destinationRootURL)



        let game = Game(

            id: gameUUID,

            title: detectedTitle.isEmpty ? rawTitle : detectedTitle,

            folderName: folderName,

            relativeEntryPath: relativeEntryPath,

            relativeCoverPath: coverRelativePath,

            coverUpdatedAt: Date(),

            importedAt: Date()

        )

        initializeCleanSaveStoreIfNeeded(for: game, in: gamesBaseURL)

        onProgress(1.0, "导入完成！")

        return game

    }



    /// 判断某个相对路径是否为 Windows 专属运行库、可执行脚本或旧版不兼容存档（导入时自动过滤，保持核心数据纯净安全）

    nonisolated static func isWindowsRuntimeBloat(relativePath: String, isDirectory: Bool) -> Bool {

        let lower = relativePath.lowercased()

        let components = lower.split(separator: "/").map(String.init)

        let ignoredDirs: Set<String> = [

            "locales", "swiftshader", "pnacl", "pepperflash", "__macosx", "crashpad", "savedata"

        ]

        if components.contains(where: { ignoredDirs.contains($0) }) {

            return true

        }

        if isDirectory { return false }



        let fileName = components.last ?? lower

        let ext = (fileName as NSString).pathExtension.lowercased()

        // 拦截 Windows 二进制库、可执行木马/脚本扩展名、以及不兼容的 PC 本地存档 (.sav / .dat)

        let ignoredExts: Set<String> = [

            "dll", "pak", "pdb", "lib", "exp", "obj", "ilk", "msi", "bat", "cmd",

            "vbs", "wsf", "ps1", "hta", "scr", "pif", "com", "jar", "reg", "lnk",

            "dylib", "so", "sh", "command", "sav", "dat"

        ]

        if ignoredExts.contains(ext) { return true }



        let ignoredExactFiles: Set<String> = [

            "icudtl.dat", "natives_blob.bin", "snapshot_blob.bin", "v8_context_snapshot.bin",

            "chrome_100_percent.pak", "chrome_200_percent.pak", "resources.pak", "nw_100_percent.pak",

            "nw_200_percent.pak", "credits.html", "license", "licenseselectron.txt", "version"

        ]

        if ignoredExactFiles.contains(fileName) { return true }

        return false

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



            var isDir: ObjCBool = false

            guard fm.fileExists(atPath: itemURL.path, isDirectory: &isDir) else { continue }



            // 自动跳过 Windows 专属 DLL/PAK、可疑可执行脚本与旧版 savedata，只拷贝核心游戏数据且不修改原文件

            if isWindowsRuntimeBloat(relativePath: relPath, isDirectory: isDir.boolValue) {

                continue

            }



            let targetURL = destinationRootURL.appendingPathComponent(relPath)

            if isDir.boolValue {

                try fm.createDirectory(at: targetURL, withIntermediateDirectories: true)

            } else {

                try fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)

                try? fm.removeItem(at: targetURL)

                try fm.copyItem(at: itemURL, to: targetURL)

            }

            if idx % 15 == 0 || idx + 1 == total {

                onProgress(Double(idx + 1) / Double(total), "正在安全校验并复制核心文件 (\(idx + 1)/\(total))…")

            }

        }

    }



    /// 识别并解包公开标准格式的 app.asar / package.nw / NW.js 单文件 .exe（原包文件保持只读，不写回修改原文件）

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

        var exeFiles: [URL] = []

        var bloatFiles: [URL] = []



        for case let fileURL as URL in enumerator {

            if fileURL.lastPathComponent == "__MACOSX" {

                enumerator.skipDescendants()

                continue

            }

            var isDir: ObjCBool = false

            guard fm.fileExists(atPath: fileURL.path, isDirectory: &isDir) else { continue }

            let relPath = relativePath(from: rootURL, to: fileURL)

            if isWindowsRuntimeBloat(relativePath: relPath, isDirectory: isDir.boolValue) {

                bloatFiles.append(fileURL)

                if isDir.boolValue { enumerator.skipDescendants() }

                continue

            }

            guard !isDir.boolValue else { continue }

            let ext = fileURL.pathExtension.lowercased()

            let name = fileURL.lastPathComponent.lowercased()

            if ext == "asar" {

                asarFiles.append(fileURL)

            } else if name == "package.nw" || ext == "nw" {

                nwFiles.append(fileURL)

            } else if ext == "exe" {

                exeFiles.append(fileURL)

            }

        }



        // 清理已混入的 Windows 运行库与旧存档文件

        for bloatURL in bloatFiles {

            try? fm.removeItem(at: bloatURL)

        }



        // 1. 解包公开标准格式的 app.asar 到独立缓存目录

        for asarURL in asarFiles {

            let extractDir = asarURL.deletingLastPathComponent()

                .appendingPathComponent("asar_extracted_\(asarURL.deletingPathExtension().lastPathComponent)", isDirectory: true)

            if !fm.fileExists(atPath: extractDir.path) {

                try NativeAsarExtractor.extract(asarURL: asarURL, to: extractDir, onProgress: onProgress)

            }

            try? fm.removeItem(at: asarURL)

        }



        // 2. 解包公开标准格式的 NW.js package.nw 到独立缓存目录

        for nwURL in nwFiles {

            let extractDir = nwURL.deletingLastPathComponent().appendingPathComponent("nw_extracted", isDirectory: true)

            if !fm.fileExists(atPath: extractDir.path) {

                try NativeZipExtractor.extract(zipURL: nwURL, to: extractDir, onProgress: onProgress)

            }

            try? fm.removeItem(at: nwURL)

        }



        // 3. 若当前目录尚未找到 index.html + tyrano，经 PE 魔数与大小校验后检测单文件 .exe 是否内嵌公开格式的 package.nw 或 ASAR

        if findTyranoRootDirectory(in: rootURL) == nil {

            for exeURL in exeFiles {

                try SecurityValidator.validatePEExecutableHeader(at: exeURL)

                onProgress?(0.5, "正在校验并提取标准封装 EXE: \(exeURL.lastPathComponent)…")

                let extractDir = exeURL.deletingLastPathComponent()

                    .appendingPathComponent("exe_unpacked_\(exeURL.deletingPathExtension().lastPathComponent)", isDirectory: true)

                if (try? NativeZipExtractor.extract(zipURL: exeURL, to: extractDir, onProgress: onProgress)) != nil,

                   findTyranoRootDirectory(in: extractDir) != nil {

                    try? fm.removeItem(at: exeURL)

                    break

                } else if (try? NativeAsarExtractor.extractEmbeddedAsar(from: exeURL, to: extractDir, onProgress: onProgress)) != nil,

                          findTyranoRootDirectory(in: extractDir) != nil {

                    try? fm.removeItem(at: exeURL)

                    break

                } else {

                    try? fm.removeItem(at: extractDir)

                }

            }

        }



        // 清理所有 .exe 二进制可执行文件，严禁任何可执行程序留在沙盒内

        for exeURL in exeFiles {

            try? fm.removeItem(at: exeURL)

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



// MARK: - 导入包安全校验器（魔数签名、大小上限、防解压炸弹与危险载荷拦截）



enum SecurityValidator {

    static let maxArchiveFileSize: UInt64 = 4_294_967_296       // 单个归档上限 4 GB

    static let maxSingleEntrySize: UInt64 = 1_610_612_736       // 单个解压文件上限 1.5 GB

    static let maxTotalExtractedBytes: UInt64 = 4_294_967_296   // 累计解压上限 4 GB



    nonisolated static func validateFileSize(at url: URL) throws -> UInt64 {

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)

        let size = (attrs[.size] as? UInt64) ?? 0

        guard size > 0 else {

            throw GameImportError.securityValidationFailed("文件大小为 0 字节")

        }

        guard size <= maxArchiveFileSize else {

            throw GameImportError.securityValidationFailed("归档体积超过 4GB 安全上限")

        }

        return size

    }



    nonisolated static func validatePEExecutableHeader(at exeURL: URL) throws {

        _ = try validateFileSize(at: exeURL)

        let handle = try FileHandle(forReadingFrom: exeURL)

        defer { try? handle.close() }

        guard let magic = try handle.read(upToCount: 2), magic.count == 2,

              magic[0] == 0x4D, magic[1] == 0x5A else { // "MZ"

            throw GameImportError.securityValidationFailed("非法的 PE (MZ) 文件头签名")

        }

    }



    nonisolated static func isSafeRelativeEntryPath(_ path: String) -> Bool {

        if path.isEmpty || path.hasPrefix("/") || path.hasPrefix("\\") { return false }

        let comps = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/")

        if comps.contains("..") { return false }

        return true

    }

}



// MARK: - 零第三方依赖：纯 Swift + 系统 zlib 原生 ZIP 解压器（含魔数校验、防炸弹与加密包识别）



enum NativeZipExtractor {

    nonisolated static func extract(

        zipURL: URL,

        to destinationURL: URL,

        onProgress: (@Sendable (Double, String) -> Void)? = nil

    ) throws {

        _ = try SecurityValidator.validateFileSize(at: zipURL)

        let fm = FileManager.default

        let data = try Data(contentsOf: zipURL, options: .mappedIfSafe)

        try fm.createDirectory(at: destinationURL, withIntermediateDirectories: true)



        guard data.count >= 22 else {

            throw GameImportError.unzipFailed("无效的 ZIP 文件（长度不足）")

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

            throw GameImportError.unzipFailed("未找到标准 ZIP 中央目录签名 (0x06054b50)")

        }



        let totalEntries = Int(readUInt16(data, at: eocd + 10))

        let cdOffset = Int(readUInt32(data, at: eocd + 16))

        var cursor = cdOffset

        var cumulativeExtractedBytes: UInt64 = 0



        for index in 0..<max(1, totalEntries) {

            guard cursor + 46 <= data.count, readUInt32(data, at: cursor) == 0x02014b50 else { break }



            let generalPurposeFlags = readUInt16(data, at: cursor + 8)

            let compressionMethod = readUInt16(data, at: cursor + 10)

            let compressedSize = Int(readUInt32(data, at: cursor + 20))

            let uncompressedSize = Int(readUInt32(data, at: cursor + 24))

            let nameLen = Int(readUInt16(data, at: cursor + 28))

            let extraLen = Int(readUInt16(data, at: cursor + 30))

            let commentLen = Int(readUInt16(data, at: cursor + 32))

            let localHeaderOffset = Int(readUInt32(data, at: cursor + 42))



            // 拒绝加密的 ZIP 条目（不内置通用密码爆破）

            if (generalPurposeFlags & 0x0001) != 0 {

                throw GameImportError.encryptedArchiveNotSupported("ZIP 归档受密码加密保护")

            }



            let nameRange = (cursor + 46)..<(cursor + 46 + nameLen)

            guard nameRange.upperBound <= data.count else { break }

            let entryName = String(data: data.subdata(in: nameRange), encoding: .utf8)

                ?? String(data: data.subdata(in: nameRange), encoding: .shiftJIS)

                ?? String(data: data.subdata(in: nameRange), encoding: .isoLatin1)

                ?? "file_\(index)"



            cursor += 46 + nameLen + extraLen + commentLen



            if entryName.hasPrefix("__MACOSX/") || !SecurityValidator.isSafeRelativeEntryPath(entryName) {

                continue

            }

            if GameImporter.isWindowsRuntimeBloat(relativePath: entryName, isDirectory: entryName.hasSuffix("/")) {

                continue

            }



            // 防解压炸弹校验

            if UInt64(max(0, uncompressedSize)) > SecurityValidator.maxSingleEntrySize {

                throw GameImportError.securityValidationFailed("单个文件解压体积异常（超过 1.5GB）")

            }

            cumulativeExtractedBytes += UInt64(max(0, uncompressedSize))

            if cumulativeExtractedBytes > SecurityValidator.maxTotalExtractedBytes {

                throw GameImportError.securityValidationFailed("累计解压体积超过 4GB 安全上限，疑似压缩炸弹")

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

            guard payloadStart >= 0, compressedSize >= 0, payloadEnd <= data.count else { continue }



            try fm.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)

            let compressedSlice = data.subdata(in: payloadStart..<payloadEnd)



            if compressionMethod == 0 {

                try compressedSlice.write(to: outURL)

            } else if compressionMethod == 8 {

                let decompressed = try inflateRawDeflate(compressedSlice, expectedSize: uncompressedSize)

                try decompressed.write(to: outURL)

            } else {

                throw GameImportError.encryptedArchiveNotSupported("非标准或受保护的 ZIP 压缩算法 (\(compressionMethod))")

            }



            if index % 15 == 0 || index + 1 == totalEntries {

                let frac = Double(index + 1) / Double(max(1, totalEntries))

                onProgress?(frac, "正在安全解压 ZIP (\(index + 1)/\(totalEntries))…")

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

                if UInt64(output.count) > SecurityValidator.maxSingleEntrySize {

                    throw GameImportError.securityValidationFailed("解压数据膨胀超出安全阈值")

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

                    throw GameImportError.unzipFailed("zlib 解压数据校验失败 (\(res))")

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



// MARK: - 零第三方依赖：纯 Swift Electron app.asar 标准解包器（仅支持公开格式，含魔数与边界安全校验）



enum NativeAsarExtractor {

    nonisolated static func extract(

        asarURL: URL,

        to destinationURL: URL,

        baseOffsetInFile: UInt64 = 0,

        onProgress: (@Sendable (Double, String) -> Void)? = nil

    ) throws {

        let fileSize = try SecurityValidator.validateFileSize(at: asarURL)

        let fm = FileManager.default

        let handle = try FileHandle(forReadingFrom: asarURL)

        defer { try? handle.close() }



        try handle.seek(toOffset: baseOffsetInFile)

        guard let prefixData = try handle.read(upToCount: 16), prefixData.count == 16 else {

            throw GameImportError.asarExtractionFailed("文件头部不足 16 字节")

        }



        let headerSizePickle = prefixData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian }

        let headerSize = prefixData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian }

        let jsonSize = prefixData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self).littleEndian }



        guard headerSizePickle == 4, jsonSize > 0, jsonSize <= 64_000_000 else {

            throw GameImportError.encryptedArchiveNotSupported("非标准或已加密的 ASAR 归档头")

        }



        guard let jsonData = try handle.read(upToCount: Int(jsonSize)),

              let rootDict = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {

            throw GameImportError.encryptedArchiveNotSupported("ASAR 目录树已加密或格式不兼容")

        }



        let totalFiles = max(1, countFiles(in: rootDict))

        var extracted = 0

        var cumulativeBytes: UInt64 = 0

        let payloadBaseOffset = baseOffsetInFile + UInt64(8) + UInt64(headerSize)

        try fm.createDirectory(at: destinationURL, withIntermediateDirectories: true)



        try extractNode(

            node: rootDict,

            currentURL: destinationURL,

            rootDestinationURL: destinationURL,

            fileHandle: handle,

            fileSize: fileSize,

            payloadBaseOffset: payloadBaseOffset,

            totalFiles: totalFiles,

            extractedFiles: &extracted,

            cumulativeBytes: &cumulativeBytes,

            onProgress: onProgress

        )

    }



    /// 扫描经 PE 魔数校验的单文件 .exe 内部是否包含公开标准格式的 ASAR 归档

    nonisolated static func extractEmbeddedAsar(

        from exeURL: URL,

        to destinationURL: URL,

        onProgress: (@Sendable (Double, String) -> Void)? = nil

    ) throws {

        try SecurityValidator.validatePEExecutableHeader(at: exeURL)

        let data = try Data(contentsOf: exeURL, options: .mappedIfSafe)

        let signature = Data("{\"files\":".utf8)

        guard let sigRange = data.range(of: signature), sigRange.lowerBound >= 16 else {

            throw GameImportError.asarExtractionFailed("未在 EXE 中检测到公开标准格式的 ASAR 归档")

        }

        let asarStartOffset = UInt64(sigRange.lowerBound - 16)

        try extract(asarURL: exeURL, to: destinationURL, baseOffsetInFile: asarStartOffset, onProgress: onProgress)

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

        rootDestinationURL: URL,

        fileHandle: FileHandle,

        fileSize: UInt64,

        payloadBaseOffset: UInt64,

        totalFiles: Int,

        extractedFiles: inout Int,

        cumulativeBytes: inout UInt64,

        onProgress: (@Sendable (Double, String) -> Void)?

    ) throws {

        let fm = FileManager.default

        if let files = node["files"] as? [String: Any] {

            try fm.createDirectory(at: currentURL, withIntermediateDirectories: true)

            for (name, val) in files {

                // 严格校验文件名安全性，拒绝任何路径穿越或非法节点

                if name.isEmpty || name.contains("..") || name.contains("/") || name.contains("\\") {

                    continue

                }

                guard let child = val as? [String: Any] else { continue }

                let childURL = currentURL.appendingPathComponent(name)

                let relPath = childURL.standardizedFileURL.path.ReplacingPrefix(rootDestinationURL.standardizedFileURL.path + "/")

                if GameImporter.isWindowsRuntimeBloat(relativePath: relPath, isDirectory: child["files"] != nil) {

                    continue

                }

                try extractNode(

                    node: child,

                    currentURL: childURL,

                    rootDestinationURL: rootDestinationURL,

                    fileHandle: fileHandle,

                    fileSize: fileSize,

                    payloadBaseOffset: payloadBaseOffset,

                    totalFiles: totalFiles,

                    extractedFiles: &extractedFiles,

                    cumulativeBytes: &cumulativeBytes,

                    onProgress: onProgress

                )

            }

            return

        }



        defer {

            extractedFiles += 1

            if extractedFiles % 15 == 0 || extractedFiles == totalFiles {

                onProgress?(Double(extractedFiles) / Double(totalFiles), "正在安全解包 ASAR (\(extractedFiles)/\(totalFiles))…")

            }

        }



        // 若条目包含自定义加密算法标记则拒绝提取，不内置通用破解

        if node["algorithm"] != nil || node["encrypted"] as? Bool == true {

            throw GameImportError.encryptedArchiveNotSupported("ASAR 条目包含自定义加密保护")

        }



        guard let sizeVal = parseUInt64(node["size"]),

              let offsetVal = parseUInt64(node["offset"]) else { return }



        let absoluteStart = payloadBaseOffset + offsetVal

        if fileSize > 0 && (absoluteStart >= fileSize || sizeVal > fileSize || absoluteStart + sizeVal > fileSize) {

            return

        }

        if sizeVal > SecurityValidator.maxSingleEntrySize {

            throw GameImportError.securityValidationFailed("ASAR 单文件体积超过 1.5GB 安全上限")

        }

        cumulativeBytes += sizeVal

        if cumulativeBytes > SecurityValidator.maxTotalExtractedBytes {

            throw GameImportError.securityValidationFailed("ASAR 累计解包体积超过 4GB 安全上限")

        }



        try fm.createDirectory(at: currentURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        fm.createFile(atPath: currentURL.path, contents: nil)

        guard sizeVal > 0 else { return }



        let outHandle = try FileHandle(forWritingTo: currentURL)

        defer { try? outHandle.close() }



        try fileHandle.seek(toOffset: absoluteStart)

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



private extension String {

    nonisolated func ReplacingPrefix(_ prefix: String) -> String {

        guard self.hasPrefix(prefix) else { return self }

        return String(self.dropFirst(prefix.count))

    }

}

