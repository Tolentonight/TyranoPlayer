import Foundation

struct Game: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    let folderName: String
    var relativeEntryPath: String
    var relativeCoverPath: String?
    var coverUpdatedAt: Date?
    let importedAt: Date

    func rootDirectoryURL(in gamesBaseURL: URL) -> URL {
        gamesBaseURL.appendingPathComponent(folderName, isDirectory: true)
    }

    func entryHTMLURL(in gamesBaseURL: URL) -> URL {
        rootDirectoryURL(in: gamesBaseURL).appendingPathComponent(relativeEntryPath)
    }

    func engineBaseDirectoryURL(in gamesBaseURL: URL) -> URL {
        entryHTMLURL(in: gamesBaseURL).deletingLastPathComponent()
    }

    func coverImageURL(in gamesBaseURL: URL) -> URL? {
        guard let relativeCoverPath else { return nil }
        let url = rootDirectoryURL(in: gamesBaseURL).appendingPathComponent(relativeCoverPath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

enum ConsoleLogLevel: String, CaseIterable, Identifiable, Sendable {
    case all = "ALL"
    case log = "LOG"
    case warn = "WARN"
    case error = "ERROR"

    var id: String { rawValue }
}

struct ConsoleLogEntry: Identifiable, Equatable, Sendable {
    let id = UUID()
    let timestamp: Date
    let level: ConsoleLogLevel
    let message: String
}

enum GameImportError: LocalizedError, Sendable {
    case securityScopeDenied
    case unsupportedArchiveFormat(String)
    case asarExtractionFailed(String)
    case unzipFailed(String)
    case notTyranoGame
    case fileCopyFailed(String)

    var errorDescription: String? {
        switch self {
        case .securityScopeDenied:
            return "无法访问所选文件或文件夹，请确认已在「文件」App 中授权访问。"
        case .unsupportedArchiveFormat(let ext):
            return "暂不支持直接解压 .\(ext) 压缩包。请选择已解压的游戏文件夹、.zip 压缩包、或包含 app.asar / package.nw 的目录。"
        case .asarExtractionFailed(let detail):
            return "解包 Electron app.asar 失败（\(detail)）。请先在电脑上执行 npx @electron/asar extract app.asar ./extracted 手动解压后再导入文件夹。"
        case .unzipFailed(let detail):
            return "解压 ZIP 归档失败：\(detail)"
        case .notTyranoGame:
            return "未检测到有效的 TyranoScript 游戏结构（需包含 index.html + tyrano 文件夹，或包含未加密的 app.asar / package.nw）。"
        case .fileCopyFailed(let detail):
            return "复制游戏文件到沙盒失败：\(detail)"
        }
    }
}
