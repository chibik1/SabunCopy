import SwiftUI
import AppKit

// MARK: - Finder の右クリック「サービス」

/// Finder で右クリック → サービス から呼ばれる。Info.plist の NSServices と対応。
final class ServicesProvider: NSObject {
    private func fileURLs(from pboard: NSPasteboard) -> [URL] {
        let objects = pboard.readObjects(forClasses: [NSURL.self],
                                         options: [.urlReadingFileURLsOnly: true])
        return (objects as? [URL]) ?? []
    }

    @objc(addToSources:userData:error:)
    func addToSources(_ pboard: NSPasteboard,
                      userData: String,
                      error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = fileURLs(from: pboard)
        DispatchQueue.main.async {
            CopyModel.shared.addSources(urls)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc(setAsDestination:userData:error:)
    func setAsDestination(_ pboard: NSPasteboard,
                          userData: String,
                          error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = fileURLs(from: pboard)
        DispatchQueue.main.async {
            if let dir = urls.first(where: isExistingDirectory) {
                CopyModel.shared.setDestination(dir)
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let services = ServicesProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = services
        CopyModel.shared.applyAppearance()
        // コピー元の一覧などを保持しているので、ウインドウが見えないあいだもシステムに自動終了させない
        ProcessInfo.processInfo.automaticTerminationSupportEnabled = false
        ProcessInfo.processInfo.disableAutomaticTermination("SabunCopy keeps the source list")
    }

    /// Dock アイコンへのドロップ／「このアプリで開く」で渡されたものはコピー元に追加する
    func application(_ application: NSApplication, open urls: [URL]) {
        DispatchQueue.main.async {
            CopyModel.shared.addSources(urls)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

// MARK: - App

@main
struct SabunCopyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // .app 化せずに実行した場合でもウインドウを前面に出せるようにする
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("SabunCopy", id: "main") {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}
