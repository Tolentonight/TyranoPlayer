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

struct GameLibraryView: View {
    @EnvironmentObject private var importer: GameImporter
    @EnvironmentObject private var orientationManager: OrientationManager

    @State private var showingFolderImporter = false
    @State private var showingArchiveImporter = false
    @State private var activeGame: Game?
    @State private var gamePendingEdit: Game?
    @State private var gamePendingDeletion: Game?

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
                                    onPlay: { activeGame = game },
                                    onEdit: { gamePendingEdit = game },
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
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showingFolderImporter = true
                        } label: {
                            Label("导入游戏文件夹（推荐）", systemImage: "folder.badge.plus")
                        }

                        Button {
                            showingArchiveImporter = true
                        } label: {
                            Label("导入 .zip / app.asar / package.nw", systemImage: "doc.zipper")
                        }
                    } label: {
                        Label("导入游戏", systemImage: "plus.circle.fill")
                    }
                    .disabled(importer.isImporting)
                }
            }
            // 选择文件夹导入
            .fileImporter(
                isPresented: $showingFolderImporter,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                handleImporterResult(result)
            }
            // 选择 .zip / .asar / .nw 导入
            .fileImporter(
                isPresented: $showingArchiveImporter,
                allowedContentTypes: [.zip, .archive, .asarArchive, .nwArchive],
                allowsMultipleSelection: false
            ) { result in
                handleImporterResult(result)
            }
            // 编辑名称与封面弹窗
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
            // 错误提示弹窗
            .alert(
                "导入提示",
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
            // 删除确认弹窗
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
                Text("删除后将移除 App 沙盒内的游戏文件。")
            }
            // 启动全屏游戏播放器
            .fullScreenCover(item: $activeGame) { game in
                WebPlayerContainerView(
                    game: game,
                    entryHTMLURL: game.entryHTMLURL(in: importer.gamesBaseURL),
                    readAccessURL: game.engineBaseDirectoryURL(in: importer.gamesBaseURL)
                )
            }
        }
    }

    private func handleImporterResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let firstURL = urls.first else { return }
            Task {
                await importer.importGame(from: firstURL)
            }
        case .failure(let error):
            importer.errorMessage = "未选择文件或读取失败：\(error.localizedDescription)"
        }
    }

    private var emptyStateView: some View {
        ContentUnavailableView {
            Label("暂无已导入的 Tyrano 游戏", systemImage: "gamecontroller.fill")
        } description: {
            Text("点击右上角「+」从系统「文件」App 选择包含 index.html + tyrano 的游戏文件夹或 .zip / app.asar 导入。")
        } actions: {
            HStack(spacing: 12) {
                Button {
                    showingFolderImporter = true
                } label: {
                    Label("选择文件夹导入", systemImage: "folder.badge.plus")
                        .fontWeight(.semibold)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    showingArchiveImporter = true
                } label: {
                    Label("导入 ZIP / ASAR", systemImage: "doc.zipper")
                        .fontWeight(.semibold)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
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
    let onPlay: () -> Void
    let onEdit: () -> Void
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

                Text(game.importedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(action: onPlay) {
                Label("运行游戏", systemImage: "play.fill")
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
            .fileImporter(
                isPresented: $showingFileImagePicker,
                allowedContentTypes: [.image],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    let hasAccess = url.startAccessingSecurityScopedResource()
                    defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
                    if let data = try? Data(contentsOf: url) {
                        selectedImageData = data
                        resetToDefaultCover = false
                    }
                }
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
