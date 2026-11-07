import AppKit
import Combine

/// 最小化しているあいだだけ、メニューバーにアイコンを出す。
/// ・進み具合（%）をアイコンの横に表示
/// ・クリックで「状況」「ウインドウを表示」「中止」を選べる
/// macOS には最小化そのものを取り消す公式の仕組みがないので、ウインドウは普通に最小化させ、
/// その間の操作口としてメニューバーを使う（Dock のアイコンは残す）。
final class MenuBarController: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?
    private var observers: [NSObjectProtocol] = []
    private var cancellable: AnyCancellable?
    private weak var minimizedWindow: NSWindow?

    func start() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSWindow.didMiniaturizeNotification, object: nil, queue: .main) { [weak self] note in
            guard let w = note.object as? NSWindow, w.styleMask.contains(.titled), !(w is NSPanel) else { return }
            self?.minimizedWindow = w
            self?.show()
        })
        observers.append(nc.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.hide()
        })
        // 進み具合の変化でアイコン横の表示を更新（細かすぎる更新は間引く）
        cancellable = CopyModel.shared.objectWillChange
            .throttle(for: .milliseconds(300), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refreshTitle() }
            }
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    private func show() {
        if item == nil {
            let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            i.button?.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "SabunCopy")
            i.button?.imagePosition = .imageLeading
            let menu = NSMenu()
            menu.delegate = self
            i.menu = menu
            item = i
        }
        refreshTitle()
    }

    private func hide() {
        if let i = item { NSStatusBar.system.removeStatusItem(i) }
        item = nil
    }

    private func refreshTitle() {
        guard let button = item?.button else { return }
        let m = CopyModel.shared
        if m.isRunning, m.progress.filesTotal > 0 {
            button.title = " \(Int((m.progress.fraction * 100).rounded()))%"
        } else {
            button.title = ""
        }
    }

    // メニューは開くたびに作り直す（最新の状況を出す）
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let m = CopyModel.shared
        let status: String
        if m.isRunning {
            status = L("処理中 %ld / %ld ファイル", m.progress.filesDone, m.progress.filesTotal)
        } else if m.isAnalyzing {
            status = L("差分を確認中…")
        } else if let s = m.summaryText {
            status = s
        } else {
            status = L("待機中")
        }
        let info = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        menu.addItem(.separator())
        let showItem = NSMenuItem(title: L("ウインドウを表示"), action: #selector(showWindow), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)
        let stop = NSMenuItem(title: L("中止"), action: m.busy ? #selector(cancel) : nil, keyEquivalent: "")
        stop.target = self
        stop.isEnabled = m.busy
        menu.addItem(stop)
    }

    @objc private func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = minimizedWindow ?? NSApp.windows.first(where: { $0.isMiniaturized }) {
            w.deminiaturize(nil)
            w.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func cancel() {
        CopyModel.shared.cancel()
    }
}
