
import Foundation

import UIKit



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



    func savesDirectoryURL(in gamesBaseURL: URL) -> URL {

        let dir = rootDirectoryURL(in: gamesBaseURL).appendingPathComponent("Saves", isDirectory: true)

        if !FileManager.default.fileExists(atPath: dir.path) {

            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        }

        return dir

    }



    func nativeSaveStoreURL(in gamesBaseURL: URL) -> URL {

        savesDirectoryURL(in: gamesBaseURL).appendingPathComponent("tyrano_saves.json")

    }



    func coverImageURL(in gamesBaseURL: URL) -> URL? {

        guard let relativeCoverPath else { return nil }

        let url = rootDirectoryURL(in: gamesBaseURL).appendingPathComponent(relativeCoverPath)

        return FileManager.default.fileExists(atPath: url.path) ? url : nil

    }

}



struct SaveBackupPackage: Codable, Sendable {

    let schemaVersion: Int

    let gameTitle: String

    let gameFolderName: String

    let exportedAt: Date

    let storageEntries: [String: String]

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



/// 全局持久化诊断日志器：记录系统信息、导入事件、存档读写与 WebKit 控制台报错，支持一键导出发给开发者

@MainActor

final class AppLogger: ObservableObject {

    static let shared = AppLogger()



    @Published private(set) var entries: [ConsoleLogEntry] = []

    private let fileManager = FileManager.default

    private let logIOQueue = DispatchQueue(label: "com.tyrano.logger.io", qos: .utility)



    var logDirectoryURL: URL {

        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]

        let dir = docs.appendingPathComponent("Logs", isDirectory: true)

        if !fileManager.fileExists(atPath: dir.path) {

            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        }

        return dir

    }



    var logFileURL: URL {

        logDirectoryURL.appendingPathComponent("tyrano_diagnostic.log")

    }



    private init() {

        let device = UIDevice.current

        let header = "=== TyranoPlayer 诊断日志启动 (\(Date().ISO8601Format())) | \(device.model) iOS \(device.systemVersion) ==="

        append(level: .log, category: "SYSTEM", message: header)

    }



    func append(level: ConsoleLogLevel, category: String = "APP", message: String) {

        let formatted = "[\(category)] \(message)"

        let entry = ConsoleLogEntry(timestamp: Date(), level: level, message: formatted)

        entries.append(entry)

        if entries.count > 600 {

            entries.removeFirst(entries.count - 600)

        }



        let timeStr = Self.timeFormatter.string(from: entry.timestamp)

        let line = "[\(timeStr)] [\(level.rawValue)] \(formatted)\n"

        let targetURL = self.logFileURL

        if let data = line.data(using: .utf8) {

            logIOQueue.async {

                if FileManager.default.fileExists(atPath: targetURL.path),

                   let handle = try? FileHandle(forWritingTo: targetURL) {

                    defer { try? handle.close() }

                    _ = try? handle.seekToEnd()

                    try? handle.write(contentsOf: data)

                } else {

                    try? data.write(to: targetURL, options: .atomic)

                }

            }

        }

    }



    func clearLogs() {

        entries.removeAll()

        try? fileManager.removeItem(at: logFileURL)

        append(level: .log, category: "SYSTEM", message: "日志已手动清空")

    }



    func exportFullReportText(games: [Game]) -> String {

        let device = UIDevice.current

        var lines: [String] = []

        lines.append("==========================================")

        lines.append("TyranoPlayer iOS 诊断报告")

        lines.append("生成时间: \(Date().ISO8601Format())")

        lines.append("系统版本: \(device.systemName) \(device.systemVersion) (\(device.model))")

        lines.append("已导入游戏数: \(games.count)")

        for g in games {

            lines.append(" - \(g.title) [entry: \(g.relativeEntryPath), folder: \(g.folderName)]")

        }

        lines.append("==========================================")

        for item in entries {

            let t = Self.timeFormatter.string(from: item.timestamp)

            lines.append("[\(t)] [\(item.level.rawValue)] \(item.message)")

        }

        let report = lines.joined(separator: "\n")

        try? report.write(to: logFileURL, atomically: true, encoding: .utf8)

        return report

    }



    private static let timeFormatter: DateFormatter = {

        let df = DateFormatter()

        df.dateFormat = "HH:mm:ss.SSS"

        return df

    }()

}



enum GameImportError: LocalizedError, Sendable {

    case securityScopeDenied

    case unsupportedArchiveFormat(String)

    case encryptedArchiveNotSupported(String)

    case securityValidationFailed(String)

    case asarExtractionFailed(String)

    case unzipFailed(String)

    case notTyranoGame

    case fileCopyFailed(String)

    case backupRestoreFailed(String)



    var errorDescription: String? {

        switch self {

        case .securityScopeDenied:

            return "无法访问所选文件或文件夹，请确认已在「文件」App 中授权访问。"

        case .unsupportedArchiveFormat(let ext):

            return "暂不支持直接解压 .\(ext) 压缩包。请选择已解压的游戏文件夹、标准 .zip 压缩包、或包含公开格式 app.asar / package.nw 的目录。"

        case .encryptedArchiveNotSupported(let detail):

            return "检测到加密或受保护的归档格式（\(detail)）。本软件仅支持公开标准格式，不内置通用破解密钥，请使用游戏官方提供的未加密版本。"

        case .securityValidationFailed(let detail):

            return "安全校验未通过，已拒绝加载可疑或损坏的封包（\(detail)）。"

        case .asarExtractionFailed(let detail):

            return "解包 Electron app.asar 失败（\(detail)）。请确认该文件为公开标准 ASAR 归档。"

        case .unzipFailed(let detail):

            return "解压 ZIP 归档失败：\(detail)"

        case .notTyranoGame:

            return "未检测到有效的 TyranoScript 游戏结构（需包含 index.html + tyrano 文件夹，或包含标准公开格式的 app.asar / package.nw）。"

        case .fileCopyFailed(let detail):

            return "复制游戏文件到沙盒失败：\(detail)"

        case .backupRestoreFailed(let detail):

            return "存档备份/恢复失败：\(detail)"

        }

    }

}

