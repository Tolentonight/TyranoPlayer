import SwiftUI
import UIKit

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask = .allButUpsideDown

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        return AppDelegate.orientationLock
    }
}

enum ScreenOrientationMode: String, CaseIterable, Identifiable, Sendable {
    case auto = "跟随系统"
    case landscape = "锁定横屏"
    case portrait = "锁定竖屏"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .auto: return "rectangle.portrait.rotate"
        case .landscape: return "rectangle.ratio.16.to.9"
        case .portrait: return "rectangle.portrait"
        }
    }

    var mask: UIInterfaceOrientationMask {
        switch self {
        case .auto: return .allButUpsideDown
        case .landscape: return .landscape
        case .portrait: return .portrait
        }
    }
}

@MainActor
final class OrientationManager: ObservableObject {
    static let shared = OrientationManager()
    @Published var currentMode: ScreenOrientationMode = .landscape

    private init() {}

    func apply(_ mode: ScreenOrientationMode) {
        currentMode = mode
        AppDelegate.orientationLock = mode.mask

        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else { return }

        let prefs = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: mode.mask)
        windowScene.requestGeometryUpdate(prefs) { _ in }
        windowScene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    func resetToDefault() {
        AppDelegate.orientationLock = .allButUpsideDown
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else { return }

        let prefs = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: .allButUpsideDown)
        windowScene.requestGeometryUpdate(prefs) { _ in }
        windowScene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}

@main
struct TyranoPlayerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var importer = GameImporter()
    @StateObject private var orientationManager = OrientationManager.shared

    var body: some Scene {
        WindowGroup {
            GameLibraryView()
                .environmentObject(importer)
                .environmentObject(orientationManager)
        }
    }
}
