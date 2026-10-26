
import SwiftUI

import WebKit

import AVFoundation

import UniformTypeIdentifiers

import UIKit



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

                    consoleLogs.append(entry)

                    if consoleLogs.count > 400 {

                        consoleLogs.removeFirst(consoleLogs.count - 400)

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



            // 1. 控制台日志与全局异常优雅降级（报错记日志但不闪退，损坏图片自动替换占位图）

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

            console.log = function() { sendLog('LOG', arguments); origLog.apply(console, arguments); };

            console.info = function() { sendLog('LOG', arguments); origInfo.apply(console, arguments); };

            console.warn = function() { sendLog('WARN', arguments); origWarn.apply(console, arguments); };

            console.error = function() { sendLog('ERROR', arguments); origError.apply(console, arguments); };



            var TRANSPARENT_PLACEHOLDER_PNG = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';



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

                            e.stopPropagation();

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

                    if (e.preventDefault) e.preventDefault();

                } catch (err) {}

            }, true);



            window.addEventListener('unhandledrejection', function(e) {

                sendLog('WARN', ['[异步异常已拦截]', e.reason ? String(e.reason) : 'unknown']);

                if (e && e.preventDefault) e.preventDefault();

            });



            // 2. 独立命名空间隔离的原生持久化存档（每个游戏使用独立 UUID 前缀与独立 JSON，绝不串档）

            window.__TYRANO_NATIVE_SAVES__ = \(initialSavesJSON);

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



            // 3. 接管并按游戏 UUID 严格隔离 localStorage（不同游戏绝不共享同一存储空间）

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



            function decodeSmartText(xhr) {

                try {

                    if (xhr.response && xhr.response instanceof ArrayBuffer) {

                        var buf = new Uint8Array(xhr.response);

                        if (buf.length >= 2 && ((buf[0] === 0xFF && buf[1] === 0xFE) || (buf[0] === 0xFE && buf[1] === 0xFF))) {

                            return new TextDecoder('utf-16').decode(buf);

                        }

                        try {

                            return new TextDecoder('utf-8', { fatal: true }).decode(buf);

                        } catch (utf8Err) {

                            try {

                                return new TextDecoder('shift-jis', { fatal: true }).decode(buf);

                            } catch (sjisErr) {

                                return new TextDecoder('utf-8').decode(buf);

                            }

                        }

                    }

                } catch (e) {}

                return xhr.responseText || '';

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



                    // 严禁直接读取原包内的 Windows 版 savedata/.dat/.sav 文件（防乱码损坏）

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



            // 5. 严格顺序控制：先预加载 Config.tjs -> 锁定初始化 sf/f/tf 非空变量守卫 -> 再允许跑脚本

            window.__TYRANO_PRELOADED_CONFIG__ = xhrReadLocalFileSync('data/system/Config.tjs');



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



            // 5.5 四层 Windows/Electron/NW.js 运行时彻底屏蔽与 jQuery 防覆盖锁（参考 ShikemokuMK/tyranoscript 与 Tyranor-Next 设计）

            function decodeSaveStr(raw) {

                if (raw === null || raw === undefined || raw === '' || raw === 'null' || raw === 'undefined') return null;

                var s = String(raw);

                if (s.charAt(0) === '{' || s.charAt(0) === '[') return s;

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

                return escape(json);

            }



            function shieldTyranoJQueryInstance(jq) {

                if (!jq || typeof jq !== 'function' || jq.__tyranoWindowsShielded) return;

                jq.__tyranoWindowsShielded = true;

                try {

                    // (A) 永久锁定 $.isNWJS() 与 $.isElectron() 为 false，彻底阻断 tyrano/libs.js 走 Windows EXE 分支

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



                    // (B) 在 tyrano/libs.js 挂载之初即接管所有存档读写函数，彻底屏蔽 Windows 本地 .sav 文件读写

                    var safeSetStorage = function(key, val) {

                        customLocalStorage.setItem(String(key), encodeSaveVal(val));

                    };

                    var safeGetStorage = function(key) {

                        return decodeSaveStr(customLocalStorage.getItem(String(key)));

                    };

                    var storageMethods = ['setStorageWeb', 'setStorageCompress', 'setStorageFile'];

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

                    var getMethods = ['getStorageWeb', 'getStorageCompress', 'getStorageFile'];

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



                    // (C) 拦截 $.loadText：在内存中自动将 Config.tjs 的 configSave=file 转为 webstorage 并修复 Shift-JIS

                    var _origLoadText = undefined;

                    Object.defineProperty(jq, 'loadText', {

                        configurable: true,

                        enumerable: true,

                        get: function() {

                            if (typeof _origLoadText !== 'function') return undefined;

                            return function(file_path, callback) {

                                var pathStr = String(file_path || '');

                                var isConfig = pathStr.toLowerCase().indexOf('config.tjs') !== -1;

                                return _origLoadText.call(jq, file_path, function(order_str) {

                                    try {

                                        var badChar = String.fromCharCode(65533);

                                        if (typeof order_str === 'string' && order_str.indexOf(badChar) !== -1) {

                                            var cleanPath = pathStr.split('?')[0].split('#')[0];

                                            var xhrSjis = new XMLHttpRequest();

                                            xhrSjis.open('GET', cleanPath, false);

                                            xhrSjis.overrideMimeType('text/plain; charset=shift_jis');

                                            xhrSjis.send(null);

                                            if ((xhrSjis.status === 200 || xhrSjis.status === 0) && xhrSjis.responseText) {

                                                order_str = xhrSjis.responseText;

                                            }

                                        }

                                        if (isConfig && typeof order_str === 'string') {

                                            order_str = sanitizeConfigTextInMemory(order_str);

                                        }

                                        if (window.TYRANO && window.TYRANO.kag) {

                                            installVariableNullGuard(window.TYRANO.kag);

                                        }

                                    } catch (e) {}

                                    if (callback) callback(order_str);

                                });

                            };

                        },

                        set: function(fn) {

                            if (typeof fn === 'function') {

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

                        } else {

                            // 拦截 PC 版 index.html 中 window.jQuery = window.$ = require('./tyrano/libs/jquery-...') 返回空对象覆盖原生 jQuery

                            sendLog('LOG', ['[Windows屏蔽层] 已拦截非法的 window.jQuery 覆盖，保护 jQuery 与插件链完好']);

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

                        } else {

                            sendLog('LOG', ['[Windows屏蔽层] 已拦截非法的 window.$ 覆盖，保护 $ 与插件链完好']);

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

                    if (isLegacyWindowsSaveFile(key) || key.toLowerCase().indexOf('save') !== -1) {

                        return readSaveFromNative(key) !== null;

                    }

                    if (readSaveFromNative(key) !== null) return true;

                    return xhrReadLocalFileSync(key) !== null;

                },

                readFileSync: function(p, options) {

                    var key = String(p || '');

                    var saved = readSaveFromNative(key);

                    if (saved !== null) return saved;

                    if (isLegacyWindowsSaveFile(key) || key.toLowerCase().indexOf('save') !== -1) {

                        return 'null';

                    }

                    var localText = xhrReadLocalFileSync(key);

                    if (localText !== null) return localText;

                    return '';

                },

                writeFileSync: function(p, data) {

                    var key = String(p || '');

                    // 只允许写入存档数据到独立内存/沙盒，绝不修改原游戏包资源文件

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

                // 拦截 index.html 中 require('./tyrano/libs/jquery-1.10.2.min.js') 等调用，直接返回已加载的原生 jQuery，严禁返回空对象 {}

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

                sendLog('WARN', ['[CommonJS] 自动兜底未知模块 require(' + id + ')']);

                var fallbackTarget = function() { return {}; };

                if (typeof Proxy !== 'undefined') {

                    return new Proxy(fallbackTarget, {

                        get: function(target, prop) {

                            if (prop === '__esModule') return false;

                            if (prop === 'default') return fallbackTarget;

                            if (prop === Symbol.toPrimitive) return function() { return ''; };

                            if (prop === 'toString' || prop === 'valueOf') return function() { return ''; };

                            return fallbackTarget;

                        },

                        apply: function() { return {}; },

                        construct: function() { return {}; }

                    });

                }

                return {};

            };



            window.require.resolve = function(id) { return String(id); };

            window.require.cache = commonJSCache;



            // 严禁在全局 window 上暴露 module / exports / process / nw / studio_api！

            // 否则会导致：

            // 1) remodal.js / jquery.touchSwipe.min.js 等 UMD 插件误判为 CommonJS 而不挂载到 window.jQuery

            // 2) TyranoScript 的 tyrano/libs.js 误判为 Windows NW.js / Electron 客户端而走本地 .sav 文件读写分支

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



            // 7. 音视频元素拦截与 .ogg -> .m4a -> .mp3 自动降级，全部失败时优雅跳过不卡死

            var origCreateElement = document.createElement.bind(document);

            document.createElement = function(tagName) {

                var el = origCreateElement(tagName);

                if (typeof tagName === 'string') {

                    var lower = tagName.toLowerCase();

                    if (lower === 'video') {

                        el.setAttribute('playsinline', '');

                        el.setAttribute('webkit-playsinline', '');

                        el.playsInline = true;

                        el.preload = 'auto';

                        el.addEventListener('error', function() {

                            sendLog('WARN', ['[优雅降级] 视频格式不受支持或缺失，已自动跳过:', el.src || 'video']);

                            try { el.dispatchEvent(new Event('ended')); } catch (e) {}

                        }, true);

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

                                sendLog('WARN', ['[优雅降级] 音频资源缺失或不受支持，已静默跳过:', src]);

                                try { el.dispatchEvent(new Event('ended')); } catch (e) {}

                            }

                        }, true);

                    }

                }

                return el;

            };



            // 8. 深度挂钩 TyranoScript 存档函数与严格顺序加载（在脚本加载阶段立即拦截：Config.tjs -> 初始化变量 sf -> 执行脚本）

            function decodeTyranoSaveString(raw) {

                if (raw === null || raw === undefined || raw === '' || raw === 'null') return null;

                var s = String(raw).trim();

                if (!s || s === 'null') return null;

                if (s.charAt(0) === '{' || s.charAt(0) === '[') return s;

                if (s.indexOf('%7B') === 0 || s.indexOf('%5B') === 0 || s.indexOf('%22') !== -1) {

                    try {

                        var u = unescape(s);

                        if (u && (u.charAt(0) === '{' || u.charAt(0) === '[')) return u;

                    } catch (e) {}

                }

                if (window.LZString) {

                    try {

                        var d1 = window.LZString.decompressFromBase64 ? window.LZString.decompressFromBase64(s) : null;

                        if (d1) {

                            if (d1.charAt(0) === '{' || d1.charAt(0) === '[') return d1;

                            var u1 = unescape(d1);

                            if (u1 && (u1.charAt(0) === '{' || u1.charAt(0) === '[')) return u1;

                        }

                    } catch (e) {}

                    try {

                        var d2 = window.LZString.decompress ? window.LZString.decompress(s) : null;

                        if (d2) {

                            if (d2.charAt(0) === '{' || d2.charAt(0) === '[') return d2;

                            var u2 = unescape(d2);

                            if (u2 && (u2.charAt(0) === '{' || u2.charAt(0) === '[')) return u2;

                        }

                    } catch (e) {}

                }

                return null;

            }



            function encodeTyranoSaveValue(val) {

                var json = typeof val === 'string' ? val : JSON.stringify(val);

                return escape(json);

            }



            var isConfigLoaded = false;

            var pendingScenarioCallbacks = [];



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



            function hookTyranoStorageAndSF() {

                ensureKagVariableInitialized();



                if (window.jQuery && window.jQuery.setStorageWeb && !window.jQuery.__tyranoStorageHooked) {

                    var $ = window.jQuery;

                    $.__tyranoStorageHooked = true;



                    $.setStorageWeb = function(key, val) {

                        window.localStorage.setItem(String(key), encodeTyranoSaveValue(val));

                    };

                    $.getStorageWeb = function(key) {

                        return decodeTyranoSaveString(window.localStorage.getItem(String(key)));

                    };

                    $.setStorageCompress = function(key, val) {

                        window.localStorage.setItem(String(key), encodeTyranoSaveValue(val));

                    };

                    $.getStorageCompress = function(key) {

                        return decodeTyranoSaveString(window.localStorage.getItem(String(key)));

                    };

                    $.setStorageFile = function(key, val) {

                        var encoded = encodeTyranoSaveValue(val);

                        window.localStorage.setItem(String(key), encoded);

                    };

                    $.getStorageFile = function(key) {

                        var v = window.localStorage.getItem(String(key));

                        return decodeTyranoSaveString(v);

                    };

                }



                // 严格顺序保障：确保 Config.tjs 配置解析与 sf 变量初始化先于任何 .ks 剧本脚本执行

                if (window.jQuery && window.jQuery.loadText && !window.jQuery.__tyranoLoadTextHooked) {

                    var $ = window.jQuery;

                    $.__tyranoLoadTextHooked = true;

                    var origLoadText = $.loadText;

                    $.loadText = function(file_path, callback) {

                        var pathStr = String(file_path || '');

                        var isConfig = pathStr.toLowerCase().indexOf('config.tjs') !== -1;



                        origLoadText.call($, file_path, function(order_str) {

                            try {

                                var badChar = String.fromCharCode(65533);

                                if (typeof order_str === 'string' && order_str.indexOf(badChar) !== -1) {

                                    try {

                                        var cleanPath = pathStr.split('?')[0].split('#')[0];

                                        var xhrSjis = new XMLHttpRequest();

                                        xhrSjis.open('GET', cleanPath, false);

                                        xhrSjis.overrideMimeType('text/plain; charset=shift_jis');

                                        xhrSjis.send(null);

                                        if ((xhrSjis.status === 200 || xhrSjis.status === 0) && xhrSjis.responseText) {

                                            order_str = xhrSjis.responseText;

                                        }

                                    } catch (eSjis) {}

                                }



                                if (isConfig && typeof order_str === 'string') {

                                    order_str = order_str.split(';configSave = file').join(';configSave = webstorage');

                                    order_str = order_str.split(';configSave=file').join(';configSave = webstorage');

                                    order_str = order_str.split(';configSave = webstorage_compress').join(';configSave = webstorage');

                                    order_str = order_str.split(';configSave=webstorage_compress').join(';configSave = webstorage');

                                    isConfigLoaded = true;

                                    ensureKagVariableInitialized();

                                    try {

                                        if (callback) callback(order_str);

                                    } finally {

                                        ensureKagVariableInitialized();

                                        while (pendingScenarioCallbacks.length > 0) {

                                            var nextFn = pendingScenarioCallbacks.shift();

                                            try { nextFn(); } catch (err) { console.error('[剧本队列执行异常]', err); }

                                        }

                                    }

                                    return;

                                }



                                var invokeScenario = function() {

                                    ensureKagVariableInitialized();

                                    if (callback) callback(order_str);

                                    ensureKagVariableInitialized();

                                };



                                if (!isConfigLoaded && pathStr.toLowerCase().endsWith('.ks')) {

                                    pendingScenarioCallbacks.push(invokeScenario);

                                    setTimeout(function() {

                                        if (!isConfigLoaded) {

                                            isConfigLoaded = true;

                                            while (pendingScenarioCallbacks.length > 0) {

                                                var fn = pendingScenarioCallbacks.shift();

                                                try { fn(); } catch (e) {}

                                            }

                                        }

                                    }, 300);

                                } else {

                                    invokeScenario();

                                }

                            } catch (err) {

                                console.error('[loadText 异常降级] (' + pathStr + '):', err);

                            }

                        });

                    };

                }

            }



            window.__tyranoHookStorageAndSF = hookTyranoStorageAndSF;

            hookTyranoStorageAndSF();

            window.addEventListener('load', hookTyranoStorageAndSF, true);

            document.addEventListener('readystatechange', hookTyranoStorageAndSF, true);

            document.addEventListener('DOMContentLoaded', hookTyranoStorageAndSF, true);

            [0, 10, 50, 150, 400, 1000].forEach(function(ms) {

                setTimeout(hookTyranoStorageAndSF, ms);

            });

        })();

        """



        let postloadViewportJS = """

        (function() {

            if (typeof window.__tyranoHookStorageAndSF === 'function') {

                window.__tyranoHookStorageAndSF();

            }



            var style = document.createElement('style');

            style.innerHTML = `

                * {

                    -webkit-touch-callout: none !important;

                    -webkit-user-select: none !important;

                    user-select: none !important;

                    -webkit-tap-highlight-color: transparent !important;

                }

                html, body {

                    margin: 0 !important;

                    padding: 0 !important;

                    width: 100% !important;

                    height: 100% !important;

                    overflow: hidden !important;

                    position: fixed !important;

                    inset: 0 !important;

                    background-color: #000000 !important;

                    touch-action: manipulation;

                }

                video { object-fit: contain; }

            `;

            document.head.appendChild(style);



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



                [0, 120, 350].forEach(function(delay) {

                    setTimeout(function() {

                        window.scrollTo(0, 0);

                        window.dispatchEvent(new Event('resize'));

                        window.dispatchEvent(new Event('orientationchange'));

                        if (window.jQuery) { window.jQuery(window).trigger('resize'); }

                        try {

                            if (window.TYRANO && window.TYRANO.kag && window.TYRANO.kag.view && typeof window.TYRANO.kag.view.resizeScreen === 'function') {

                                window.TYRANO.kag.view.resizeScreen();

                            }

                        } catch (e) {}

                        window.__tyranoApplyStretch();

                    }, delay);

                });

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

        webView.loadFileURL(entryHTMLURL, allowingReadAccessTo: readAccessURL)



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

            webView.loadFileURL(entryHTMLURL, allowingReadAccessTo: readAccessURL)

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

        let onConsoleLog: (ConsoleLogEntry) -> Void



        init(nativeSaveStoreURL: URL, onConsoleLog: @escaping (ConsoleLogEntry) -> Void) {

            self.nativeSaveStoreURL = nativeSaveStoreURL

            self.onConsoleLog = onConsoleLog

            super.init()

            reloadSaveDictFromDisk()

        }



        func reloadSaveDictFromDisk() {

            if let data = try? Data(contentsOf: nativeSaveStoreURL),

               let loaded = try? JSONSerialization.jsonObject(with: data) as? [String: String] {

                self.saveDict = loaded

            } else {

                self.saveDict = [:]

            }

        }



        func log(level: ConsoleLogLevel, message: String) {

            onConsoleLog(ConsoleLogEntry(timestamp: Date(), level: level, message: message))

        }



        private func persistSaveDict() {

            let dir = nativeSaveStoreURL.deletingLastPathComponent()

            if !FileManager.default.fileExists(atPath: dir.path) {

                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            }

            if let data = try? JSONSerialization.data(withJSONObject: saveDict, options: [.prettyPrinted]) {

                try? data.write(to: nativeSaveStoreURL, options: .atomic)

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

            log(level: .warn, message: "[WebKit] 渲染进程被系统回收，正在自动恢复…")

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

