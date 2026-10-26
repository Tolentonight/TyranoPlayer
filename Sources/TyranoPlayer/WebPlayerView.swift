
import SwiftUI

import WebKit

import AVFoundation

import UniformTypeIdentifiers

import UIKit

import Darwin



struct WebPlayerContainerView: View {

    let game: Game

    let entryHTMLURL: URL

    let readAccessURL: URL

    let nativeSaveStoreURL: URL



    @Environment(\.dismiss) private var dismiss

    @Environment(\.scenePhase) private var scenePhase

    @EnvironmentObject private var orientationManager: OrientationManager

    @EnvironmentObject private var importer: GameImporter



    @State private var reloadTrigger = UUID()

    @State private var layoutFixTrigger = UUID()

    @State private var showExitConfirmation = false

    @State private var isFullScreenStretch = false

    @State private var isFloatingBarHidden = false

    @State private var showDebugConsole = false

    @State private var consoleLogs: [ConsoleLogEntry] = []

    @State private var pendingJSCommand: String?

    @State private var shareBackupURL: URL?

    @State private var showRestorePicker = false



    private var errorCount: Int {

        consoleLogs.filter { $0.level == .error }.count

    }



    var body: some View {

        ZStack(alignment: .topTrailing) {

            Color.black.ignoresSafeArea()



            WebPlayerView(

                gameID: game.id.uuidString,

                gameTitle: game.title,

                entryHTMLURL: entryHTMLURL,

                readAccessURL: readAccessURL,

                nativeSaveStoreURL: nativeSaveStoreURL,

                reloadTrigger: reloadTrigger,

                layoutFixTrigger: layoutFixTrigger,

                isFullScreenStretch: isFullScreenStretch,

                pendingJSCommand: $pendingJSCommand,

                onConsoleLog: { entry in

                    // 仅在调试抽屉打开或遇到错误时更新视图状态，避免游戏运行期间高频日志触发 SwiftUI 视图重绘掉帧

                    if showDebugConsole || entry.level == .error || entry.level == .warn {

                        consoleLogs.append(entry)

                        if consoleLogs.count > 300 {

                            consoleLogs.removeFirst(consoleLogs.count - 300)

                        }

                    }

                    AppLogger.shared.append(level: entry.level, category: "WEBKIT:\(game.title)", message: entry.message)

                }

            )

            .ignoresSafeArea()



            floatingToolbar



            if showDebugConsole {

                VStack {

                    Spacer()

                    WebDebugConsoleDrawer(

                        gameTitle: game.title,

                        logs: $consoleLogs,

                        onExecuteJS: { cmd in pendingJSCommand = cmd },

                        onExportLog: {

                            _ = AppLogger.shared.exportFullReportText(games: importer.games)

                            shareBackupURL = AppLogger.shared.logFileURL

                        },

                        onClose: { showDebugConsole = false }

                    )

                    .frame(maxHeight: 270)

                }

                .ignoresSafeArea(edges: .bottom)

            }

        }

        .statusBarHidden(true)

        .persistentSystemOverlays(.hidden)

        .onAppear {

            AppLogger.shared.append(level: .log, category: "PLAYER", message: "启动游戏: \(game.title) (\(entryHTMLURL.path))")

            orientationManager.apply(orientationManager.currentMode)

        }

        .onDisappear {

            orientationManager.resetToDefault()

        }

        .onChange(of: scenePhase) { _, newPhase in

            if newPhase == .active {

                orientationManager.apply(orientationManager.currentMode)

                layoutFixTrigger = UUID()

            }

        }

        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in

            orientationManager.apply(orientationManager.currentMode)

            layoutFixTrigger = UUID()

        }

        .sheet(

            isPresented: Binding(

                get: { shareBackupURL != nil },

                set: { if !$0 { shareBackupURL = nil } }

            )

        ) {

            if let url = shareBackupURL {

                ShareSheetView(activityItems: [url])

            }

        }

        .sheet(isPresented: $showRestorePicker) {

            NativeDocumentPicker(

                contentTypes: [.json, .data, .item],

                onPick: { url in

                    showRestorePicker = false

                    importer.restoreSaveBackup(from: url, for: game)

                    reloadTrigger = UUID()

                },

                onCancel: {

                    showRestorePicker = false

                }

            )

        }

        .confirmationDialog("确定返回游戏库吗？", isPresented: $showExitConfirmation, titleVisibility: .visible) {

            Button("返回游戏库", role: .destructive) { dismiss() }

            Button("继续游戏", role: .cancel) {}

        } message: {

            Text("系统已自动实时同步存档到本地沙盒。")

        }

    }



    @ViewBuilder

    private var floatingToolbar: some View {

        if isFloatingBarHidden {

            Button {

                isFloatingBarHidden = false

            } label: {

                Image(systemName: "chevron.left.circle.fill")

                    .font(.system(size: 22))

                    .foregroundStyle(.white.opacity(0.35))

                    .padding(10)

            }

        } else {

            HStack(spacing: 10) {

                Button {

                    showExitConfirmation = true

                } label: {

                    HStack(spacing: 4) {

                        Image(systemName: "chevron.backward")

                            .font(.caption.weight(.bold))

                        Text("游戏库")

                            .font(.caption)

                            .fontWeight(.semibold)

                    }

                    .foregroundStyle(.white)

                    .padding(.horizontal, 10)

                    .padding(.vertical, 6)

                    .background(Color.white.opacity(0.18), in: Capsule())

                }



                Button {

                    isFullScreenStretch.toggle()

                    layoutFixTrigger = UUID()

                } label: {

                    HStack(spacing: 4) {

                        Image(systemName: isFullScreenStretch ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")

                            .font(.caption.weight(.bold))

                        Text(isFullScreenStretch ? "原始比例" : "全屏")

                            .font(.caption)

                            .fontWeight(.semibold)

                    }

                    .foregroundStyle(.white)

                    .padding(.horizontal, 10)

                    .padding(.vertical, 6)

                    .background(isFullScreenStretch ? Color.indigo.opacity(0.85) : Color.white.opacity(0.18), in: Capsule())

                }



                Menu {

                    Section("存档备份与恢复") {

                        Button {

                            if let url = importer.exportSaveBackup(for: game) {

                                shareBackupURL = url

                            }

                        } label: {

                            Label("备份当前存档到本地", systemImage: "externaldrive.badge.plus")

                        }



                        Button {

                            showRestorePicker = true

                        } label: {

                            Label("从备份文件恢复存档", systemImage: "arrow.down.doc.fill")

                        }

                    }



                    Section("屏幕方向 (\(orientationManager.currentMode.rawValue))") {

                        ForEach(ScreenOrientationMode.allCases) { mode in

                            Button {

                                orientationManager.apply(mode)

                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {

                                    layoutFixTrigger = UUID()

                                }

                            } label: {

                                Label(

                                    mode.rawValue,

                                    systemImage: orientationManager.currentMode == mode ? "checkmark.circle.fill" : mode.iconName

                                )

                            }

                        }

                    }



                    Section("画面与调试日志") {

                        Button {

                            layoutFixTrigger = UUID()

                        } label: {

                            Label("修复画面缩放 / 唤醒音频", systemImage: "aspectratio")

                        }

                        Button {

                            showDebugConsole.toggle()

                        } label: {

                            Label(

                                errorCount > 0 ? "调试控制台 (\(errorCount) 个错误)" : "调试控制台 (\(consoleLogs.count))",

                                systemImage: "terminal"

                            )

                        }

                        Button {

                            _ = AppLogger.shared.exportFullReportText(games: importer.games)

                            shareBackupURL = AppLogger.shared.logFileURL

                        } label: {

                            Label("导出诊断日志文件 (.log)", systemImage: "square.and.arrow.up")

                        }

                    }



                    Section("游戏控制") {

                        Button {

                            reloadTrigger = UUID()

                        } label: {

                            Label("重新加载游戏", systemImage: "arrow.clockwise")

                        }

                    }

                } label: {

                    Image(systemName: "ellipsis.circle.fill")

                        .font(.system(size: 20))

                        .foregroundStyle(.white)

                }



                Button {

                    isFloatingBarHidden = true

                } label: {

                    Image(systemName: "eye.slash.fill")

                        .font(.caption)

                        .foregroundStyle(.white.opacity(0.8))

                        .padding(6)

                }

            }

            .padding(.horizontal, 10)

            .padding(.vertical, 6)

            .background(.black.opacity(0.55), in: Capsule())

            .padding(.top, 10)

            .padding(.trailing, 12)

        }

    }

}



struct WebPlayerView: UIViewRepresentable {

    let gameID: String

    let gameTitle: String

    let entryHTMLURL: URL

    let readAccessURL: URL

    let nativeSaveStoreURL: URL

    let reloadTrigger: UUID

    let layoutFixTrigger: UUID

    let isFullScreenStretch: Bool

    @Binding var pendingJSCommand: String?

    let onConsoleLog: (ConsoleLogEntry) -> Void



    func makeCoordinator() -> Coordinator {

        Coordinator(nativeSaveStoreURL: nativeSaveStoreURL, onConsoleLog: onConsoleLog)

    }



    private static func loadInitialSaveJSON(from storeURL: URL) -> String {

        guard FileManager.default.fileExists(atPath: storeURL.path),

              let data = try? Data(contentsOf: storeURL),

              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String],

              let validData = try? JSONSerialization.data(withJSONObject: dict),

              let jsonStr = String(data: validData, encoding: .utf8) else {

            return "{}"

        }

        return jsonStr

    }



    func makeUIView(context: Context) -> WKWebView {

        Self.configureAudioSession()



        let config = WKWebViewConfiguration()

        config.websiteDataStore = .default()

        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")



        config.allowsInlineMediaPlayback = true

        config.mediaTypesRequiringUserActionForPlayback = []

        config.allowsAirPlayForMediaPlayback = false

        config.allowsPictureInPictureMediaPlayback = false



        let contentController = config.userContentController

        contentController.add(context.coordinator, name: Coordinator.consoleHandlerName)

        contentController.add(context.coordinator, name: Coordinator.storageHandlerName)



        let initialSavesJSON = Self.loadInitialSaveJSON(from: nativeSaveStoreURL)

        let isolatedGameID = gameID.replacingOccurrences(of: "-", with: "_")



        let preloadCompatJS = """

        (function() {

            var NL = String.fromCharCode(10);

            var GAME_UUID = '\(isolatedGameID)';

            var GAME_STORAGE_PREFIX = 'tyrano_isolated_' + GAME_UUID + '_';



            function collapseSlashes(str) {

                var s = String(str || '');

                while (s.indexOf('//') !== -1) {

                    s = s.split('//').join('/');

                }

                return s;

            }



            // 0. 在 .atDocumentStart 第一时间注入基础样式与 <video> 独立硬件合成层，确保开幕动画从第 0 帧即刻渲染且绝不阻塞按钮层级

            function injectEarlyBaseCSS() {

                try {

                    var root = document.head || document.documentElement;

                    if (!root || document.getElementById('__tyrano_early_css')) return;

                    var style = document.createElement('style');

                    style.id = '__tyrano_early_css';

                    style.textContent = [

                        '* { -webkit-touch-callout: none !important; -webkit-user-select: none !important; user-select: none !important; -webkit-tap-highlight-color: transparent !important; }',

                        'html, body { margin: 0 !important; padding: 0 !important; width: 100% !important; height: 100% !important; overflow: hidden !important; position: fixed !important; inset: 0 !important; background-color: #000000 !important; touch-action: manipulation; }',

                        'video { object-fit: contain; -webkit-transform: translateZ(0); transform: translateZ(0); }',

                        '#bgmovie { pointer-events: none; }'

                    ].join(NL);

                    root.appendChild(style);

                } catch (e) {}

            }

            injectEarlyBaseCSS();

            document.addEventListener('readystatechange', injectEarlyBaseCSS, true);

            document.addEventListener('DOMContentLoaded', injectEarlyBaseCSS, true);



            // 1. 轻量级控制台日志与全局异常优雅降级（过滤引擎高频普通日志，防止跨进程 IPC 阻塞主线程导致转场掉帧）

            function sendLog(level, args) {

                try {

                    var msg = Array.prototype.slice.call(args).map(function(item) {

                        if (item instanceof Error) {

                            return item.name + ': ' + item.message + (item.stack ? ' | ' + item.stack.split(NL)[0] : '');

                        }

                        if (typeof item === 'object' && item !== null) {

                            try { return JSON.stringify(item); } catch (e) { return String(item); }

                        }

                        return String(item);

                    }).join(' ');

                    window.webkit.messageHandlers.tyranoConsole.postMessage({ level: level, message: msg });

                } catch (e) {}

            }



            var origLog = console.log, origInfo = console.info, origWarn = console.warn, origError = console.error;

            console.warn = function() { sendLog('WARN', arguments); origWarn.apply(console, arguments); };

            console.error = function() { sendLog('ERROR', arguments); origError.apply(console, arguments); };



            var TRANSPARENT_PLACEHOLDER_PNG = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';



            // 自动恢复因缺图或弹窗中断的 UI 图层与点击事件

            function recoverStuckUiState() {

                try {

                    if (window.jQuery) {

                        var $ = window.jQuery;

                        var $menu = $('.layer_menu');

                        if ($menu.length && $menu.is(':visible')) {

                            var hasItems = $menu.find('img, .save_list_item, .menu_item, .button').length > 0;

                            if (!hasItems && $menu.text().trim().length === 0) {

                                $menu.empty().hide();

                            }

                        }

                        $('.layer_event_click').css({ 'display': 'block', 'pointer-events': 'auto' });

                    }

                    if (window.TYRANO && window.TYRANO.kag && window.TYRANO.kag.stat) {

                        window.TYRANO.kag.stat.is_stop = false;

                        window.TYRANO.kag.stat.is_wait = false;

                        window.TYRANO.kag.stat.is_trans = false;

                    }

                } catch (e) {}

            }



            window.addEventListener('error', function(e) {

                try {

                    var target = e.target || e.srcElement;

                    if (target && target !== window && target.tagName) {

                        var tag = String(target.tagName).toUpperCase();

                        if (tag === 'IMG') {

                            var failedSrc = target.getAttribute('src') || target.src || 'unknown';

                            if (failedSrc !== TRANSPARENT_PLACEHOLDER_PNG && !target.dataset.degradedPlaceholder) {

                                target.dataset.degradedPlaceholder = 'true';

                                sendLog('WARN', ['[优雅降级] 图片缺失或格式不受支持，已替换为安全占位图:', failedSrc]);

                                target.src = TRANSPARENT_PLACEHOLDER_PNG;

                            }

                            // 关键修复：绝不调用 e.stopPropagation()！

                            // 替换为 1x1 透明图后让浏览器正常触发 img.onload，保证 Tyrano 引擎 nextOrder() 与右侧按钮继续渲染

                            setTimeout(recoverStuckUiState, 50);

                            return;

                        }

                        if (tag === 'SCRIPT') {

                            var scriptSrc = target.getAttribute('src') || 'inline';

                            sendLog('WARN', ['[优雅降级] 外部脚本加载失败，已忽略并继续运行:', scriptSrc]);

                            return;

                        }

                    }

                    var detail = (e.message || 'RuntimeError') + (e.filename ? ' (' + e.filename.split('/').pop() + ':' + e.lineno + ')' : '');

                    sendLog('ERROR', ['[脚本异常已拦截]', detail]);

                    setTimeout(recoverStuckUiState, 50);

                    if (e.preventDefault) e.preventDefault();

                } catch (err) {}

            }, true);



            window.addEventListener('unhandledrejection', function(e) {

                sendLog('WARN', ['[异步异常已拦截]', e.reason ? String(e.reason) : 'unknown']);

                if (e && e.preventDefault) e.preventDefault();

            });



            // 拦截由于缺图或宏跳转 If 栈偏移引发的阻塞式 alert 报错弹窗，转为自愈恢复并继续推进指令

            var _origWindowAlert = window.alert;

            window.alert = function(msg) {

                var text = String(msg || '');

                sendLog('WARN', ['[拦截引擎报错弹窗]', text]);

                if (text.indexOf('Error:') === 0 || text.indexOf('file not found') !== -1 || text.indexOf('見つかりません') !== -1 || text.indexOf('誤りがあります') !== -1) {

                    setTimeout(function() {

                        try {

                            recoverStuckUiState();

                            if (window.TYRANO && window.TYRANO.kag && window.TYRANO.kag.ftag && text.indexOf('見つかりません') !== -1) {

                                window.TYRANO.kag.ftag.nextOrder();

                            }

                        } catch (e) {}

                    }, 30);

                    return;

                }

                if (_origWindowAlert) {

                    try { _origWindowAlert.call(window, msg); } catch (e) {}

                }

            };



            // 2. 独立命名空间隔离的原生持久化存档（支持游戏内返回标题/location.reload 实时拉取最新存档，绝不回档）

            var _bootNativeSaves = \(initialSavesJSON) || {};

            function pullLiveSavesFromServer() {

                var merged = {};

                try {

                    for (var bk in _bootNativeSaves) {

                        if (Object.prototype.hasOwnProperty.call(_bootNativeSaves, bk)) {

                            merged[bk] = _bootNativeSaves[bk];

                        }

                    }

                } catch (e) {}

                try {

                    var sessRaw = window.sessionStorage.getItem('__TYRANO_ALL_SAVES_' + GAME_UUID);

                    if (sessRaw) {

                        var sessMap = JSON.parse(sessRaw);

                        if (sessMap && typeof sessMap === 'object') {

                            for (var sk in sessMap) {

                                if (Object.prototype.hasOwnProperty.call(sessMap, sk)) {

                                    merged[sk] = sessMap[sk];

                                }

                            }

                        }

                    }

                } catch (e) {}

                try {

                    if (window.location && window.location.protocol && window.location.protocol.indexOf('http') === 0) {

                        var xhr = new XMLHttpRequest();

                        xhr.open('GET', '/__tyrano_native_saves__.json?_t=' + Date.now(), false);

                        xhr.send(null);

                        if (xhr.status === 200 && xhr.responseText) {

                            var liveMap = JSON.parse(xhr.responseText);

                            if (liveMap && typeof liveMap === 'object') {

                                for (var lk in liveMap) {

                                    if (Object.prototype.hasOwnProperty.call(liveMap, lk)) {

                                        merged[lk] = liveMap[lk];

                                    }

                                }

                            }

                        }

                    }

                } catch (e) {}

                return merged;

            }

            window.__TYRANO_NATIVE_SAVES__ = pullLiveSavesFromServer();

            window.__TYRANO_MEM_CACHE__ = {};



            function normalizeSaveKey(rawKey) {

                var k = String(rawKey || 'default');

                var parts = k.split('/');

                var base = parts[parts.length - 1] || k;

                if (base.toLowerCase().endsWith('.sav')) {

                    base = base.slice(0, base.length - 4);

                }

                if (base.toLowerCase().endsWith('.dat')) {

                    base = base.slice(0, base.length - 4);

                }

                return base;

            }



            function namespacedKey(rawKey) {

                var clean = normalizeSaveKey(rawKey);

                if (clean.indexOf(GAME_STORAGE_PREFIX) === 0) return clean;

                return GAME_STORAGE_PREFIX + clean;

            }



            function syncSaveToNative(key, val) {

                var strVal = String(val);

                var shortKey = normalizeSaveKey(key);

                var nsKey = namespacedKey(key);

                window.__TYRANO_NATIVE_SAVES__[key] = strVal;

                window.__TYRANO_NATIVE_SAVES__[shortKey] = strVal;

                window.__TYRANO_NATIVE_SAVES__[nsKey] = strVal;

                try {

                    window.sessionStorage.setItem('__TYRANO_ALL_SAVES_' + GAME_UUID, JSON.stringify(window.__TYRANO_NATIVE_SAVES__));

                } catch (e) {}

                try {

                    window.webkit.messageHandlers.tyranoStorage.postMessage({

                        action: 'set',

                        key: nsKey,

                        shortKey: shortKey,

                        value: strVal

                    });

                } catch (e) {}

            }



            function readSaveFromNative(key) {

                var nsKey = namespacedKey(key);

                if (Object.prototype.hasOwnProperty.call(window.__TYRANO_NATIVE_SAVES__, nsKey)) {

                    return window.__TYRANO_NATIVE_SAVES__[nsKey];

                }

                if (Object.prototype.hasOwnProperty.call(window.__TYRANO_NATIVE_SAVES__, key)) {

                    return window.__TYRANO_NATIVE_SAVES__[key];

                }

                var shortKey = normalizeSaveKey(key);

                if (Object.prototype.hasOwnProperty.call(window.__TYRANO_NATIVE_SAVES__, shortKey)) {

                    return window.__TYRANO_NATIVE_SAVES__[shortKey];

                }

                return null;

            }



            function removeSaveFromNative(key) {

                var shortKey = normalizeSaveKey(key);

                var nsKey = namespacedKey(key);

                delete window.__TYRANO_NATIVE_SAVES__[key];

                delete window.__TYRANO_NATIVE_SAVES__[shortKey];

                delete window.__TYRANO_NATIVE_SAVES__[nsKey];

                try {

                    window.webkit.messageHandlers.tyranoStorage.postMessage({

                        action: 'remove',

                        key: nsKey,

                        shortKey: shortKey

                    });

                } catch (e) {}

            }



            // 3. 接管并按游戏 UUID 严格隔离 localStorage

            var customLocalStorage = {

                getItem: function(key) {

                    var v = readSaveFromNative(String(key));

                    if (v !== null && v !== undefined) return v;

                    try { return window.sessionStorage.getItem(namespacedKey(key)); } catch (e) { return null; }

                },

                setItem: function(key, value) {

                    syncSaveToNative(String(key), String(value));

                    try { window.sessionStorage.setItem(namespacedKey(key), String(value)); } catch (e) {}

                },

                removeItem: function(key) {

                    removeSaveFromNative(String(key));

                    try { window.sessionStorage.removeItem(namespacedKey(key)); } catch (e) {}

                },

                clear: function() {

                    window.__TYRANO_NATIVE_SAVES__ = {};

                    try {

                        window.webkit.messageHandlers.tyranoStorage.postMessage({ action: 'clear' });

                    } catch (e) {}

                },

                key: function(index) {

                    var keys = Object.keys(window.__TYRANO_NATIVE_SAVES__);

                    return keys[index] || null;

                },

                get length() {

                    return Object.keys(window.__TYRANO_NATIVE_SAVES__).length;

                }

            };



            try {

                Object.defineProperty(window, 'localStorage', {

                    configurable: true,

                    enumerable: true,

                    get: function() { return customLocalStorage; }

                });

            } catch (e) {}



            // 4. 只读原包 + 纯内存解码与配置净化（绝不写回或破坏原包文件）

            function sanitizeConfigTextInMemory(txt) {

                if (!txt || typeof txt !== 'string') return txt;

                var out = txt;

                out = out.split(';configSave = file').join(';configSave = webstorage');

                out = out.split(';configSave=file').join(';configSave = webstorage');

                out = out.split(';configSave = webstorage_compress').join(';configSave = webstorage');

                out = out.split(';configSave=webstorage_compress').join(';configSave = webstorage');

                return out;

            }



            function isLegacyWindowsSaveFile(pathStr) {

                var lower = String(pathStr || '').toLowerCase();

                return lower.endsWith('.sav') || lower.endsWith('.dat') || lower.indexOf('savedata/') !== -1 || lower.indexOf('/savedata/') !== -1;

            }



            function xhrReadLocalFileSync(relPath) {

                try {

                    var clean = String(relPath || '').split('?')[0].split('#')[0];

                    if (clean.indexOf('file://') === 0) clean = clean.slice(7);

                    if (clean.indexOf('./') === 0) clean = clean.slice(2);



                    if (isLegacyWindowsSaveFile(clean)) {

                        return readSaveFromNative(clean);

                    }



                    if (Object.prototype.hasOwnProperty.call(window.__TYRANO_MEM_CACHE__, clean)) {

                        return window.__TYRANO_MEM_CACHE__[clean];

                    }



                    var badChar = String.fromCharCode(65533);

                    var xhr = new XMLHttpRequest();

                    xhr.open('GET', clean, false);

                    xhr.overrideMimeType('text/plain; charset=utf-8');

                    xhr.send(null);

                    if (xhr.status === 200 || (xhr.status === 0 && xhr.responseText && xhr.responseText.length > 0)) {

                        var txt = xhr.responseText;

                        if (txt && txt.indexOf(badChar) !== -1) {

                            try {

                                var xhrSjis = new XMLHttpRequest();

                                xhrSjis.open('GET', clean, false);

                                xhrSjis.overrideMimeType('text/plain; charset=shift_jis');

                                xhrSjis.send(null);

                                if (xhrSjis.status === 200 || xhrSjis.status === 0) {

                                    txt = xhrSjis.responseText;

                                }

                            } catch (e2) {}

                        }

                        if (clean.toLowerCase().indexOf('config.tjs') !== -1 && txt) {

                            txt = sanitizeConfigTextInMemory(txt);

                        }

                        window.__TYRANO_MEM_CACHE__[clean] = txt;

                        return txt;

                    }

                } catch (e) {}

                return null;

            }



            // 5. 严格顺序控制：锁定初始化 sf/f/tf 非空变量守卫

            function createSafeSFObject(initial) {

                var base = (initial && typeof initial === 'object') ? initial : {};

                if (typeof base._system_config_bgm_volume === 'undefined') base._system_config_bgm_volume = 100;

                if (typeof base._system_config_se_volume === 'undefined') base._system_config_se_volume = 100;

                if (typeof base._system_config_movie_volume === 'undefined') base._system_config_movie_volume = 100;

                if (typeof base._system_config_already_read_text_color === 'undefined') base._system_config_already_read_text_color = 0;

                if (typeof base._system_config_unread_text_skip === 'undefined') base._system_config_unread_text_skip = false;

                return base;

            }



            function installVariableNullGuard(kagObj) {

                if (!kagObj || typeof kagObj !== 'object') return;

                if (!kagObj.variable || typeof kagObj.variable !== 'object') {

                    kagObj.variable = { sf: createSafeSFObject({}), f: {}, tf: {}, mp: {} };

                }

                var varObj = kagObj.variable;

                if (varObj.__tyranoNullGuarded) return;

                varObj.__tyranoNullGuarded = true;



                var _sf = createSafeSFObject(varObj.sf);

                var _f = (varObj.f && typeof varObj.f === 'object') ? varObj.f : {};

                var _tf = (varObj.tf && typeof varObj.tf === 'object') ? varObj.tf : {};



                try {

                    Object.defineProperty(varObj, 'sf', {

                        configurable: true,

                        enumerable: true,

                        get: function() { return _sf; },

                        set: function(v) {

                            if (v && typeof v === 'object') {

                                _sf = createSafeSFObject(v);

                            } else {

                                _sf = createSafeSFObject(_sf);

                            }

                        }

                    });

                    Object.defineProperty(varObj, 'f', {

                        configurable: true,

                        enumerable: true,

                        get: function() { return _f; },

                        set: function(v) { _f = (v && typeof v === 'object') ? v : (_f || {}); }

                    });

                    Object.defineProperty(varObj, 'tf', {

                        configurable: true,

                        enumerable: true,

                        get: function() { return _tf; },

                        set: function(v) { _tf = (v && typeof v === 'object') ? v : (_tf || {}); }

                    });

                } catch (e) {}

            }



            var _tyranoGlobal = undefined;

            try {

                Object.defineProperty(window, 'TYRANO', {

                    configurable: true,

                    enumerable: true,

                    get: function() { return _tyranoGlobal; },

                    set: function(val) {

                        _tyranoGlobal = val;

                        if (val && val.kag) {

                            installVariableNullGuard(val.kag);

                        }

                    }

                });

            } catch (e) {}



            // 5.5 零额外请求的图片 GPU 纹理常驻池（仅保留游戏自然加载过的最近 36 张图片引用，彻底解决结束摸头/跨天切回房间时重新解码立绘导致的掉帧，且对启动速度 0 负担）

            var _decodedImagePinPool = [];

            var _decodedImagePinMap = {};

            var _PIN_POOL_MAX = 36;



            function pinLoadedImageElement(imgEl) {

                try {

                    if (!imgEl || !imgEl.src) return;

                    var src = String(imgEl.src);

                    if (!src || src.indexOf('data:') === 0 || _decodedImagePinMap[src]) return;

                    _decodedImagePinMap[src] = imgEl;

                    _decodedImagePinPool.push({ src: src, el: imgEl });

                    while (_decodedImagePinPool.length > _PIN_POOL_MAX) {

                        var old = _decodedImagePinPool.shift();

                        if (old && old.src) {

                            delete _decodedImagePinMap[old.src];

                        }

                    }

                } catch (e) {}

            }



            window.__tyranoTrimMemoryPool = function(keepCount) {

                var limit = typeof keepCount === 'number' ? keepCount : 8;

                while (_decodedImagePinPool.length > limit) {

                    var old = _decodedImagePinPool.shift();

                    if (old && old.src) {

                        delete _decodedImagePinMap[old.src];

                    }

                }

            };



            var SAVELOAD_EX_SAVE_HTML_FALLBACK = '<div class="save saveload_ex"><img class="menu_item menu_close" src="data/others/plugin/saveload_ex/image/back.png" /><div style="clear:both"></div><img class="button_smart button_arrow_up" src="data/others/plugin/saveload_ex/image/arrow_up.png" style="cursor:pointer;" /><img class="button_smart button_arrow_down" src="data/others/plugin/saveload_ex/image/arrow_down.png" style="cursor:pointer;" /><div class="area_page_list"></div><div class="area_save_list"><script class="save_list_item" type="text/x-jsrender"><ul class="save_list">{{for array_save}}<li class="save_display_area save_list_item" data-num="{{:num}}" data-page="{{:page}}"><span class="save_list_item_num">{{:num+1}}</span><span class="save_list_item_thumb">{{if img_data != ""}}<img src="{{:img_data}}">{{else}}<span class="no_image">NO DATA</span>{{/if}}</span><span class="save_list_item_area"><span class="save_list_item_date">{{:save_date}}</span><span class="save_list_item_text">{{:title}}</span></span><span class="save_list_item_Lock" data-num="{{:num}}" data-lock="{{:lock}}"></span><span class="save_list_item_delete" data-num="{{:num}}"></span><input class="save_list_item_comment" type="text" data-num="{{:num}}" placeholder="備註" value="{{:comment}}"></li>{{/for}}</ul></' + 'script></div><img class="img_bg_base" src="data/others/plugin/saveload_ex/image/bg_save.png" data-type="save" /></div>';

            var SAVELOAD_EX_LOAD_HTML_FALLBACK = '<div class="load saveload_ex"><img class="menu_item menu_close" src="data/others/plugin/saveload_ex/image/back.png" /><div style="clear:both"></div><img class="button_smart button_arrow_up" src="data/others/plugin/saveload_ex/image/arrow_up.png" style="cursor:pointer;" /><img class="button_smart button_arrow_down" src="data/others/plugin/saveload_ex/image/arrow_down.png" style="cursor:pointer;" /><div class="area_page_list"></div><div class="area_save_list"><script class="save_list_item" type="text/x-jsrender"><ul class="save_list">{{for array_save}}<li class="save_display_area save_list_item" data-num="{{:num}}" data-page="{{:page}}"><span class="save_list_item_num">{{:num+1}}</span><span class="save_list_item_thumb">{{if img_data != ""}}<img src="{{:img_data}}">{{else}}<span class="no_image">NO DATA</span>{{/if}}</span><span class="save_list_item_area"><span class="save_list_item_date">{{:save_date}}</span><span class="save_list_item_text">{{:title}}</span></span><span class="save_list_item_Lock" data-num="{{:num}}" data-lock="{{:lock}}"></span><span class="save_list_item_delete" data-num="{{:num}}"></span><input class="save_list_item_comment" type="text" data-num="{{:num}}" placeholder="備註" value="{{:comment}}"></li>{{/for}}</ul></' + 'script></div><img class="img_bg_base" src="data/others/plugin/saveload_ex/image/bg_load.png" data-type="load" /></div>';



            function getBuiltinHtmlFallback(pathStr) {

                var lower = String(pathStr || '').toLowerCase();

                if (lower.indexOf('saveload_ex') !== -1) {

                    if (lower.indexOf('save.html') !== -1) return SAVELOAD_EX_SAVE_HTML_FALLBACK;

                    if (lower.indexOf('load.html') !== -1) return SAVELOAD_EX_LOAD_HTML_FALLBACK;

                }

                return null;

            }



            function decodeSaveStr(raw) {

                if (raw === null || raw === undefined || raw === '' || raw === 'null' || raw === 'undefined') return null;

                var s = String(raw);

                if (s.charAt(0) === '{' || s.charAt(0) === '[') return s;

                try {

                    var decUri = decodeURIComponent(s);

                    if (decUri && (decUri.charAt(0) === '{' || decUri.charAt(0) === '[')) return decUri;

                } catch (e) {}

                try {

                    var u = unescape(s);

                    if (u && (u.charAt(0) === '{' || u.charAt(0) === '[')) return u;

                } catch (e) {}

                if (window.LZString) {

                    try {

                        var d1 = window.LZString.decompressFromBase64(s);

                        if (d1) {

                            if (d1.charAt(0) === '{' || d1.charAt(0) === '[') return d1;

                            var u1 = unescape(d1);

                            if (u1 && (u1.charAt(0) === '{' || u1.charAt(0) === '[')) return u1;

                        }

                    } catch (e) {}

                    try {

                        var d2 = window.LZString.decompressFromUTF16(s);

                        if (d2) {

                            if (d2.charAt(0) === '{' || d2.charAt(0) === '[') return d2;

                            var u2 = unescape(d2);

                            if (u2 && (u2.charAt(0) === '{' || u2.charAt(0) === '[')) return u2;

                        }

                    } catch (e) {}

                }

                return null;

            }



            function encodeSaveVal(val) {

                var json = typeof val === 'string' ? val : JSON.stringify(val);

                try { return encodeURIComponent(json); } catch (e) { return escape(json); }

            }



            // 剧本与界面模板纯内存缓存池：同一 .ks / .tjs / .html 模板在摸头结束、跨天或打开存读档界面时 0ms 直接从 JS 内存返回

            var _ksTextMemoryCache = {};



            function shieldTyranoJQueryInstance(jq) {

                if (!jq || typeof jq !== 'function' || jq.__tyranoWindowsShielded) return;

                jq.__tyranoWindowsShielded = true;

                try {

                    // (A) 永久锁定 $.isNWJS() 与 $.isElectron() 为 false（阻断 Windows 本地 .sav 分支）

                    Object.defineProperty(jq, 'isNWJS', {

                        configurable: true,

                        enumerable: true,

                        get: function() { return function() { return false; }; },

                        set: function() {}

                    });

                    Object.defineProperty(jq, 'isElectron', {

                        configurable: true,

                        enumerable: true,

                        get: function() { return function() { return false; }; },

                        set: function() {}

                    });



                    // (B) 接管所有存档读写函数（包括顶层 $.setStorage / $.getStorage），确保任何插件调用都 100% 落盘到 iOS 原生磁盘

                    var safeSetStorage = function(key, val) {

                        customLocalStorage.setItem(String(key), encodeSaveVal(val));

                    };

                    var safeGetStorage = function(key) {

                        return decodeSaveStr(customLocalStorage.getItem(String(key)));

                    };

                    var storageMethods = ['setStorage', 'setStorageWeb', 'setStorageCompress', 'setStorageFile'];

                    for (var sm = 0; sm < storageMethods.length; sm++) {

                        (function(mName) {

                            Object.defineProperty(jq, mName, {

                                configurable: true,

                                enumerable: true,

                                get: function() { return safeSetStorage; },

                                set: function() {}

                            });

                        })(storageMethods[sm]);

                    }

                    var getMethods = ['getStorage', 'getStorageWeb', 'getStorageCompress', 'getStorageFile'];

                    for (var gm = 0; gm < getMethods.length; gm++) {

                        (function(mName) {

                            Object.defineProperty(jq, mName, {

                                configurable: true,

                                enumerable: true,

                                get: function() { return safeGetStorage; },

                                set: function() {}

                            });

                        })(getMethods[gm]);

                    }



                    // (C) 强化 $.loadText：支持 .ks/.tjs/.html 内存缓存 + 异步失败时自动同步 XHR 重试 + 内置 saveload_ex 模板兜底

                    var _origLoadText = undefined;

                    var _safeLoadTextWrapper = function(file_path, callback) {

                        var pathStr = String(file_path || '');

                        var cleanKey = pathStr.split('?')[0].split('#')[0];

                        if (cleanKey.indexOf('./') === 0) cleanKey = cleanKey.slice(2);

                        var lowerPath = cleanKey.toLowerCase();

                        var isConfig = lowerPath.indexOf('config.tjs') !== -1;

                        var isCacheableText = isConfig || lowerPath.endsWith('.ks') || lowerPath.endsWith('.tjs') || lowerPath.endsWith('.html');



                        if (isCacheableText && Object.prototype.hasOwnProperty.call(_ksTextMemoryCache, cleanKey) && _ksTextMemoryCache[cleanKey]) {

                            var cachedStr = _ksTextMemoryCache[cleanKey];

                            setTimeout(function() {

                                try {

                                    if (window.TYRANO && window.TYRANO.kag) {

                                        installVariableNullGuard(window.TYRANO.kag);

                                    }

                                } catch (e) {}

                                if (callback) callback(cachedStr);

                            }, 0);

                            return;

                        }



                        var finalizeText = function(rawText) {

                            var outText = (typeof rawText === 'string') ? rawText : '';

                            if (!outText) {

                                var syncFallback = xhrReadLocalFileSync(cleanKey) || getBuiltinHtmlFallback(cleanKey);

                                if (syncFallback) outText = syncFallback;

                            }

                            if (isConfig && outText) {

                                outText = sanitizeConfigTextInMemory(outText);

                            }

                            if (isCacheableText && outText && outText.length > 0) {

                                _ksTextMemoryCache[cleanKey] = outText;

                            }

                            try {

                                if (window.TYRANO && window.TYRANO.kag) {

                                    installVariableNullGuard(window.TYRANO.kag);

                                    patchTyranoEngineAndPlugins();

                                }

                            } catch (e) {}

                            if (callback) callback(outText);

                        };



                        if (jq.ajax) {

                            jq.ajax({

                                url: cleanKey,

                                cache: true,

                                dataType: 'text',

                                success: function(text) {

                                    finalizeText(text);

                                },

                                error: function() {

                                    finalizeText('');

                                }

                            });

                            return;

                        }



                        if (typeof _origLoadText === 'function') {

                            return _origLoadText.call(jq, cleanKey, finalizeText);

                        }

                        finalizeText('');

                    };

                    _safeLoadTextWrapper.__tyranoLoadTextWrapper = true;



                    Object.defineProperty(jq, 'loadText', {

                        configurable: true,

                        enumerable: true,

                        get: function() {

                            return _safeLoadTextWrapper;

                        },

                        set: function(fn) {

                            if (typeof fn === 'function' && !fn.__tyranoLoadTextWrapper) {

                                _origLoadText = fn;

                            }

                        }

                    });

                } catch (e) {}

            }



            var _lockedJQuery = undefined;

            function isValidJQueryInstance(val) {

                return typeof val === 'function' && !!(val.fn && typeof val.fn === 'object');

            }



            try {

                Object.defineProperty(window, 'jQuery', {

                    configurable: true,

                    enumerable: true,

                    get: function() { return _lockedJQuery; },

                    set: function(val) {

                        if (isValidJQueryInstance(val)) {

                            _lockedJQuery = val;

                            shieldTyranoJQueryInstance(val);

                        } else if (!_lockedJQuery && val !== undefined && val !== null && typeof val === 'function') {

                            _lockedJQuery = val;

                        }

                    }

                });

                Object.defineProperty(window, '$', {

                    configurable: true,

                    enumerable: true,

                    get: function() { return _lockedJQuery; },

                    set: function(val) {

                        if (isValidJQueryInstance(val)) {

                            _lockedJQuery = val;

                            shieldTyranoJQueryInstance(val);

                        } else if (!_lockedJQuery && val !== undefined && val !== null && typeof val === 'function') {

                            _lockedJQuery = val;

                        }

                    }

                });

            } catch (e) {}



            // 6. CommonJS (window.require / module.exports) 与 Node.js / Electron / NW.js 核心模块模拟

            var pathModule = {

                sep: '/',

                delimiter: ':',

                join: function() {

                    var parts = Array.prototype.slice.call(arguments).filter(Boolean);

                    return collapseSlashes(parts.join('/'));

                },

                resolve: function() {

                    var parts = Array.prototype.slice.call(arguments).filter(Boolean);

                    return collapseSlashes(parts.join('/'));

                },

                dirname: function(p) {

                    var s = String(p || '');

                    var idx = s.lastIndexOf('/');

                    return idx === -1 ? '.' : (idx === 0 ? '/' : s.slice(0, idx));

                },

                basename: function(p, ext) {

                    var s = String(p || '').split('/').pop() || '';

                    if (ext && s.endsWith(ext)) {

                        return s.slice(0, s.length - ext.length);

                    }

                    return s;

                },

                extname: function(p) {

                    var b = String(p || '').split('/').pop() || '';

                    var idx = b.lastIndexOf('.');

                    return idx > 0 ? b.slice(idx) : '';

                },

                normalize: function(p) { return collapseSlashes(String(p || '')); }

            };



            var fsModule = {

                existsSync: function(p) {

                    var key = String(p || '');

                    if (isLegacyWindowsSaveFile(key)) {

                        return readSaveFromNative(key) !== null;

                    }

                    if (readSaveFromNative(key) !== null) return true;

                    if (getBuiltinHtmlFallback(key) !== null) return true;

                    return xhrReadLocalFileSync(key) !== null;

                },

                readFileSync: function(p, options) {

                    var key = String(p || '');

                    var saved = readSaveFromNative(key);

                    if (saved !== null) return saved;

                    if (isLegacyWindowsSaveFile(key)) {

                        return 'null';

                    }

                    var localText = xhrReadLocalFileSync(key);

                    if (localText !== null) return localText;

                    var fbHtml = getBuiltinHtmlFallback(key);

                    if (fbHtml !== null) return fbHtml;

                    return '';

                },

                writeFileSync: function(p, data) {

                    var key = String(p || '');

                    syncSaveToNative(key, data !== undefined && data !== null ? String(data) : '');

                },

                readFile: function(p, options, callback) {

                    var cb = typeof options === 'function' ? options : callback;

                    try {

                        var content = fsModule.readFileSync(p, options);

                        if (cb) setTimeout(function() { cb(null, content); }, 0);

                    } catch (err) {

                        if (cb) setTimeout(function() { cb(err, null); }, 0);

                    }

                },

                writeFile: function(p, data, options, callback) {

                    var cb = typeof options === 'function' ? options : callback;

                    fsModule.writeFileSync(p, data);

                    if (cb) setTimeout(function() { cb(null); }, 0);

                },

                mkdirSync: function() { return true; },

                mkdir: function(p, opt, cb) {

                    var fn = typeof opt === 'function' ? opt : cb;

                    if (fn) setTimeout(function() { fn(null); }, 0);

                },

                readdirSync: function() { return Object.keys(window.__TYRANO_NATIVE_SAVES__); },

                statSync: function() {

                    return {

                        isFile: function() { return true; },

                        isDirectory: function() { return true; },

                        mtime: new Date(),

                        size: 1024

                    };

                },

                unlinkSync: function(p) { removeSaveFromNative(String(p || '')); },

                accessSync: function() {},

                promises: {

                    readFile: function(p, opt) { return Promise.resolve(fsModule.readFileSync(p, opt)); },

                    writeFile: function(p, data) { fsModule.writeFileSync(p, data); return Promise.resolve(); },

                    mkdir: function() { return Promise.resolve(); },

                    stat: function() { return Promise.resolve(fsModule.statSync()); }

                }

            };



            var osModule = {

                platform: function() { return 'darwin'; },

                arch: function() { return 'arm64'; },

                homedir: function() { return '.'; },

                tmpdir: function() { return './tmp'; },

                release: function() { return '23.0.0'; },

                EOL: NL

            };



            var electronAppObj = {

                getPath: function(name) {

                    if (name === 'exe') return '/Applications/TyranoPlayer.app/Contents/MacOS/TyranoPlayer';

                    return '/Applications/' + String(name || 'userData');

                },

                getAppPath: function() { return '.'; },

                getName: function() { return 'TyranoGame'; },

                getVersion: function() { return '1.0.0'; },

                quit: function() {},

                exit: function() {}

            };



            var electronWinObj = {

                isFullScreen: function() { return false; },

                setFullScreen: function() {},

                maximize: function() {},

                unmaximize: function() {},

                minimize: function() {},

                restore: function() {},

                setSize: function() {},

                getSize: function() { return [window.innerWidth || 1280, window.innerHeight || 720]; },

                setTitle: function() {},

                setMenuBarVisibility: function() {},

                setAutoHideMenuBar: function() {},

                setContentSize: function() {},

                getContentSize: function() { return [window.innerWidth || 1280, window.innerHeight || 720]; },

                center: function() {},

                focus: function() {},

                show: function() {},

                close: function() {},

                on: function() { return this; },

                webContents: {

                    openDevTools: function() {},

                    on: function() {}

                }

            };



            var electronRemoteModule = {

                app: electronAppObj,

                getCurrentWindow: function() { return electronWinObj; },

                BrowserWindow: {

                    getFocusedWindow: function() { return electronWinObj; },

                    getAllWindows: function() { return [electronWinObj]; }

                },

                dialog: {

                    showMessageBoxSync: function(opt) {

                        if (opt && opt.message) { window.alert(opt.message); }

                        return 0;

                    },

                    showMessageBox: function(opt) {

                        if (opt && opt.message) { window.alert(opt.message); }

                        return Promise.resolve({ response: 0 });

                    }

                },

                shell: {

                    openExternal: function(url) { try { window.open(url); } catch (e) {} }

                }

            };



            var electronModule = {

                ipcRenderer: {

                    on: function() {},

                    once: function() {},

                    removeListener: function() {},

                    send: function() {},

                    sendSync: function(channel) {

                        if (String(channel).indexOf('path') !== -1) return '.';

                        return null;

                    },

                    invoke: function() { return Promise.resolve(null); }

                },

                remote: electronRemoteModule,

                app: electronAppObj,

                shell: electronRemoteModule.shell,

                webFrame: {

                    setZoomFactor: function() {},

                    getZoomFactor: function() { return 1; },

                    setVisualZoomLevelLimits: function() {},

                    setLayoutZoomLevelLimits: function() {}

                }

            };



            var nwGuiModule = {

                App: {

                    argv: [],

                    fullArgv: [],

                    dataPath: './saves_' + GAME_UUID,

                    manifest: { window: { title: 'TyranoPlayer' } },

                    quit: function() {},

                    closeAllWindows: function() {},

                    clearCache: function() {}

                },

                Window: {

                    get: function() {

                        return {

                            x: 0, y: 0,

                            width: window.innerWidth || 1280,

                            height: window.innerHeight || 720,

                            title: document.title || 'TyranoPlayer',

                            isFullscreen: false,

                            enterFullscreen: function() {},

                            leaveFullscreen: function() {},

                            toggleFullscreen: function() {},

                            resizeTo: function() {},

                            moveTo: function() {},

                            focus: function() {},

                            show: function() {},

                            hide: function() {},

                            close: function() {},

                            on: function() {},

                            once: function() {},

                            showDevTools: function() {}

                        };

                    }

                },

                Shell: {

                    openExternal: function(uri) { try { window.open(uri); } catch (e) {} }

                },

                Menu: function() {

                    this.append = function() {};

                    this.popup = function() {};

                    this.createMacBuiltin = function() {};

                },

                MenuItem: function() {},

                Clipboard: {

                    get: function() {

                        return { get: function() { return ''; }, set: function() {}, clear: function() {} };

                    }

                }

            };



            var builtinModules = {

                'fs': fsModule,

                'node:fs': fsModule,

                'path': pathModule,

                'node:path': pathModule,

                'os': osModule,

                'node:os': osModule,

                'electron': electronModule,

                '@electron/remote': electronRemoteModule,

                'nw.gui': nwGuiModule,

                'util': {

                    promisify: function(fn) {

                        return function() {

                            var args = Array.prototype.slice.call(arguments);

                            return new Promise(function(resolve, reject) {

                                args.push(function(err, res) {

                                    if (err) reject(err); else resolve(res);

                                });

                                fn.apply(null, args);

                            });

                        };

                    },

                    inherits: function() {},

                    format: function() { return Array.prototype.slice.call(arguments).join(' '); }

                },

                'events': {

                    EventEmitter: function() {

                        this.on = function() { return this; };

                        this.once = function() { return this; };

                        this.off = function() { return this; };

                        this.emit = function() { return false; };

                        this.removeListener = function() { return this; };

                    }

                },

                'crypto': {

                    randomBytes: function(size) {

                        var arr = new Uint8Array(size || 16);

                        if (window.crypto && window.crypto.getRandomValues) {

                            window.crypto.getRandomValues(arr);

                        }

                        return arr;

                    },

                    createHash: function() {

                        var content = '';

                        return {

                            update: function(d) { content += String(d); return this; },

                            digest: function() { return btoa(unescape(encodeURIComponent(content))).slice(0, 32); }

                        };

                    }

                },

                'buffer': {

                    Buffer: {

                        from: function(v) { return String(v || ''); },

                        isBuffer: function() { return false; },

                        alloc: function(n) { return new Uint8Array(n || 0); }

                    }

                }

            };



            var commonJSCache = {};



            var localProcessShim = {

                platform: 'darwin',

                arch: 'arm64',

                execPath: '/Applications/TyranoPlayer.app/Contents/MacOS/TyranoPlayer',

                resourcesPath: '/Applications/TyranoPlayer.app/Contents/Resources',

                helperExecPath: '/Applications/TyranoPlayer.app',

                argv: ['/Applications/TyranoPlayer.app/Contents/MacOS/TyranoPlayer'],

                versions: { node: '18.0.0', chrome: '114.0.0' },

                env: { NODE_ENV: 'production' },

                cwd: function() { return '.'; },

                nextTick: function(fn) { setTimeout(fn, 0); },

                on: function() { return this; },

                exit: function() {},

                mainModule: { filename: 'index.html', paths: [] }

            };



            function isJQueryCoreModulePath(idStr) {

                var lower = String(idStr || '').toLowerCase();

                if (lower === 'jquery') return true;

                if (lower.indexOf('jquery') !== -1 &&

                    lower.indexOf('migrate') === -1 &&

                    lower.indexOf('ui') === -1 &&

                    lower.indexOf('swipe') === -1 &&

                    lower.indexOf('a3d') === -1 &&

                    lower.indexOf('lettering') === -1 &&

                    lower.indexOf('textillate') === -1) {

                    return true;

                }

                return false;

            }



            window.require = function(moduleId) {

                var id = String(moduleId || '');

                if (isJQueryCoreModulePath(id) && (_lockedJQuery || window.jQuery || window.$)) {

                    return _lockedJQuery || window.jQuery || window.$;

                }

                if (Object.prototype.hasOwnProperty.call(builtinModules, id)) {

                    return builtinModules[id];

                }

                if (Object.prototype.hasOwnProperty.call(commonJSCache, id)) {

                    return commonJSCache[id].exports;

                }

                var candidates = [id, id + '.js', id + '.json', id + '/index.js'];

                for (var i = 0; i < candidates.length; i++) {

                    var candidate = candidates[i];

                    var src = xhrReadLocalFileSync(candidate);

                    if (src !== null) {

                        var mod = { id: candidate, exports: {} };

                        commonJSCache[id] = mod;

                        if (candidate.endsWith('.json')) {

                            try { mod.exports = JSON.parse(src); } catch (e) { mod.exports = {}; }

                        } else {

                            try {

                                var dir = pathModule.dirname(candidate);

                                var wrapper = new Function('exports', 'require', 'module', '__filename', '__dirname', 'process', src);

                                wrapper(mod.exports, window.require, mod, candidate, dir, localProcessShim);

                                if (isJQueryCoreModulePath(candidate)) {

                                    if (typeof mod.exports === 'function' && !mod.exports.fn) {

                                        try { mod.exports = mod.exports(window); } catch (eJq) {}

                                    }

                                    if (!isValidJQueryInstance(mod.exports) && (_lockedJQuery || window.jQuery)) {

                                        mod.exports = _lockedJQuery || window.jQuery;

                                    }

                                }

                            } catch (err) {

                                sendLog('WARN', ['[CommonJS] 模块执行异常已降级 (' + candidate + '):', String(err)]);

                            }

                        }

                        return mod.exports;

                    }

                }

                return {};

            };



            window.require.resolve = function(id) { return String(id); };

            window.require.cache = commonJSCache;



            try {

                window.module = undefined;

                window.exports = undefined;

                window.process = undefined;

                window.nw = undefined;

                window.studio_api = undefined;

            } catch (e) {}

            if (typeof window.__dirname === 'undefined') {

                window.__dirname = '.';

            }

            if (typeof window.__filename === 'undefined') {

                window.__filename = 'index.html';

            }

            if (typeof window.global === 'undefined') {

                window.global = window;

            }

            if (typeof window.Buffer === 'undefined') {

                window.Buffer = builtinModules['buffer'].Buffer;

            }

            window.close = function() {};



            // 7. 音视频与图片元素第 0 帧即刻加速：在 createElement / appendChild / insertBefore 阶段同步注入 playsinline 与 GPU 合成层，确保开幕动画从第 0 秒完整显示

            function enforceVideoVisibleAndPlayable(videoEl) {

                if (!videoEl || videoEl.__tyranoVideoEnhanced) return;

                videoEl.__tyranoVideoEnhanced = true;

                try {

                    videoEl.setAttribute('playsinline', '');

                    videoEl.setAttribute('webkit-playsinline', '');

                    videoEl.playsInline = true;

                    videoEl.preload = 'auto';



                    var fixVideoLayer = function() {

                        try {

                            videoEl.style.webkitTransform = 'translateZ(0)';

                            videoEl.style.transform = 'translateZ(0)';

                            videoEl.style.objectFit = 'contain';

                            if (videoEl.id === 'bgmovie') {

                                videoEl.style.pointerEvents = 'none';

                            }

                        } catch (eStyle) {}

                    };



                    videoEl.addEventListener('loadedmetadata', fixVideoLayer);

                    videoEl.addEventListener('play', fixVideoLayer);

                    videoEl.addEventListener('ended', function() {

                        if (!videoEl.loop) {

                            videoEl.style.pointerEvents = 'none';

                        }

                    });

                    fixVideoLayer();



                    var origPlay = videoEl.play;

                    if (typeof origPlay === 'function') {

                        videoEl.play = function() {

                            fixVideoLayer();

                            var p = origPlay.apply(videoEl, arguments);

                            if (p && typeof p.catch === 'function') {

                                return p.catch(function(err) {

                                    videoEl.muted = true;

                                    var unlockAudio = function() {

                                        videoEl.muted = false;

                                        document.removeEventListener('touchstart', unlockAudio, true);

                                        document.removeEventListener('click', unlockAudio, true);

                                    };

                                    document.addEventListener('touchstart', unlockAudio, true);

                                    document.addEventListener('click', unlockAudio, true);

                                    return origPlay.apply(videoEl, arguments).catch(function() {

                                        videoEl.style.pointerEvents = 'none';

                                        try { videoEl.dispatchEvent(new Event('ended')); } catch (e2) {}

                                    });

                                });

                            }

                            return p;

                        };

                    }



                    videoEl.addEventListener('error', function() {

                        var src = videoEl.getAttribute('src') || videoEl.src || '';

                        var cleanSrc = src.split('?')[0].toLowerCase();

                        if ((cleanSrc.endsWith('.webm') || cleanSrc.endsWith('.ogv')) && !videoEl.dataset.videoFallbackTried) {

                            videoEl.dataset.videoFallbackTried = 'mp4';

                            var dotIdx = src.lastIndexOf('.');

                            if (dotIdx !== -1) {

                                videoEl.src = src.slice(0, dotIdx) + '.mp4';

                                videoEl.load();

                                videoEl.play().catch(function(){});

                                return;

                            }

                        }

                        videoEl.style.pointerEvents = 'none';

                        try { videoEl.dispatchEvent(new Event('ended')); } catch (e) {}

                    }, true);

                } catch (e) {}

            }



            function enhanceMediaNodeTree(node) {

                try {

                    if (!node || node.nodeType !== 1) return;

                    var tag = String(node.tagName || '').toUpperCase();

                    if (tag === 'VIDEO') {

                        enforceVideoVisibleAndPlayable(node);

                    } else if (tag === 'IMG') {

                        if (!node.__tyranoImgHooked) {

                            node.__tyranoImgHooked = true;

                            node.decoding = 'async';

                            node.addEventListener('load', function() { pinLoadedImageElement(node); }, { once: true });

                        }

                    } else if (node.querySelectorAll) {

                        var vids = node.querySelectorAll('video');

                        for (var v = 0; v < vids.length; v++) {

                            enforceVideoVisibleAndPlayable(vids[v]);

                        }

                    }

                } catch (e) {}

            }



            // 同步拦截 appendChild 与 insertBefore：哪怕通过 jQuery $('<video>') 插入节点，也在挂载瞬间（第 0 帧前）完成硬件加速配置

            var origAppendChild = Element.prototype.appendChild;

            Element.prototype.appendChild = function(child) {

                enhanceMediaNodeTree(child);

                return origAppendChild.call(this, child);

            };

            var origInsertBefore = Element.prototype.insertBefore;

            Element.prototype.insertBefore = function(newNode, refNode) {

                enhanceMediaNodeTree(newNode);

                return origInsertBefore.call(this, newNode, refNode);

            };



            var origCreateElement = document.createElement.bind(document);

            document.createElement = function(tagName) {

                var el = origCreateElement(tagName);

                if (typeof tagName === 'string') {

                    var lower = tagName.toLowerCase();

                    if (lower === 'video') {

                        enforceVideoVisibleAndPlayable(el);

                    } else if (lower === 'img') {

                        el.__tyranoImgHooked = true;

                        el.decoding = 'async';

                        el.addEventListener('load', function() { pinLoadedImageElement(el); }, { once: true });

                    } else if (lower === 'audio') {

                        el.preload = 'auto';

                        el.addEventListener('error', function() {

                            var src = el.getAttribute('src') || el.src || '';

                            var cleanSrc = src.split('?')[0].toLowerCase();

                            if (cleanSrc.endsWith('.ogg') && !el.dataset.fallbackTried) {

                                el.dataset.fallbackTried = 'm4a';

                                el.src = src.slice(0, src.toLowerCase().lastIndexOf('.ogg')) + '.m4a';

                                el.load();

                                el.play().catch(function(){});

                            } else if (el.dataset.fallbackTried === 'm4a' && src.toLowerCase().lastIndexOf('.m4a') !== -1) {

                                el.dataset.fallbackTried = 'mp3';

                                el.src = src.slice(0, src.toLowerCase().lastIndexOf('.m4a')) + '.mp3';

                                el.load();

                                el.play().catch(function(){});

                            } else if (!el.dataset.degradedNotified) {

                                el.dataset.degradedNotified = 'true';

                                try { el.dispatchEvent(new Event('ended')); } catch (e) {}

                            }

                        }, true);

                    }

                }

                return el;

            };



            // 8. 深度挂钩 TyranoScript 变量初始化

            function ensureKagVariableInitialized() {

                try {

                    if (window.TYRANO && window.TYRANO.kag) {

                        var kag = window.TYRANO.kag;

                        if (!kag.variable || typeof kag.variable !== 'object') {

                            kag.variable = { sf: {}, f: {}, tf: {}, mp: {} };

                        }

                        if (!kag.variable.sf || typeof kag.variable.sf !== 'object') {

                            kag.variable.sf = {};

                        }

                        if (typeof kag.variable.sf._system_config_bgm_volume === 'undefined') {

                            kag.variable.sf._system_config_bgm_volume = 100;

                        }

                        if (typeof kag.variable.sf._system_config_se_volume === 'undefined') {

                            kag.variable.sf._system_config_se_volume = 100;

                        }

                    }

                } catch (e) {}

            }



            var _patchedTyranoIfTags = false;

            function patchTyranoEngineAndPlugins() {

                try {

                    if (!window.TYRANO || !window.TYRANO.kag) return;

                    var kag = window.TYRANO.kag;

                    installVariableNullGuard(kag);



                    // (1) 防止 TYRANO.kag.html 将空字符串缓存在 cache_html 中导致存读档菜单空白无响应

                    if (kag.html && !kag.__tyranoHtmlPatched) {

                        kag.__tyranoHtmlPatched = true;

                        var _origKagHtml = kag.html;

                        kag.html = function(html_file_name, data, callback) {

                            var that = this;

                            if (this.cache_html && this.cache_html[html_file_name] === '') {

                                delete this.cache_html[html_file_name];

                            }

                            return _origKagHtml.call(that, html_file_name, data, function(html_str) {

                                if (!html_str || String(html_str).trim() === '') {

                                    if (that.cache_html) delete that.cache_html[html_file_name];

                                    var fb = getBuiltinHtmlFallback('saveload_ex/' + html_file_name + '.html');

                                    if (fb && window.jQuery && window.jQuery.templates) {

                                        try {

                                            var tmpl = window.jQuery.templates(fb);

                                            html_str = tmpl.render(data || {});

                                        } catch (e) {}

                                    }

                                }

                                if (typeof callback === 'function') callback(html_str);

                            });

                        };

                    }



                    // (2) 修复 TF/pre/macro_TF.ks:557行目:If文に誤りがあります（跨宏 [jump] 导致 stack['if'] 的 deep_if 偏移时自动按相对嵌套层级自愈）

                    if (kag.ftag && kag.ftag.master_tag && !_patchedTyranoIfTags) {

                        var mt = kag.ftag.master_tag;

                        if (mt['if'] && mt['elsif'] && mt['else'] && mt['endif']) {

                            _patchedTyranoIfTags = true;



                            var jumpToMatchingIfBranch = function(kagInst, targetMap, startDeep) {

                                var ftag = kagInst.ftag;

                                var arrayTag = ftag.array_tag || [];

                                var startIdx = ftag.current_order_index;



                                // 第一遍：按原生 deep_if 精确匹配

                                for (var i = 0; i < 2000; i++) {

                                    ftag.current_order_index++;

                                    if (ftag.current_order_index >= arrayTag.length) break;

                                    var tag = arrayTag[ftag.current_order_index];

                                    if (!tag) break;

                                    if (tag.name === 'endif' && tag.deep_if == startDeep) {

                                        if (targetMap['endif']) {

                                            kagInst.popStack('if');

                                            ftag.nextOrder();

                                            return true;

                                        }

                                        break;

                                    } else if (targetMap[tag.name] && tag.deep_if == startDeep) {

                                        ftag.current_order_index--;

                                        ftag.nextOrder();

                                        return true;

                                    }

                                }



                                // 第二遍：因之前在 [if] 块内执行了 [jump] 导致 deep_if 失步时，按相对 [if]...[endif] 嵌套层级自愈匹配

                                var nest = 0;

                                for (var idx = startIdx + 1; idx < arrayTag.length; idx++) {

                                    var t = arrayTag[idx];

                                    if (!t) continue;

                                    if (t.name === 'if') {

                                        nest++;

                                    } else if (t.name === 'endif') {

                                        if (nest === 0) {

                                            ftag.current_order_index = idx;

                                            if (kagInst.getStack('if')) kagInst.popStack('if');

                                            sendLog('WARN', ['[脚本自愈] 已自动修复跨宏跳转导致的 If 栈深度偏移 (line ' + (t.line || '') + ')']);

                                            ftag.nextOrder();

                                            return true;

                                        }

                                        nest--;

                                    } else if ((t.name === 'elsif' || t.name === 'else') && nest === 0 && targetMap[t.name]) {

                                        var topSt = kagInst.getStack('if');

                                        if (topSt) {

                                            topSt.deep = t.deep_if;

                                        } else {

                                            kagInst.pushStack('if', { bool: false, deep: t.deep_if });

                                        }

                                        ftag.current_order_index = idx - 1;

                                        ftag.nextOrder();

                                        return true;

                                    }

                                }



                                ftag.current_order_index = Math.min(startIdx + 1, Math.max(0, arrayTag.length - 1));

                                ftag.nextOrder();

                                return true;

                            };



                            mt['if'].start = function(pm) {

                                var bool = false;

                                try { bool = this.kag.embScript(pm.exp); } catch (e) { bool = false; }

                                if (bool) {

                                    this.kag.pushStack('if', { bool: true, deep: pm.deep_if });

                                    this.kag.ftag.nextOrder();

                                } else {

                                    this.kag.pushStack('if', { bool: false, deep: pm.deep_if });

                                    jumpToMatchingIfBranch(this.kag, { 'else': 1, 'elsif': 1, 'endif': 1 }, pm.deep_if);

                                }

                            };



                            mt['elsif'].start = function(pm) {

                                var stackIf = this.kag.getStack('if');

                                if (!stackIf) {

                                    stackIf = { bool: false, deep: pm.deep_if };

                                    this.kag.pushStack('if', stackIf);

                                } else if (stackIf.deep != pm.deep_if) {

                                    stackIf.deep = pm.deep_if;

                                }

                                if (stackIf.bool === false) {

                                    var bool = false;

                                    try { bool = this.kag.embScript(pm.exp); } catch (e) { bool = false; }

                                    if (bool) {

                                        this.kag.setStack('if', { bool: true, deep: pm.deep_if });

                                        this.kag.ftag.nextOrder();

                                        return;

                                    }

                                }

                                jumpToMatchingIfBranch(this.kag, { 'else': 1, 'elsif': 1, 'endif': 1 }, pm.deep_if);

                            };



                            mt['else'].start = function(pm) {

                                var stackIf = this.kag.getStack('if');

                                if (!stackIf) {

                                    stackIf = { bool: false, deep: pm.deep_if };

                                    this.kag.pushStack('if', stackIf);

                                } else if (stackIf.deep != pm.deep_if) {

                                    stackIf.deep = pm.deep_if;

                                }

                                if (stackIf.bool === false) {

                                    this.kag.setStack('if', { bool: true, deep: pm.deep_if });

                                    this.kag.ftag.nextOrder();

                                } else {

                                    jumpToMatchingIfBranch(this.kag, { 'endif': 1 }, pm.deep_if);

                                }

                            };



                            mt['endif'].start = function() {

                                if (this.kag.getStack('if')) {

                                    this.kag.popStack('if');

                                }

                                this.kag.ftag.nextOrder();

                            };

                        }

                    }



                    // (3) 增强 TYRANO.kag.menu (修复 saveload_ex 插件在 that.snap 为 null 或缩略图超时导致存档失败的问题)

                    if (kag.menu && kag.menu.doSave && !kag.menu.__tyranoSaveMenuPatched) {

                        var menu = kag.menu;

                        var isSaveloadReady = (kag.variable && kag.variable.sf && kag.variable.sf._saveload) ||

                                              (String(menu.doSave).indexOf('comment') !== -1) ||

                                              document.readyState === 'complete';

                        if (isSaveloadReady) {

                            menu.__tyranoSaveMenuPatched = true;

                            var ensureSaveloadConfig = function() {

                                try {

                                    if (!kag.variable) kag.variable = {};

                                    if (!kag.variable.sf) kag.variable.sf = {};

                                    if (!kag.variable.sf._saveload) {

                                        kag.variable.sf._saveload = {

                                            memory: false, quick: 1, exsave: 0, Slot: 0, style: 1, Page: 20,

                                            slot_var: '', dialog: false, dialog_overwrite: false,

                                            save_sound: '', load_sound: '', fade_time: 0

                                        };

                                    }

                                } catch (e) {}

                            };

                            var buildFallbackSnap = function(titleStr) {

                                var jq = window.jQuery || window.$;

                                var _stat = (kag.stat && jq && jq.cloneObject) ? jq.extend(true, {}, jq.cloneObject(kag.stat)) : (kag.stat || {});

                                var _three = (kag.tmp && kag.tmp.three && jq && jq.cloneObject) ? jq.extend(true, {}, jq.cloneObject(kag.tmp.three)) : {};

                                var nowStr = (jq && jq.getNowDate && jq.getNowTime) ? (jq.getNowDate() + '　' + jq.getNowTime()) : new Date().toLocaleString();

                                return {

                                    title: titleStr || (kag.stat && kag.stat.current_save_str) || 'Save',

                                    current_order_index: (kag.ftag && kag.ftag.current_order_index) || 0,

                                    save_date: nowStr,

                                    img_data: TRANSPARENT_PLACEHOLDER_PNG,

                                    stat: _stat,

                                    three: _three,

                                    layer: { map_layer_fore: {}, map_layer_back: {} }

                                };

                            };



                            var _origSnapSave = menu.snapSave;

                            menu.snapSave = function(title, call_back, flag_thumb) {

                                var that = this;

                                ensureSaveloadConfig();

                                var done = false;

                                var timer = setTimeout(function() {

                                    if (!done) {

                                        done = true;

                                        if (!that.snap) that.snap = buildFallbackSnap(title);

                                        if (typeof call_back === 'function') call_back();

                                    }

                                }, 700);

                                try {

                                    _origSnapSave.call(that, title, function() {

                                        if (!done) {

                                            done = true;

                                            clearTimeout(timer);

                                            if (!that.snap) that.snap = buildFallbackSnap(title);

                                            if (typeof call_back === 'function') call_back();

                                        }

                                    }, flag_thumb);

                                } catch (e) {

                                    if (!done) {

                                        done = true;

                                        clearTimeout(timer);

                                        that.snap = buildFallbackSnap(title);

                                        if (typeof call_back === 'function') call_back();

                                    }

                                }

                            };



                            var _origDoSave = menu.doSave;

                            menu.doSave = function(num, cb) {

                                var that = this;

                                ensureSaveloadConfig();

                                if (!that.snap) {

                                    that.snap = buildFallbackSnap((kag.stat && kag.stat.current_save_str) || 'Save');

                                }

                                try {

                                    var r = _origDoSave.call(that, num, function(saveData) {

                                        try { kag.saveSystemVariable(); } catch (e) {}

                                        if (typeof cb === 'function') cb(saveData);

                                    });

                                    try { kag.saveSystemVariable(); } catch (e) {}

                                    return r;

                                } catch (err) {

                                    sendLog('WARN', ['[存档保护] doSave 异常，已执行安全存档写入:', String(err)]);

                                    try {

                                        var jq = window.jQuery || window.$;

                                        var arraySave = that.getSaveData();

                                        var data = that.snap || buildFallbackSnap('Save');

                                        data.save_date = (jq && jq.getNowDate && jq.getNowTime) ? (jq.getNowDate() + '　' + jq.getNowTime()) : new Date().toLocaleString();

                                        data.lock = (arraySave.data[num] && arraySave.data[num].lock) || false;

                                        data.comment = (arraySave.data[num] && arraySave.data[num].comment) || '';

                                        arraySave.data[num] = data;

                                        jq.setStorage(kag.config.projectID + '_tyrano_data', arraySave, kag.config.configSave);

                                        kag.saveSystemVariable();

                                        if (typeof cb === 'function') cb(data);

                                    } catch (e2) {}

                                }

                            };

                        }

                    }

                } catch (e) {}

            }



            function hookTyranoStorageAndSF() {

                injectEarlyBaseCSS();

                ensureKagVariableInitialized();

                if (_lockedJQuery) {

                    shieldTyranoJQueryInstance(_lockedJQuery);

                }

                patchTyranoEngineAndPlugins();

            }



            var _enginePatchInterval = setInterval(function() {

                hookTyranoStorageAndSF();

            }, 350);

            setTimeout(function() { clearInterval(_enginePatchInterval); }, 30000);



            window.__tyranoHookStorageAndSF = hookTyranoStorageAndSF;

            hookTyranoStorageAndSF();

            window.addEventListener('load', hookTyranoStorageAndSF, true);

            document.addEventListener('DOMContentLoaded', hookTyranoStorageAndSF, true);

        })();

        """



        let postloadViewportJS = """

        (function() {

            if (typeof window.__tyranoHookStorageAndSF === 'function') {

                window.__tyranoHookStorageAndSF();

            }



            var meta = document.querySelector('meta[name="viewport"]');

            if (!meta) {

                meta = document.createElement('meta');

                meta.name = 'viewport';

                document.head.appendChild(meta);

            }

            meta.content = 'width=device-width, initial-scale=1.0, minimum-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover';



            window.__tyranoStretchMode = false;



            window.__tyranoApplyStretch = function() {

                var target = document.getElementById('tyrano_base') || document.querySelector('.tyrano_base');

                if (!target) return;

                if (window.__tyranoStretchMode) {

                    var scWidth = parseFloat(target.style.width) || target.clientWidth || 1280;

                    var scHeight = parseFloat(target.style.height) || target.clientHeight || 720;

                    var scaleX = window.innerWidth / scWidth;

                    var scaleY = window.innerHeight / scHeight;

                    target.style.transformOrigin = '0 0';

                    target.style.transform = 'scale(' + scaleX + ', ' + scaleY + ')';

                    target.style.left = '0px';

                    target.style.top = '0px';

                    target.style.margin = '0px';

                } else {

                    target.style.left = '';

                    target.style.top = '';

                }

            };



            window.__tyranoSetFullScreen = function(stretch) {

                window.__tyranoStretchMode = !!stretch;

                window.__tyranoFixViewport();

            };



            window.__tyranoFixViewport = function() {

                window.scrollTo(0, 0);

                if (typeof window.__tyranoHookStorageAndSF === 'function') {

                    window.__tyranoHookStorageAndSF();

                }

                try {

                    if (window.Howler && window.Howler.ctx && window.Howler.ctx.state !== 'running') {

                        window.Howler.ctx.resume();

                    }

                } catch (e) {}



                if (window.__tyranoResizingGuard) return;

                window.__tyranoResizingGuard = true;

                try {

                    if (window.TYRANO && window.TYRANO.kag && window.TYRANO.kag.view && typeof window.TYRANO.kag.view.resizeScreen === 'function') {

                        window.TYRANO.kag.view.resizeScreen();

                    } else {

                        window.dispatchEvent(new Event('resize'));

                    }

                    window.__tyranoApplyStretch();

                } catch (e) {

                } finally {

                    window.__tyranoResizingGuard = false;

                }

            };

        })();

        """



        contentController.addUserScript(WKUserScript(source: preloadCompatJS, injectionTime: .atDocumentStart, forMainFrameOnly: false))

        contentController.addUserScript(WKUserScript(source: postloadViewportJS, injectionTime: .atDocumentEnd, forMainFrameOnly: false))



        let webView = WKWebView(frame: .zero, configuration: config)

        webView.navigationDelegate = context.coordinator

        webView.uiDelegate = context.coordinator

        context.coordinator.webView = webView



        webView.isOpaque = false

        webView.backgroundColor = .black

        webView.scrollView.backgroundColor = .black

        webView.scrollView.isScrollEnabled = false

        webView.scrollView.bounces = false

        webView.scrollView.bouncesZoom = false

        webView.scrollView.minimumZoomScale = 1.0

        webView.scrollView.maximumZoomScale = 1.0

        webView.scrollView.contentInsetAdjustmentBehavior = .never

        webView.allowsBackForwardNavigationGestures = false



        if #available(iOS 16.4, *) {

            webView.isInspectable = true

        }



        context.coordinator.lastReloadTrigger = reloadTrigger

        context.coordinator.lastLayoutFixTrigger = layoutFixTrigger

        context.coordinator.lastStretchState = isFullScreenStretch

        if let httpURL = LocalGameHTTPServer.shared.startAndMakeEntryURL(rootDirectoryURL: readAccessURL, entryHTMLURL: entryHTMLURL) {

            AppLogger.shared.append(level: .log, category: "HTTP", message: "本机 HTTP 资源服务已就绪: \(httpURL.absoluteString)")

            webView.load(URLRequest(url: httpURL))

        } else {

            webView.loadFileURL(entryHTMLURL, allowingReadAccessTo: readAccessURL)

        }



        return webView

    }



    func updateUIView(_ webView: WKWebView, context: Context) {

        if context.coordinator.lastReloadTrigger != reloadTrigger {

            context.coordinator.lastReloadTrigger = reloadTrigger

            Self.configureAudioSession()

            context.coordinator.reloadSaveDictFromDisk()

            let latestJSON = Self.loadInitialSaveJSON(from: nativeSaveStoreURL)

            let syncBackupScript = WKUserScript(

                source: "window.__TYRANO_NATIVE_SAVES__ = \(latestJSON);",

                injectionTime: .atDocumentStart,

                forMainFrameOnly: false

            )

            webView.configuration.userContentController.addUserScript(syncBackupScript)

            if let httpURL = LocalGameHTTPServer.shared.startAndMakeEntryURL(rootDirectoryURL: readAccessURL, entryHTMLURL: entryHTMLURL) {

                webView.load(URLRequest(url: httpURL))

            } else {

                webView.loadFileURL(entryHTMLURL, allowingReadAccessTo: readAccessURL)

            }

        }



        if context.coordinator.lastStretchState != isFullScreenStretch {

            context.coordinator.lastStretchState = isFullScreenStretch

            let flag = isFullScreenStretch ? "true" : "false"

            webView.evaluateJavaScript("if (typeof window.__tyranoSetFullScreen === 'function') { window.__tyranoSetFullScreen(\(flag)); }", completionHandler: nil)

        }



        if context.coordinator.lastLayoutFixTrigger != layoutFixTrigger {

            context.coordinator.lastLayoutFixTrigger = layoutFixTrigger

            Self.configureAudioSession()

            Self.repairWebViewViewport(webView, stretch: isFullScreenStretch)

        }



        if let jsCommand = pendingJSCommand {

            DispatchQueue.main.async {

                self.pendingJSCommand = nil

            }

            context.coordinator.log(level: .log, message: "> \(jsCommand)")

            webView.evaluateJavaScript(jsCommand) { result, error in

                if let error {

                    context.coordinator.log(level: .error, message: error.localizedDescription)

                } else if let result {

                    context.coordinator.log(level: .log, message: "<- \(String(describing: result))")

                }

            }

        }

    }



    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {

        uiView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.consoleHandlerName)

        uiView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.storageHandlerName)

    }



    static func configureAudioSession() {

        do {

            let session = AVAudioSession.sharedInstance()

            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])

            try session.setActive(true)

        } catch {}

    }



    static func repairWebViewViewport(_ webView: WKWebView, stretch: Bool) {

        webView.scrollView.setZoomScale(1.0, animated: false)

        webView.scrollView.setContentOffset(.zero, animated: false)

        webView.scrollView.contentInset = .zero

        webView.setNeedsLayout()

        webView.layoutIfNeeded()



        let flag = stretch ? "true" : "false"

        webView.evaluateJavaScript("""

        if (typeof window.__tyranoSetFullScreen === 'function') {

            window.__tyranoSetFullScreen(\(flag));

        } else if (typeof window.__tyranoFixViewport === 'function') {

            window.__tyranoFixViewport();

        }

        """, completionHandler: nil)

    }



    @MainActor

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {

        static let consoleHandlerName = "tyranoConsole"

        static let storageHandlerName = "tyranoStorage"



        weak var webView: WKWebView?

        let nativeSaveStoreURL: URL

        var saveDict: [String: String] = [:]

        var lastReloadTrigger: UUID?

        var lastLayoutFixTrigger: UUID?

        var lastStretchState: Bool = false

        private var saveWriteWorkItem: DispatchWorkItem?

        private var lastProcessTerminateAt: Date = .distantPast

        private let saveIOQueue = DispatchQueue(label: "com.tyrano.save.io", qos: .utility)

        let onConsoleLog: (ConsoleLogEntry) -> Void



        init(nativeSaveStoreURL: URL, onConsoleLog: @escaping (ConsoleLogEntry) -> Void) {

            self.nativeSaveStoreURL = nativeSaveStoreURL

            self.onConsoleLog = onConsoleLog

            super.init()

            reloadSaveDictFromDisk()

            NotificationCenter.default.addObserver(

                self,

                selector: #selector(handleSystemMemoryWarning),

                name: UIApplication.didReceiveMemoryWarningNotification,

                object: nil

            )

            NotificationCenter.default.addObserver(

                self,

                selector: #selector(handleAppWillResignActive),

                name: UIApplication.willResignActiveNotification,

                object: nil

            )

        }



        @objc private func handleAppWillResignActive() {

            persistSaveDict(immediate: true)

        }



        deinit {

            NotificationCenter.default.removeObserver(self)

        }



        @objc private func handleSystemMemoryWarning() {

            log(level: .warn, message: "[内存保护] 收到系统低内存告警，正在主动清理缓存池以防游戏重启…")

            LocalGameHTTPServer.shared.clearMemoryCaches()

            webView?.evaluateJavaScript("if (typeof window.__tyranoTrimMemoryPool === 'function') { window.__tyranoTrimMemoryPool(6); }", completionHandler: nil)

        }



        func reloadSaveDictFromDisk() {

            if let data = try? Data(contentsOf: nativeSaveStoreURL),

               let loaded = try? JSONSerialization.jsonObject(with: data) as? [String: String] {

                self.saveDict = loaded

            } else {

                self.saveDict = [:]

            }

            LocalGameHTTPServer.shared.replaceLiveSaves(self.saveDict)

        }



        func log(level: ConsoleLogLevel, message: String) {

            onConsoleLog(ConsoleLogEntry(timestamp: Date(), level: level, message: message))

        }



        private func persistSaveDict(immediate: Bool = false) {

            saveWriteWorkItem?.cancel()

            let snapshot = self.saveDict

            LocalGameHTTPServer.shared.replaceLiveSaves(snapshot)

            let targetURL = self.nativeSaveStoreURL

            let writeBlock: @Sendable () -> Void = {

                let dir = targetURL.deletingLastPathComponent()

                if !FileManager.default.fileExists(atPath: dir.path) {

                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

                }

                if let data = try? JSONSerialization.data(withJSONObject: snapshot, options: []) {

                    try? data.write(to: targetURL, options: .atomic)

                }

            }

            if immediate {

                saveIOQueue.async(execute: writeBlock)

            } else {

                let item = DispatchWorkItem(block: writeBlock)

                saveWriteWorkItem = item

                saveIOQueue.asyncAfter(deadline: .now() + 0.25, execute: item)

            }

        }



        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {

            if message.name == Self.consoleHandlerName {

                guard let body = message.body as? [String: Any],

                      let levelStr = body["level"] as? String,

                      let text = body["message"] as? String else {

                    return

                }

                let level = ConsoleLogLevel(rawValue: levelStr) ?? .log

                log(level: level, message: text)

                return

            }



            if message.name == Self.storageHandlerName {

                guard let body = message.body as? [String: Any],

                      let action = body["action"] as? String else {

                    return

                }

                switch action {

                case "set":

                    if let key = body["key"] as? String, let val = body["value"] as? String {

                        saveDict[key] = val

                        if let shortKey = body["shortKey"] as? String, !shortKey.isEmpty {

                            saveDict[shortKey] = val

                        }

                        persistSaveDict()

                    }

                case "remove":

                    if let key = body["key"] as? String {

                        saveDict.removeValue(forKey: key)

                    }

                    if let shortKey = body["shortKey"] as? String {

                        saveDict.removeValue(forKey: shortKey)

                    }

                    persistSaveDict()

                case "clear":

                    saveDict.removeAll()

                    persistSaveDict()

                default:

                    break

                }

            }

        }



        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {

            log(level: .log, message: "[WebKit] 已加载: \(webView.url?.lastPathComponent ?? "index.html") (存档键数量: \(saveDict.count))")

            WebPlayerView.repairWebViewViewport(webView, stretch: lastStretchState)

        }



        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {

            persistSaveDict(immediate: true)

            LocalGameHTTPServer.shared.clearMemoryCaches()

            let now = Date()

            guard now.timeIntervalSince(lastProcessTerminateAt) > 3.0 else {

                log(level: .error, message: "[WebKit] 渲染进程短时间内重复终止，已暂停自动重载以防死循环")

                return

            }

            lastProcessTerminateAt = now

            log(level: .warn, message: "[WebKit] 渲染进程因系统内存压力回收，已保存最新进度并自动恢复…")

            let latestJSON = WebPlayerView.loadInitialSaveJSON(from: nativeSaveStoreURL)

            let syncBackupScript = WKUserScript(

                source: "window.__TYRANO_NATIVE_SAVES__ = \(latestJSON);",

                injectionTime: .atDocumentStart,

                forMainFrameOnly: false

            )

            webView.configuration.userContentController.addUserScript(syncBackupScript)

            webView.reload()

        }



        func webView(

            _ webView: WKWebView,

            runJavaScriptAlertPanelWithMessage message: String,

            initiatedByFrame frame: WKFrameInfo,

            completionHandler: @escaping @MainActor () -> Void

        ) {

            log(level: .warn, message: "[JS Alert] \(message)")

            guard let presenter = Self.topViewController() else {

                completionHandler()

                return

            }

            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)

            alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler() })

            presenter.present(alert, animated: true)

        }



        func webView(

            _ webView: WKWebView,

            runJavaScriptConfirmPanelWithMessage message: String,

            initiatedByFrame frame: WKFrameInfo,

            completionHandler: @escaping @MainActor (Bool) -> Void

        ) {

            log(level: .warn, message: "[JS Confirm] \(message)")

            guard let presenter = Self.topViewController() else {

                completionHandler(true)

                return

            }

            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)

            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })

            alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })

            presenter.present(alert, animated: true)

        }



        private static func topViewController() -> UIViewController? {

            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,

                  var top = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {

                return nil

            }

            while let presented = top.presentedViewController {

                top = presented

            }

            return top

        }

    }

}



/// 高性能本机 HTTP 游戏资源服务器（v1.8.0 长时间游玩防崩与存档增强版）：

/// 1. 自动将 iOS 进程文件描述符上限从默认 256 提升至 4096，并移除 .mappedIfSafe 句柄驻留，彻底解决游玩 15~20 分钟后 status.png / save.html 突然报 file not found 的问题

/// 2. 消除 2 秒空闲超时断开 Keep-Alive 引起的连接重置竞争，确保阅读对话后点击存读档 100% 稳定加载

/// 3. 对缺失的可选图标（如 button_menu.png 或拼写差异的 culumn1.png）直接返回 200 OK 1x1 透明 PNG，从根源上防止 img.onerror 导致右侧操作按钮消失无响应

/// 4. 提供 /__tyrano_native_saves__.json 实时存档同步端点，确保游戏内返回标题或重载页面绝不丢失当前会话新存档

final class LocalGameHTTPServer: @unchecked Sendable {

    static let shared = LocalGameHTTPServer()



    private let lock = NSLock()

    private var serverSocket: Int32 = -1

    private var isRunning: Bool = false

    private(set) var port: UInt16 = 0

    private var rootDirectoryURL: URL?



    private var resolvedPathCache: [String: URL] = [:]

    private var sanitizedTextCache: [String: Data] = [:]

    private var liveSavesSnapshot: [String: String] = [:]

    private let assetMemoryCache: NSCache<NSString, NSData> = {

        let cache = NSCache<NSString, NSData>()

        cache.totalCostLimit = 48 * 1024 * 1024 // 48 MB 自动受系统管理

        cache.countLimit = 240

        return cache

    }()



    private static let transparentPNGData: Data = Data(

        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="

    ) ?? Data()



    private static let saveloadExSaveHTMLData: Data = Data("""

    <div class="save saveload_ex"><img class="menu_item menu_close" src="data/others/plugin/saveload_ex/image/back.png" /><div style="clear:both"></div><img class="button_smart button_arrow_up" src="data/others/plugin/saveload_ex/image/arrow_up.png" style="cursor:pointer;" /><img class="button_smart button_arrow_down" src="data/others/plugin/saveload_ex/image/arrow_down.png" style="cursor:pointer;" /><div class="area_page_list"></div><div class="area_save_list"><script class="save_list_item" type="text/x-jsrender"><ul class="save_list">{{for array_save}}<li class="save_display_area save_list_item" data-num="{{:num}}" data-page="{{:page}}"><span class="save_list_item_num">{{:num+1}}</span><span class="save_list_item_thumb">{{if img_data != ""}}<img src="{{:img_data}}">{{else}}<span class="no_image">NO DATA</span>{{/if}}</span><span class="save_list_item_area"><span class="save_list_item_date">{{:save_date}}</span><span class="save_list_item_text">{{:title}}</span></span><span class="save_list_item_Lock" data-num="{{:num}}" data-lock="{{:lock}}"></span><span class="save_list_item_delete" data-num="{{:num}}"></span><input class="save_list_item_comment" type="text" data-num="{{:num}}" placeholder="備註" value="{{:comment}}"></li>{{/for}}</ul></script></div><img class="img_bg_base" src="data/others/plugin/saveload_ex/image/bg_save.png" data-type="save" /></div>

    """.utf8)



    private static let saveloadExLoadHTMLData: Data = Data("""

    <div class="load saveload_ex"><img class="menu_item menu_close" src="data/others/plugin/saveload_ex/image/back.png" /><div style="clear:both"></div><img class="button_smart button_arrow_up" src="data/others/plugin/saveload_ex/image/arrow_up.png" style="cursor:pointer;" /><img class="button_smart button_arrow_down" src="data/others/plugin/saveload_ex/image/arrow_down.png" style="cursor:pointer;" /><div class="area_page_list"></div><div class="area_save_list"><script class="save_list_item" type="text/x-jsrender"><ul class="save_list">{{for array_save}}<li class="save_display_area save_list_item" data-num="{{:num}}" data-page="{{:page}}"><span class="save_list_item_num">{{:num+1}}</span><span class="save_list_item_thumb">{{if img_data != ""}}<img src="{{:img_data}}">{{else}}<span class="no_image">NO DATA</span>{{/if}}</span><span class="save_list_item_area"><span class="save_list_item_date">{{:save_date}}</span><span class="save_list_item_text">{{:title}}</span></span><span class="save_list_item_Lock" data-num="{{:num}}" data-lock="{{:lock}}"></span><span class="save_list_item_delete" data-num="{{:num}}"></span><input class="save_list_item_comment" type="text" data-num="{{:num}}" placeholder="備註" value="{{:comment}}"></li>{{/for}}</ul></script></div><img class="img_bg_base" src="data/others/plugin/saveload_ex/image/bg_load.png" data-type="load" /></div>

    """.utf8)



    private let acceptQueue = DispatchQueue(label: "com.tyrano.httpserver.accept", qos: .userInteractive)

    private let clientQueue = DispatchQueue(label: "com.tyrano.httpserver.client", qos: .userInteractive, attributes: .concurrent)



    private init() {

        Self.raiseFileDescriptorLimit()

    }



    private static func raiseFileDescriptorLimit() {

        var limit = rlimit()

        if getrlimit(RLIMIT_NOFILE, &limit) == 0 {

            let targetCur: rlim_t = 4096

            if limit.rlim_cur < targetCur {

                limit.rlim_cur = min(targetCur, limit.rlim_max)

                _ = setrlimit(RLIMIT_NOFILE, &limit)

            }

        }

    }



    func replaceLiveSaves(_ dict: [String: String]) {

        lock.lock()

        liveSavesSnapshot = dict

        lock.unlock()

    }



    func clearMemoryCaches() {

        lock.lock()

        resolvedPathCache.removeAll()

        sanitizedTextCache.removeAll()

        lock.unlock()

        assetMemoryCache.removeAllObjects()

    }



    func startAndMakeEntryURL(rootDirectoryURL: URL, entryHTMLURL: URL) -> URL? {

        Self.raiseFileDescriptorLimit()

        let stdRoot = rootDirectoryURL.standardizedFileURL

        lock.lock()

        if self.rootDirectoryURL != stdRoot {

            self.rootDirectoryURL = stdRoot

            self.resolvedPathCache.removeAll()

            self.sanitizedTextCache.removeAll()

            self.assetMemoryCache.removeAllObjects()

        }

        let activePort = ensureListeningLocked()

        lock.unlock()



        guard activePort > 0 else { return nil }

        let baseComps = stdRoot.pathComponents

        let entryComps = entryHTMLURL.standardizedFileURL.pathComponents

        let commonCount = zip(baseComps, entryComps).prefix(while: { $0 == $1 }).count

        let relComps = entryComps.dropFirst(commonCount)

        let encodedPath = relComps.map { comp in

            comp.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? comp

        }.joined(separator: "/")

        return URL(string: "http://127.0.0.1:\(activePort)/\(encodedPath)")

    }



    private func ensureListeningLocked() -> UInt16 {

        if isRunning && serverSocket >= 0 && port > 0 {

            return port

        }

        if serverSocket >= 0 {

            Darwin.close(serverSocket)

            serverSocket = -1

        }



        let sock = Darwin.socket(AF_INET, SOCK_STREAM, 0)

        guard sock >= 0 else { return 0 }



        var yes: Int32 = 1

        _ = Darwin.setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        _ = Darwin.setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))



        var addr = sockaddr_in()

        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        addr.sin_family = sa_family_t(AF_INET)

        addr.sin_port = port.bigEndian

        addr.sin_addr.s_addr = inet_addr("127.0.0.1")



        var bindResult = withUnsafePointer(to: &addr) { ptr in

            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in

                Darwin.bind(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))

            }

        }

        if bindResult != 0 && port != 0 {

            addr.sin_port = 0

            bindResult = withUnsafePointer(to: &addr) { ptr in

                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in

                    Darwin.bind(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))

                }

            }

        }

        guard bindResult == 0 else {

            Darwin.close(sock)

            return 0

        }



        var boundAddr = sockaddr_in()

        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

        _ = withUnsafeMutablePointer(to: &boundAddr) { ptr in

            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in

                Darwin.getsockname(sock, sockPtr, &addrLen)

            }

        }

        let assignedPort = UInt16(bigEndian: boundAddr.sin_port)

        guard assignedPort > 0, Darwin.listen(sock, 128) == 0 else {

            Darwin.close(sock)

            return 0

        }



        self.serverSocket = sock

        self.port = assignedPort

        self.isRunning = true



        acceptQueue.async { [weak self] in

            self?.acceptLoop(listenSocket: sock)

        }

        return assignedPort

    }



    private func acceptLoop(listenSocket: Int32) {

        while true {

            var clientAddr = sockaddr_in()

            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)

            let clientSock = withUnsafeMutablePointer(to: &clientAddr) { ptr in

                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in

                    Darwin.accept(listenSocket, sockPtr, &clientLen)

                }

            }

            if clientSock < 0 {

                let err = errno

                if err == EINTR || err == EAGAIN || err == EWOULDBLOCK {

                    continue

                }

                if err == EMFILE || err == ENFILE {

                    usleep(40_000)

                    continue

                }

                lock.lock()

                let stillRunning = isRunning && (serverSocket == listenSocket)

                lock.unlock()

                if !stillRunning { break }

                continue

            }



            var noSigPipe: Int32 = 1

            _ = Darwin.setsockopt(clientSock, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

            var noDelay: Int32 = 1

            _ = Darwin.setsockopt(clientSock, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))

            var sendBufSize: Int32 = 1_048_576

            _ = Darwin.setsockopt(clientSock, SOL_SOCKET, SO_SNDBUF, &sendBufSize, socklen_t(MemoryLayout<Int32>.size))

            var tv = timeval(tv_sec: 15, tv_usec: 0)

            _ = Darwin.setsockopt(clientSock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

            _ = Darwin.setsockopt(clientSock, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))



            clientQueue.async { [weak self] in

                self?.handleClientConnection(clientSock)

            }

        }

    }



    private static func normalizeRelativeRequestPath(_ rawPath: String) -> String {

        let unified = rawPath.replacingOccurrences(of: "\\", with: "/")

        var stack: [String] = []

        for part in unified.split(separator: "/", omittingEmptySubsequences: true) {

            if part == "." {

                continue

            } else if part == ".." {

                if !stack.isEmpty { stack.removeLast() }

            } else {

                stack.append(String(part))

            }

        }

        return stack.joined(separator: "/")

    }



    private func handleClientConnection(_ clientSock: Int32) {

        defer { Darwin.close(clientSock) }



        let crlf = String(UnicodeScalar(13)) + String(UnicodeScalar(10))

        let headerTerminator = Data([13, 10, 13, 10])

        var pendingData = Data()

        var recvBuffer = [UInt8](repeating: 0, count: 16384)



        while pendingData.range(of: headerTerminator) == nil && pendingData.count < 65536 {

            let n = Darwin.recv(clientSock, &recvBuffer, recvBuffer.count, 0)

            if n < 0 {

                if errno == EINTR { continue }

                return

            }

            if n == 0 { break }

            pendingData.append(recvBuffer, count: n)

        }



        guard let termRange = pendingData.range(of: headerTerminator) else { return }

        let requestHeaderData = pendingData.subdata(in: 0..<termRange.lowerBound)



        guard let headerText = String(data: requestHeaderData, encoding: .utf8) ?? String(data: requestHeaderData, encoding: .isoLatin1) else {

            return

        }



        let lines = headerText.components(separatedBy: crlf)

        guard let requestLine = lines.first else { return }

        let parts = requestLine.split(separator: " ")

        guard parts.count >= 2 else { return }



        let method = String(parts[0]).uppercased()

        var ifNoneMatch: String?

        var rangeHeader: String?



        for line in lines.dropFirst() {

            let lowerLine = line.lowercased()

            if lowerLine.hasPrefix("range:") {

                rangeHeader = line.dropFirst(6).trimmingCharacters(in: .whitespaces)

            } else if lowerLine.hasPrefix("if-none-match:") {

                ifNoneMatch = line.dropFirst(14).trimmingCharacters(in: .whitespaces)

            }

        }



        if method == "OPTIONS" {

            let resp = [

                "HTTP/1.1 200 OK",

                "Access-Control-Allow-Origin: *",

                "Access-Control-Allow-Methods: GET, HEAD, OPTIONS",

                "Content-Length: 0",

                "Connection: close",

                "",

                ""

            ].joined(separator: crlf)

            _ = sendAll(socket: clientSock, data: Data(resp.utf8))

            return

        }



        var rawTarget = String(parts[1])

        if let qIdx = rawTarget.firstIndex(of: "?") {

            rawTarget = String(rawTarget[..<qIdx])

        }

        if let hIdx = rawTarget.firstIndex(of: "#") {

            rawTarget = String(rawTarget[..<hIdx])

        }

        let decodedPath = rawTarget.removingPercentEncoding ?? rawTarget

        let cleanRelPath = Self.normalizeRelativeRequestPath(decodedPath)



        // 实时存档同步端点：供游戏返回标题或刷新页面时同步拉取最新存档

        if cleanRelPath == "__tyrano_native_saves__.json" {

            lock.lock()

            let snap = self.liveSavesSnapshot

            lock.unlock()

            let jsonData = (try? JSONSerialization.data(withJSONObject: snap, options: [])) ?? Data("{}".utf8)

            let header = [

                "HTTP/1.1 200 OK",

                "Content-Type: application/json; charset=utf-8",

                "Content-Length: \(jsonData.count)",

                "Access-Control-Allow-Origin: *",

                "Cache-Control: no-store",

                "Connection: close",

                "",

                ""

            ].joined(separator: crlf)

            if sendAll(socket: clientSock, data: Data(header.utf8)) && method != "HEAD" {

                _ = sendAll(socket: clientSock, data: jsonData)

            }

            return

        }



        lock.lock()

        let baseDir = self.rootDirectoryURL

        lock.unlock()



        guard let rootDir = baseDir else { return }



        guard let resolvedFileURL = resolveLocalFile(in: rootDir, relativePath: cleanRelPath) else {

            let lowerRel = cleanRelPath.lowercased()

            let reqExt = (cleanRelPath as NSString).pathExtension.lowercased()



            // 关键防护 1：当请求缺失的图片资源（如 button_menu.png 或拼写差异的 culumn1.png）时，

            // 直接返回 HTTP 200 + 1x1 透明 PNG，使 WebKit 触发 img.onload 而非 img.onerror，彻底解决优雅降级后按钮消失无响应的问题

            if ["png", "jpg", "jpeg", "gif", "webp", "bmp", "svg", "ico"].contains(reqExt) {

                let pngData = Self.transparentPNGData

                let header = [

                    "HTTP/1.1 200 OK",

                    "Content-Type: image/png",

                    "Content-Length: \(pngData.count)",

                    "Access-Control-Allow-Origin: *",

                    "Cache-Control: no-cache",

                    "Connection: close",

                    "",

                    ""

                ].joined(separator: crlf)

                if sendAll(socket: clientSock, data: Data(header.utf8)) && method != "HEAD" {

                    _ = sendAll(socket: clientSock, data: pngData)

                }

                return

            }



            // 关键防护 2：内置 saveload_ex 插件 save.html / load.html 模板兜底

            if lowerRel.contains("saveload_ex") && (lowerRel.hasSuffix("save.html") || lowerRel.hasSuffix("load.html")) {

                let htmlData = lowerRel.hasSuffix("save.html") ? Self.saveloadExSaveHTMLData : Self.saveloadExLoadHTMLData

                let header = [

                    "HTTP/1.1 200 OK",

                    "Content-Type: text/html; charset=utf-8",

                    "Content-Length: \(htmlData.count)",

                    "Access-Control-Allow-Origin: *",

                    "Cache-Control: no-cache",

                    "Connection: close",

                    "",

                    ""

                ].joined(separator: crlf)

                if sendAll(socket: clientSock, data: Data(header.utf8)) && method != "HEAD" {

                    _ = sendAll(socket: clientSock, data: htmlData)

                }

                return

            }



            let notFound = [

                "HTTP/1.1 404 Not Found",

                "Access-Control-Allow-Origin: *",

                "Content-Length: 0",

                "Connection: close",

                "",

                ""

            ].joined(separator: crlf)

            _ = sendAll(socket: clientSock, data: Data(notFound.utf8))

            return

        }



        let ext = resolvedFileURL.pathExtension.lowercased()

        let mime = mimeType(for: ext)

        let cachePolicy = cacheControlHeader(for: ext)



        // 优先针对带 Range 请求头的音视频流（如开幕动画 <video> / BGM）使用 FileHandle 偏移直读

        if ext != "tjs" && ext != "ks", let rangeStr = rangeHeader, rangeStr.lowercased().hasPrefix("bytes=") {

            let fileSize = (try? FileManager.default.attributesOfItem(atPath: resolvedFileURL.path)[.size] as? Int) ?? 0

            if fileSize > 0 {

                let quoteChar = String(UnicodeScalar(34))

                let etag = quoteChar + "\(fileSize)-\(abs(resolvedFileURL.lastPathComponent.hashValue))" + quoteChar

                let spec = rangeStr.dropFirst(6)

                let rangeParts = spec.split(separator: "-", omittingEmptySubsequences: false)

                if rangeParts.count == 2 {

                    let startVal = Int(rangeParts[0]) ?? 0

                    let endVal = rangeParts[1].isEmpty ? (fileSize - 1) : (Int(rangeParts[1]) ?? (fileSize - 1))

                    let clampedStart = max(0, min(startVal, fileSize - 1))

                    let clampedEnd = max(clampedStart, min(endVal, fileSize - 1))

                    let sliceLen = clampedEnd - clampedStart + 1



                    let header = [

                        "HTTP/1.1 206 Partial Content",

                        "Content-Type: \(mime)",

                        "Accept-Ranges: bytes",

                        "Content-Range: bytes \(clampedStart)-\(clampedEnd)/\(fileSize)",

                        "Content-Length: \(sliceLen)",

                        "ETag: \(etag)",

                        "Access-Control-Allow-Origin: *",

                        "Cache-Control: \(cachePolicy)",

                        "Connection: close",

                        "",

                        ""

                    ].joined(separator: crlf)

                    if !sendAll(socket: clientSock, data: Data(header.utf8)) { return }

                    if method != "HEAD" && sliceLen > 0 {

                        if let cachedData = assetMemoryCache.object(forKey: resolvedFileURL.path as NSString) as Data?,

                           clampedEnd < cachedData.count {

                            let slice = cachedData.subdata(in: clampedStart..<(clampedEnd + 1))

                            _ = sendAll(socket: clientSock, data: slice)

                        } else if let fh = try? FileHandle(forReadingFrom: resolvedFileURL) {

                            defer { try? fh.close() }

                            _ = try? fh.seek(toOffset: UInt64(clampedStart))

                            var remaining = sliceLen

                            while remaining > 0 {

                                let chunkCount = min(262_144, remaining)

                                guard let chunk = try? fh.read(upToCount: chunkCount), !chunk.isEmpty else { break }

                                if !sendAll(socket: clientSock, data: chunk) { return }

                                remaining -= chunk.count

                            }

                        }

                    }

                    return

                }

            }

        }



        guard let payloadData = loadAndSanitizeFileData(at: resolvedFileURL) else {

            let notFound = [

                "HTTP/1.1 404 Not Found",

                "Access-Control-Allow-Origin: *",

                "Content-Length: 0",

                "Connection: close",

                "",

                ""

            ].joined(separator: crlf)

            _ = sendAll(socket: clientSock, data: Data(notFound.utf8))

            return

        }



        let totalLen = payloadData.count

        let quoteChar = String(UnicodeScalar(34))

        let etag = quoteChar + "\(totalLen)-\(abs(resolvedFileURL.lastPathComponent.hashValue))" + quoteChar



        if rangeHeader == nil, let clientETag = ifNoneMatch, clientETag == etag, isStaticCacheableAsset(ext: ext) {

            let notModified = [

                "HTTP/1.1 304 Not Modified",

                "ETag: \(etag)",

                "Cache-Control: \(cachePolicy)",

                "Access-Control-Allow-Origin: *",

                "Connection: close",

                "",

                ""

            ].joined(separator: crlf)

            _ = sendAll(socket: clientSock, data: Data(notModified.utf8))

            return

        }



        let okHeader = [

            "HTTP/1.1 200 OK",

            "Content-Type: \(mime)",

            "Accept-Ranges: bytes",

            "Content-Length: \(totalLen)",

            "ETag: \(etag)",

            "Access-Control-Allow-Origin: *",

            "Cache-Control: \(cachePolicy)",

            "Connection: close",

            "",

            ""

        ].joined(separator: crlf)

        if !sendAll(socket: clientSock, data: Data(okHeader.utf8)) { return }

        if method != "HEAD" && totalLen > 0 {

            _ = sendAll(socket: clientSock, data: payloadData)

        }

    }



    private func isStaticCacheableAsset(ext: String) -> Bool {

        switch ext {

        case "png", "jpg", "jpeg", "gif", "webp", "svg", "ico", "woff", "woff2", "ttf", "otf", "ogg", "oga", "m4a", "mp4a", "mp3", "wav", "mp4", "m4v", "webm", "ogv", "js", "css", "ks", "tjs":

            return true

        default:

            return false

        }

    }



    private func cacheControlHeader(for ext: String) -> String {

        if isStaticCacheableAsset(ext: ext) {

            return "public, max-age=86400, immutable"

        }

        return "no-cache"

    }



    private func resolveLocalFile(in rootDir: URL, relativePath: String) -> URL? {

        let cleanRel = Self.normalizeRelativeRequestPath(relativePath)

        if cleanRel.isEmpty { return nil }



        lock.lock()

        if let cached = resolvedPathCache[cleanRel] {

            lock.unlock()

            return cached

        }

        lock.unlock()



        let fm = FileManager.default



        let directURL = rootDir.appendingPathComponent(cleanRel)

        var isDir: ObjCBool = false

        if fm.fileExists(atPath: directURL.path, isDirectory: &isDir), !isDir.boolValue {

            cacheResolvedPath(cleanRel, url: directURL)

            return directURL

        }



        // 兼容 saveload_ex 插件历史版本的 culumn1.png <-> column1.png 拼写差异

        let lowerRel = cleanRel.lowercased()

        if lowerRel.contains("culumn") || lowerRel.contains("column") {

            let altRel = lowerRel.contains("culumn")

                ? cleanRel.replacingOccurrences(of: "culumn", with: "column", options: .caseInsensitive)

                : cleanRel.replacingOccurrences(of: "column", with: "culumn", options: .caseInsensitive)

            let altURL = rootDir.appendingPathComponent(altRel)

            if fm.fileExists(atPath: altURL.path, isDirectory: &isDir), !isDir.boolValue {

                cacheResolvedPath(cleanRel, url: altURL)

                return altURL

            }

        }



        let components = cleanRel.split(separator: "/").map(String.init)

        var currentURL = rootDir

        for (idx, comp) in components.enumerated() {

            let candidate = currentURL.appendingPathComponent(comp)

            var subDir: ObjCBool = false

            if fm.fileExists(atPath: candidate.path, isDirectory: &subDir) {

                currentURL = candidate

                if idx == components.count - 1 && !subDir.boolValue {

                    cacheResolvedPath(cleanRel, url: currentURL)

                    return currentURL

                }

                continue

            }

            guard let children = try? fm.contentsOfDirectory(at: currentURL, includingPropertiesForKeys: nil, options: []) else {

                break

            }

            let lowerComp = comp.precomposedStringWithCanonicalMapping.lowercased()

            if let matched = children.first(where: { $0.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased() == lowerComp }) {

                currentURL = matched

                var matchedDir: ObjCBool = false

                if idx == components.count - 1 && fm.fileExists(atPath: matched.path, isDirectory: &matchedDir) && !matchedDir.boolValue {

                    cacheResolvedPath(cleanRel, url: matched)

                    return matched

                }

            } else if idx == components.count - 1 {

                // 检查 culumn <-> column 同目录拼写容错

                if lowerComp.contains("culumn") || lowerComp.contains("column") {

                    let altComp = lowerComp.contains("culumn")

                        ? lowerComp.replacingOccurrences(of: "culumn", with: "column")

                        : lowerComp.replacingOccurrences(of: "column", with: "culumn")

                    if let altMatched = children.first(where: { $0.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased() == altComp }) {

                        cacheResolvedPath(cleanRel, url: altMatched)

                        return altMatched

                    }

                }

                let mediaExts = [".ogg", ".m4a", ".mp3", ".wav", ".webm", ".ogv", ".mp4", ".m4v"]

                if let matchedExt = mediaExts.first(where: { lowerComp.hasSuffix($0) }) {

                    let baseName = String(lowerComp.dropLast(matchedExt.count))

                    let fallbackCandidates: [String]

                    if matchedExt == ".webm" || matchedExt == ".ogv" || matchedExt == ".mp4" || matchedExt == ".m4v" {

                        fallbackCandidates = [baseName + ".mp4", baseName + ".m4v", baseName + ".webm", baseName + ".ogv"]

                    } else {

                        fallbackCandidates = [baseName + ".m4a", baseName + ".mp3", baseName + ".ogg", baseName + ".wav"]

                    }

                    for candName in fallbackCandidates {

                        if let fallbackFile = children.first(where: { $0.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased() == candName }) {

                            cacheResolvedPath(cleanRel, url: fallbackFile)

                            return fallbackFile

                        }

                    }

                }

                return nil

            } else {

                return nil

            }

        }

        return nil

    }



    private func cacheResolvedPath(_ relPath: String, url: URL) {

        lock.lock()

        if resolvedPathCache.count > 4096 {

            resolvedPathCache.removeAll(keepingCapacity: true)

        }

        resolvedPathCache[relPath] = url

        lock.unlock()

    }



    private func loadAndSanitizeFileData(at fileURL: URL) -> Data? {

        let ext = fileURL.pathExtension.lowercased()

        let fileName = fileURL.lastPathComponent.lowercased()

        let cacheKey = fileURL.path



        if ext == "tjs" || ext == "ks" {

            lock.lock()

            if let cachedData = sanitizedTextCache[cacheKey] {

                lock.unlock()

                return cachedData

            }

            lock.unlock()



            // 关键修复：不使用 .mappedIfSafe，防止 mmap 长期驻留耗尽 iOS 256 文件描述符上限

            guard let rawData = try? Data(contentsOf: fileURL) else { return nil }

            var text: String?

            if rawData.count >= 2 && ((rawData[0] == 0xFF && rawData[1] == 0xFE) || (rawData[0] == 0xFE && rawData[1] == 0xFF)) {

                text = String(data: rawData, encoding: .utf16)

            } else if let utf8Str = String(data: rawData, encoding: .utf8) {

                text = utf8Str

            } else if let sjisStr = String(data: rawData, encoding: .shiftJIS) {

                text = sjisStr

            } else if let eucStr = String(data: rawData, encoding: .japaneseEUC) {

                text = eucStr

            }



            if var validText = text {

                if fileName == "config.tjs" {

                    validText = validText.replacingOccurrences(of: ";configSave = file", with: ";configSave = webstorage")

                    validText = validText.replacingOccurrences(of: ";configSave=file", with: ";configSave = webstorage")

                    validText = validText.replacingOccurrences(of: ";configSave = webstorage_compress", with: ";configSave = webstorage")

                    validText = validText.replacingOccurrences(of: ";configSave=webstorage_compress", with: ";configSave = webstorage")

                }

                if let utf8Data = validText.data(using: .utf8) {

                    lock.lock()

                    if sanitizedTextCache.count > 256 {

                        sanitizedTextCache.removeAll(keepingCapacity: true)

                    }

                    sanitizedTextCache[cacheKey] = utf8Data

                    lock.unlock()

                    return utf8Data

                }

            }

            return rawData

        }



        if let memCached = assetMemoryCache.object(forKey: cacheKey as NSString) {

            return memCached as Data

        }



        guard let data = try? Data(contentsOf: fileURL) else { return nil }

        if data.count <= 6 * 1024 * 1024 {

            assetMemoryCache.setObject(data as NSData, forKey: cacheKey as NSString, cost: data.count)

        }

        return data

    }



    private func mimeType(for ext: String) -> String {

        switch ext {

        case "html", "htm": return "text/html; charset=utf-8"

        case "js", "mjs": return "application/javascript; charset=utf-8"

        case "css": return "text/css; charset=utf-8"

        case "json": return "application/json; charset=utf-8"

        case "ks", "tjs", "txt": return "text/plain; charset=utf-8"

        case "png": return "image/png"

        case "jpg", "jpeg": return "image/jpeg"

        case "gif": return "image/gif"

        case "webp": return "image/webp"

        case "svg": return "image/svg+xml"

        case "ico": return "image/x-icon"

        case "ogg", "oga": return "audio/ogg"

        case "m4a", "mp4a": return "audio/mp4"

        case "mp3": return "audio/mpeg"

        case "wav": return "audio/wav"

        case "mp4", "m4v": return "video/mp4"

        case "webm": return "video/webm"

        case "ogv": return "video/ogg"

        case "woff": return "font/woff"

        case "woff2": return "font/woff2"

        case "ttf": return "font/ttf"

        case "otf": return "font/otf"

        default: return "application/octet-stream"

        }

    }



    @discardableResult

    private func sendAll(socket: Int32, data: Data) -> Bool {

        return data.withUnsafeBytes { rawBuf in

            guard let base = rawBuf.baseAddress else { return false }

            var totalSent = 0

            let count = data.count

            while totalSent < count {

                let sent = Darwin.send(socket, base.advanced(by: totalSent), count - totalSent, 0)

                if sent < 0 {

                    let err = errno

                    if err == EINTR { continue }

                    if err == EAGAIN || err == EWOULDBLOCK {

                        usleep(2_000)

                        continue

                    }

                    return false

                }

                if sent == 0 { return false }

                totalSent += sent

            }

            return true

        }

    }

}



struct WebDebugConsoleDrawer: View {

    let gameTitle: String

    @Binding var logs: [ConsoleLogEntry]

    let onExecuteJS: (String) -> Void

    let onExportLog: () -> Void

    let onClose: () -> Void



    @State private var selectedLevel: ConsoleLogLevel = .all

    @State private var jsInput: String = ""

    @State private var copiedFlag = false



    private var filteredLogs: [ConsoleLogEntry] {

        selectedLevel == .all ? logs : logs.filter { $0.level == selectedLevel }

    }



    var body: some View {

        VStack(spacing: 0) {

            HStack(spacing: 8) {

                Text("Web 控制台")

                    .font(.caption.weight(.bold))

                    .foregroundStyle(.white)



                Picker("级别", selection: $selectedLevel) {

                    ForEach(ConsoleLogLevel.allCases) { level in

                        Text(level.rawValue).tag(level)

                    }

                }

                .pickerStyle(.segmented)

                .frame(maxWidth: 180)



                Spacer()



                Button {

                    let text = logs.map { "[\($0.level.rawValue)] \($0.message)" }.joined(separator: "\n")

                    UIPasteboard.general.string = text

                    copiedFlag = true

                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedFlag = false }

                } label: {

                    Text(copiedFlag ? "已复制" : "复制")

                        .font(.caption2)

                }

                .buttonStyle(.bordered)

                .tint(.cyan)



                Button(action: onExportLog) {

                    Image(systemName: "square.and.arrow.up").font(.caption)

                }

                .buttonStyle(.bordered)

                .tint(.indigo)



                Button {

                    logs.removeAll()

                } label: {

                    Image(systemName: "trash").font(.caption)

                }

                .buttonStyle(.bordered)

                .tint(.red)



                Button(action: onClose) {

                    Image(systemName: "xmark.circle.fill")

                        .font(.title3)

                        .foregroundStyle(.white.opacity(0.8))

                }

            }

            .padding(.horizontal, 12)

            .padding(.vertical, 6)

            .background(Color.black.opacity(0.92))



            ScrollView {

                LazyVStack(alignment: .leading, spacing: 4) {

                    ForEach(filteredLogs) { entry in

                        Text("[\(entry.level.rawValue)] \(entry.message)")

                            .font(.system(size: 11, design: .monospaced))

                            .foregroundStyle(entry.level == .error ? .red : (entry.level == .warn ? .yellow : .white))

                            .padding(.horizontal, 10)

                    }

                }

                .padding(.vertical, 6)

            }

            .background(Color(white: 0.08).opacity(0.92))



            HStack(spacing: 8) {

                TextField("输入 JS 表达式", text: $jsInput)

                    .font(.system(size: 12, design: .monospaced))

                    .foregroundStyle(.white)

                    .textInputAutocapitalization(.never)

                    .autocorrectionDisabled(true)

                Button("执行") {

                    let cmd = jsInput.trimmingCharacters(in: .whitespacesAndNewlines)

                    guard !cmd.isEmpty else { return }

                    onExecuteJS(cmd)

                    jsInput = ""

                }

                .font(.caption)

                .buttonStyle(.borderedProminent)

            }

            .padding(.horizontal, 12)

            .padding(.vertical, 6)

            .background(Color.black.opacity(0.95))

        }

        .clipShape(RoundedRectangle(cornerRadius: 12))

        .padding(8)

    }

}

