
import SwiftUI

import PhotosUI

import UniformTypeIdentifiers

import UIKit



extension UTType {

    static var asarArchive: UTType {

        UTType(filenameExtension: "asar") ?? .data

    }

    static var nwArchive: UTType {

        UTType(filenameExtension: "nw") ?? .archive

    }

}



enum PickerImportMode: Identifiable {

    case folder

    case archive

    case anyItem

    case restoreSave(Game)



    var id: String {

        switch self {

        case .folder: return "folder"

        case .archive: return "archive"

        case .anyItem: return "anyItem"

        case .restoreSave(let g): return "restore_\(g.id.uuidString)"

        }

    }



    var contentTypes: [UTType] {

        switch self {

        case .folder:

            return [.folder]

        case .archive:

            return [.zip, .archive, .asarArchive, .nwArchive, .data]

        case .anyItem:

            return [.folder, .item, .html, .zip, .archive, .asarArchive, .nwArchive, .data]

        case .restoreSave:

            return [.json, .data, .item]

        }

    }

}



struct ShareSheetView: UIViewControllerRepresentable {

    let activityItems: [Any]



    func makeUIViewController(context: Context) -> UIActivityViewController {

        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)

    }



    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}

}



struct NativeDocumentPicker: UIViewControllerRepresentable {

    let contentTypes: [UTType]

    let onPick: (URL) -> Void

    let onCancel: () -> Void



    func makeCoordinator() -> Coordinator {

        Coordinator(onPick: onPick, onCancel: onCancel)

    }



    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: false)

        picker.allowsMultipleSelection = false

        picker.shouldShowFileExtensions = true

        picker.delegate = context.coordinator

        return picker

    }



    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}



    final class Coordinator: NSObject, UIDocumentPickerDelegate {

        let onPick: (URL) -> Void

        let onCancel: () -> Void



        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {

            self.onPick = onPick

            self.onCancel = onCancel

        }



        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {

            guard let first = urls.first else {

                onCancel()

                return

            }

            onPick(first)

        }



        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {

            onCancel()

        }

    }

}



struct GameLibraryView: View {

    @EnvironmentObject private var importer: GameImporter

    @EnvironmentObject private var orientationManager: OrientationManager

    @ObservedObject private var logger = AppLogger.shared



    @State private var activePickerMode: PickerImportMode?

    @State private var activeGame: Game?

    @State private var gamePendingEdit: Game?

    @State private var gamePendingDeletion: Game?

    @State private var showDiagnosticSheet = false

    @State private var shareFileURL: URL?



    private let columns = [

        GridItem(.adaptive(minimum: 155, maximum: 220), spacing: 16)

    ]



    var body: some View {

        NavigationStack {

            ZStack {

                if importer.games.isEmpty {

                    emptyStateView

                } else {

                    ScrollView {

                        LazyVGrid(columns: columns, spacing: 18) {

                            ForEach(importer.games) { game in

                                GameCardItemView(

                                    game: game,

                                    coverURL: game.coverImageURL(in: importer.gamesBaseURL),

                                    saveCount: importer.saveEntryCount(for: game),

                                    onPlay: { activeGame = game },

                                    onEdit: { gamePendingEdit = game },

                                    onBackupSave: {

                                        if let url = importer.exportSaveBackup(for: game) {

                                            shareFileURL = url

                                        }

                                    },

                                    onRestoreSave: {

                                        activePickerMode = .restoreSave(game)

                                    },

                                    onRescan: {

                                        Task { await importer.rescanGame(game) }

                                    },

                                    onDelete: { gamePendingDeletion = game }

                                )

                            }

                        }

                        .padding(16)

                    }

                }



                if let toast = importer.toastMessage {

                    VStack {

                        Text(toast)

                            .font(.subheadline)

                            .fontWeight(.medium)

                            .foregroundStyle(.white)

                            .padding(.horizontal, 16)

                            .padding(.vertical, 10)

                            .background(.black.opacity(0.82), in: Capsule())

                            .padding(.top, 8)

                        Spacer()

                    }

                    .transition(.move(edge: .top).combined(with: .opacity))

                }



                if importer.isImporting {

                    importingProgressOverlay

                }

            }

            .navigationTitle("Tyrano 游戏库")

            .toolbar {

                ToolbarItemGroup(placement: .topBarLeading) {

                    Button {

                        importer.scanSandboxGamesDirectory()

                    } label: {

                        Label("扫描沙盒", systemImage: "arrow.clockwise.circle")

                    }

                    .disabled(importer.isImporting)



                    Button {

                        showDiagnosticSheet = true

                    } label: {

                        Label("诊断日志", systemImage: "list.bullet.rectangle.portrait")

                    }

                }



                ToolbarItem(placement: .topBarTrailing) {

                    Menu {

                        Button {

                            activePickerMode = .anyItem

                        } label: {

                            Label("点选文件夹内的 index.html 或 .zip 导入（推荐）", systemImage: "doc.text.magnifyingglass")

                        }



                        Button {

                            activePickerMode = .folder

                        } label: {

                            Label("选择整个游戏文件夹导入", systemImage: "folder.badge.plus")

                        }



                        Button {

                            activePickerMode = .archive

                        } label: {

                            Label("导入 .zip / app.asar / package.nw", systemImage: "doc.zipper")

                        }



                        Divider()



                        Button {

                            importer.scanSandboxGamesDirectory()

                        } label: {

                            Label("直接扫描「我的 iPhone/TyranoPlayer/Games」", systemImage: "folder.fill.badge.gearshape")

                        }

                    } label: {

                        Label("导入游戏", systemImage: "plus.circle.fill")

                    }

                    .disabled(importer.isImporting)

                }

            }

            .sheet(item: $activePickerMode) { mode in

                NativeDocumentPicker(

                    contentTypes: mode.contentTypes,

                    onPick: { pickedURL in

                        let currentMode = mode

                        activePickerMode = nil

                        switch currentMode {

                        case .restoreSave(let targetGame):

                            importer.restoreSaveBackup(from: pickedURL, for: targetGame)

                        default:

                            Task {

                                await importer.importGame(from: pickedURL)

                            }

                        }

                    },

                    onCancel: {

                        activePickerMode = nil

                    }

                )

                .ignoresSafeArea()

            }

            .sheet(item: $gamePendingEdit) { game in

                GameEditSheet(

                    game: game,

                    currentCoverURL: game.coverImageURL(in: importer.gamesBaseURL)

                ) { newTitle, newCoverData, resetCover in

                    importer.updateGameInfo(

                        game: game,

                        newTitle: newTitle,

                        newCoverImageData: newCoverData,

                        resetToDefaultCover: resetCover

                    )

                }

            }

            .sheet(isPresented: $showDiagnosticSheet) {

                DiagnosticLogSheetView(games: importer.games)

            }

            .sheet(

                isPresented: Binding(

                    get: { shareFileURL != nil },

                    set: { if !$0 { shareFileURL = nil } }

                )

            ) {

                if let url = shareFileURL {

                    ShareSheetView(activityItems: [url])

                }

            }

            .alert(

                "提示",

                isPresented: Binding(

                    get: { importer.errorMessage != nil },

                    set: { if !$0 { importer.errorMessage = nil } }

                )

            ) {

                Button("确定", role: .cancel) {

                    importer.errorMessage = nil

                }

            } message: {

                Text(importer.errorMessage ?? "")

            }

            .confirmationDialog(

                "确认删除该游戏？",

                isPresented: Binding(

                    get: { gamePendingDeletion != nil },

                    set: { if !$0 { gamePendingDeletion = nil } }

                ),

                titleVisibility: .visible

            ) {

                if let game = gamePendingDeletion {

                    Button("删除「\(game.title)」", role: .destructive) {

                        importer.deleteGame(game)

                        gamePendingDeletion = nil

                    }

                }

                Button("取消", role: .cancel) {

                    gamePendingDeletion = nil

                }

            } message: {

                Text("删除后将移除 App 沙盒内的游戏文件（已导出的本地存档备份不会受影响）。")

            }

            .fullScreenCover(item: $activeGame) { game in

                WebPlayerContainerView(

                    game: game,

                    entryHTMLURL: game.entryHTMLURL(in: importer.gamesBaseURL),

                    readAccessURL: game.rootDirectoryURL(in: importer.gamesBaseURL),

                    nativeSaveStoreURL: game.nativeSaveStoreURL(in: importer.gamesBaseURL)

                )

                .environmentObject(importer)

            }

        }

    }



    private var emptyStateView: some View {

        ContentUnavailableView {

            Label("暂无已导入的 Tyrano 游戏", systemImage: "gamecontroller.fill")

        } description: {

            Text("方式 1（推荐）：在系统「文件」App 中把游戏文件夹放进「我的 iPhone/TyranoPlayer/Games」后点下方扫描；方式 2：直接点选游戏文件夹内的 index.html 或 .zip 导入。")

        } actions: {

            VStack(spacing: 10) {

                Button {

                    importer.scanSandboxGamesDirectory()

                } label: {

                    Label("扫描 TyranoPlayer/Games 目录（秒导入）", systemImage: "arrow.clockwise.circle.fill")

                        .fontWeight(.semibold)

                        .frame(minWidth: 240)

                }

                .buttonStyle(.borderedProminent)



                Button {

                    activePickerMode = .anyItem

                } label: {

                    Label("点选游戏内的 index.html 或 .zip 导入", systemImage: "doc.badge.plus")

                        .fontWeight(.semibold)

                        .frame(minWidth: 240)

                }

                .buttonStyle(.bordered)



                Button {

                    activePickerMode = .folder

                } label: {

                    Label("选择整个游戏文件夹导入", systemImage: "folder.badge.plus")

                        .fontWeight(.semibold)

                        .frame(minWidth: 240)

                }

                .buttonStyle(.bordered)

            }

        }

    }



    private var importingProgressOverlay: some View {

        ZStack {

            Color.black.opacity(0.42)

                .ignoresSafeArea()



            VStack(spacing: 14) {

                ProgressView(value: importer.importProgress, total: 1.0)

                    .progressViewStyle(.linear)

                    .frame(width: 240)



                HStack {

                    Text(importer.importStatusText)

                        .font(.caption)

                        .foregroundStyle(.secondary)

                        .lineLimit(1)

                    Spacer()

                    Text("\(Int(importer.importProgress * 100))%")

                        .font(.caption)

                        .fontWeight(.bold)

                        .monospacedDigit()

                }

                .frame(width: 240)

            }

            .padding(24)

            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))

            .shadow(radius: 12)

        }

    }

}



struct GameCardItemView: View {

    let game: Game

    let coverURL: URL?

    let saveCount: Int

    let onPlay: () -> Void

    let onEdit: () -> Void

    let onBackupSave: () -> Void

    let onRestoreSave: () -> Void

    let onRescan: () -> Void

    let onDelete: () -> Void



    var body: some View {

        Button(action: onPlay) {

            VStack(alignment: .leading, spacing: 8) {

                ZStack {

                    if let coverURL, let uiImage = UIImage(contentsOfFile: coverURL.path) {

                        Image(uiImage: uiImage)

                            .resizable()

                            .scaledToFill()

                            .frame(height: 115)

                            .clipped()

                            .id(game.coverUpdatedAt ?? game.importedAt)

                    } else {

                        LinearGradient(

                            colors: [.indigo.opacity(0.85), .purple.opacity(0.75)],

                            startPoint: .topLeading,

                            endPoint: .bottomTrailing

                        )

                        .frame(height: 115)

                        .overlay {

                            VStack(spacing: 6) {

                                Image(systemName: "play.tv.fill")

                                    .font(.system(size: 30))

                                    .foregroundStyle(.white.opacity(0.9))

                                Text("TYRANO")

                                    .font(.caption2)

                                    .fontWeight(.bold)

                                    .tracking(1.5)

                                    .foregroundStyle(.white.opacity(0.75))

                            }

                        }

                    }

                }

                .clipShape(RoundedRectangle(cornerRadius: 10))



                HStack(spacing: 4) {

                    Text(game.title)

                        .font(.subheadline)

                        .fontWeight(.semibold)

                        .foregroundStyle(.primary)

                        .lineLimit(1)



                    Spacer(minLength: 2)



                    Button(action: onEdit) {

                        Image(systemName: "pencil.circle")

                            .font(.subheadline)

                            .foregroundStyle(.secondary)

                    }

                    .buttonStyle(.plain)

                }



                HStack {

                    Text(game.importedAt.formatted(date: .abbreviated, time: .omitted))

                        .font(.caption2)

                        .foregroundStyle(.secondary)

                    Spacer()

                    Text(saveCount > 0 ? "已存档" : "无存档")

                        .font(.caption2)

                        .foregroundStyle(saveCount > 0 ? .green : .secondary)

                }

            }

            .padding(10)

            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))

        }

        .buttonStyle(.plain)

        .contextMenu {

            Button(action: onPlay) {

                Label("运行游戏", systemImage: "play.fill")

            }

            Button(action: onBackupSave) {

                Label("备份存档到本地文件", systemImage: "externaldrive.badge.plus")

            }

            Button(action: onRestoreSave) {

                Label("从本地文件恢复存档", systemImage: "arrow.down.doc.fill")

            }

            Button(action: onEdit) {

                Label("自定义名称与封面", systemImage: "photo.badge.plus")

            }

            Button(action: onRescan) {

                Label("重新扫描游戏目录", systemImage: "arrow.triangle.2.circlepath")

            }

            Divider()

            Button(role: .destructive, action: onDelete) {

                Label("删除游戏", systemImage: "trash")

            }

        }

    }

}



struct DiagnosticLogSheetView: View {

    let games: [Game]

    @ObservedObject private var logger = AppLogger.shared

    @Environment(\.dismiss) private var dismiss

    @State private var copiedToast = false

    @State private var shareLogURL: URL?



    var body: some View {

        NavigationStack {

            VStack(spacing: 0) {

                if logger.entries.isEmpty {

                    ContentUnavailableView("暂无日志记录", systemImage: "doc.text")

                } else {

                    ScrollView {

                        LazyVStack(alignment: .leading, spacing: 6) {

                            ForEach(logger.entries) { entry in

                                Text("[\(entry.level.rawValue)] \(entry.message)")

                                    .font(.system(size: 11, design: .monospaced))

                                    .foregroundStyle(entry.level == .error ? .red : (entry.level == .warn ? .orange : .primary))

                                    .frame(maxWidth: .infinity, alignment: .leading)

                                    .padding(.horizontal, 12)

                            }

                        }

                        .padding(.vertical, 10)

                    }

                }



                Divider()



                HStack(spacing: 12) {

                    Button {

                        let text = logger.exportFullReportText(games: games)

                        UIPasteboard.general.string = text

                        copiedToast = true

                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {

                            copiedToast = false

                        }

                    } label: {

                        Label(copiedToast ? "已复制到剪贴板！" : "一键复制全部日志", systemImage: "doc.on.doc.fill")

                            .frame(maxWidth: .infinity)

                    }

                    .buttonStyle(.borderedProminent)



                    Button {

                        _ = logger.exportFullReportText(games: games)

                        shareLogURL = logger.logFileURL

                    } label: {

                        Label("导出 .log 文件", systemImage: "square.and.arrow.up")

                            .frame(maxWidth: .infinity)

                    }

                    .buttonStyle(.bordered)

                }

                .padding(12)

            }

            .navigationTitle("诊断日志（可发给开发者）")

            .navigationBarTitleDisplayMode(.inline)

            .toolbar {

                ToolbarItem(placement: .topBarLeading) {

                    Button(role: .destructive) {

                        logger.clearLogs()

                    } label: {

                        Text("清空")

                    }

                }

                ToolbarItem(placement: .topBarTrailing) {

                    Button("关闭") { dismiss() }

                }

            }

            .sheet(

                isPresented: Binding(

                    get: { shareLogURL != nil },

                    set: { if !$0 { shareLogURL = nil } }

                )

            ) {

                if let url = shareLogURL {

                    ShareSheetView(activityItems: [url])

                }

            }

        }

    }

}



struct GameEditSheet: View {

    let game: Game

    let currentCoverURL: URL?

    let onSave: (String, Data?, Bool) -> Void



    @Environment(\.dismiss) private var dismiss

    @State private var titleInput: String

    @State private var selectedPhotoItem: PhotosPickerItem?

    @State private var selectedImageData: Data?

    @State private var resetToDefaultCover = false

    @State private var showingFileImagePicker = false



    init(game: Game, currentCoverURL: URL?, onSave: @escaping (String, Data?, Bool) -> Void) {

        self.game = game

        self.currentCoverURL = currentCoverURL

        self.onSave = onSave

        _titleInput = State(initialValue: game.title)

    }



    var body: some View {

        NavigationStack {

            Form {

                Section("游戏名称") {

                    TextField("请输入游戏名称", text: $titleInput)

                }



                Section("游戏封面") {

                    HStack {

                        Spacer()

                        coverPreview

                            .frame(width: 200, height: 125)

                            .clipShape(RoundedRectangle(cornerRadius: 12))

                        Spacer()

                    }

                    .padding(.vertical, 6)



                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {

                        Label("从「相册」选择封面图片", systemImage: "photo.on.rectangle")

                    }

                    .onChange(of: selectedPhotoItem) { _, newItem in

                        guard let newItem else { return }

                        Task {

                            if let data = try? await newItem.loadTransferable(type: Data.self) {

                                await MainActor.run {

                                    selectedImageData = data

                                    resetToDefaultCover = false

                                }

                            }

                        }

                    }



                    Button {

                        showingFileImagePicker = true

                    } label: {

                        Label("从「文件」选择封面图片", systemImage: "folder")

                    }



                    if currentCoverURL != nil || selectedImageData != nil {

                        Button(role: .destructive) {

                            selectedImageData = nil

                            selectedPhotoItem = nil

                            resetToDefaultCover = true

                        } label: {

                            Label("恢复默认游戏封面", systemImage: "arrow.counterclockwise")

                        }

                    }

                }

            }

            .navigationTitle("编辑游戏信息")

            .navigationBarTitleDisplayMode(.inline)

            .toolbar {

                ToolbarItem(placement: .cancellationAction) {

                    Button("取消") { dismiss() }

                }

                ToolbarItem(placement: .confirmationAction) {

                    Button("保存") {

                        onSave(titleInput, selectedImageData, resetToDefaultCover)

                        dismiss()

                    }

                    .fontWeight(.semibold)

                    .disabled(titleInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                }

            }

            .sheet(isPresented: $showingFileImagePicker) {

                NativeDocumentPicker(

                    contentTypes: [.image],

                    onPick: { url in

                        showingFileImagePicker = false

                        let hasAccess = url.startAccessingSecurityScopedResource()

                        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }

                        if let data = try? Data(contentsOf: url) {

                            selectedImageData = data

                            resetToDefaultCover = false

                        }

                    },

                    onCancel: {

                        showingFileImagePicker = false

                    }

                )

            }

        }

    }



    @ViewBuilder

    private var coverPreview: some View {

        if let data = selectedImageData, let uiImage = UIImage(data: data) {

            Image(uiImage: uiImage).resizable().scaledToFill()

        } else if !resetToDefaultCover, let url = currentCoverURL, let uiImage = UIImage(contentsOfFile: url.path) {

            Image(uiImage: uiImage).resizable().scaledToFill()

        } else {

            LinearGradient(colors: [.indigo, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)

                .overlay {

                    Text("默认占位封面").font(.caption).foregroundStyle(.white)

                }

        }

    }

}

