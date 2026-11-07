import Foundation
import SwiftUI
import AppKit

private enum DefaultsKey {
    static let autoClose = "autoCloseWhenDone"
    static let verify = "verifyAfterCopy"
    static let alwaysOnTop = "alwaysOnTop"
    static let blur = "blur"
    static let recents = "recentDestinations"
    static let favorites = "favoriteDestinations"
}

func isExistingDirectory(_ url: URL) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
}

struct LogEntry: Identifiable {
    let id = UUID()
    let kind: LogKind
    let text: String
}

struct ConflictRequest: Identifiable {
    let id = UUID()
    let info: ConflictInfo
}

/// 差分プレビューの結果
struct PreviewResult: Identifiable {
    let id = UUID()
    let rows: [PreviewRow]
    let operation: OperationMode

    func count(_ outcome: PreviewOutcome) -> Int {
        rows.filter { $0.outcome == outcome }.count
    }
}

/// 比較が空欄のときの処理（同名ファイルの扱い）
enum PolicyChoice: String, CaseIterable, Identifiable {
    case ask, skip, overwrite, replace, keepBoth
    var id: String { rawValue }

    var label: String {
        switch self {
        case .ask: return L("確認")
        case .overwrite: return L("上書き")
        case .replace: return L("置き換え")
        case .skip: return L("スキップ")
        case .keepBoth: return L("両方残す")
        }
    }

    /// nil = 毎回確認
    var action: ConflictAction? {
        switch self {
        case .ask: return nil
        case .overwrite, .replace: return .overwrite
        case .skip: return .skip
        case .keepBoth: return .keepBoth
        }
    }
}

/// UI 状態。@Published の更新は必ずメインスレッドで行う。
final class CopyModel: ObservableObject {
    /// AppDelegate / サービス（右クリック）からも触れるように共有インスタンスにする
    static let shared = CopyModel()

    @Published var sources: [URL] = []
    @Published var destination: URL?

    // 動作・比較・処理
    @Published var operation: OperationMode = .copy
    @Published var compare: CompareMode = .none
    /// true = 新しい／大きいほうを残す、false = 古い／小さいほうを残す
    @Published var preferHigh = true
    @Published var policy: PolicyChoice = .ask

    // 歯車のポップアップ（次回起動時も保持）
    @Published var verify: Bool {
        didSet { UserDefaults.standard.set(verify, forKey: DefaultsKey.verify) }
    }
    @Published var alwaysOnTop: Bool {
        didSet {
            UserDefaults.standard.set(alwaysOnTop, forKey: DefaultsKey.alwaysOnTop)
            applyWindowLevel()
        }
    }
    @Published var autoCloseWhenDone: Bool {
        didSet { UserDefaults.standard.set(autoCloseWhenDone, forKey: DefaultsKey.autoClose) }
    }
    @Published var showOptions = false
    /// 背景はつねにすりガラス（透け方は固定）。ぼかし具合は 0…1（0 = ぼかさずそのまま透ける）
    let glass: Double = 1
    @Published var blur: Double {
        didSet { UserDefaults.standard.set(blur, forKey: DefaultsKey.blur) }
    }
    /// ドロップモード：コピー元のドロップ欄だけの小さな最前面ウインドウ（保存しない）
    @Published var dropMode = false {
        didSet { applyWindowLevel() }
    }

    /// コピー先の履歴とお気に入り（次回起動時も保持）
    @Published private(set) var recentFolders: [URL]
    @Published private(set) var favoriteFolders: [URL]

    @Published var isRunning = false { didSet { updateActivity() } }
    @Published var isAnalyzing = false { didSet { updateActivity() } }
    @Published var analyzeDone = 0
    @Published var analyzeTotal = 0
    @Published var progress = CopyProgress()
    @Published var logs: [LogEntry] = []
    @Published var pending: ConflictRequest?
    @Published var preview: PreviewResult?
    @Published var summaryText: String?
    @Published var srcTargeted = false
    @Published var dstTargeted = false

    private var task: Task<Void, Never>?
    private var analyzeTask: Task<Void, Never>?
    private var continuation: CheckedContinuation<ConflictDecision?, Never>?
    private var cancelRequested = false

    var busy: Bool { isRunning || isAnalyzing }

    /// 処理中は「ユーザーが頼んだ作業の最中」とシステムに伝える。
    /// userInitiated は、自動終了・即時終了の禁止とスリープの防止を含む（NSProcessInfo.h）。
    /// これがないと、最小化してウインドウが見えないあいだに macOS に終了させられることがある。
    private var activity: NSObjectProtocol?

    private func updateActivity() {
        if busy, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated,
                                                              reason: "SabunCopy: copying files")
        } else if !busy, let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
    }
    var canStart: Bool { destination != nil && !sources.isEmpty && !busy }

    init() {
        let d = UserDefaults.standard
        verify = d.bool(forKey: DefaultsKey.verify)
        alwaysOnTop = d.bool(forKey: DefaultsKey.alwaysOnTop)
        autoCloseWhenDone = d.bool(forKey: DefaultsKey.autoClose)
        blur = d.object(forKey: DefaultsKey.blur) == nil ? 0.8 : min(1, max(0, d.double(forKey: DefaultsKey.blur)))
        recentFolders = (d.stringArray(forKey: DefaultsKey.recents) ?? []).map { URL(fileURLWithPath: $0) }
        favoriteFolders = (d.stringArray(forKey: DefaultsKey.favorites) ?? []).map { URL(fileURLWithPath: $0) }
    }

    private var options: CopyOptions {
        CopyOptions(operation: operation,
                    compare: compare,
                    preferHigh: preferHigh,
                    verify: verify,
                    initialPolicy: policy.action,
                    replaceFolders: policy == .replace,
                    allowAdmin: true)
    }

    // MARK: Window

    /// 外観はライトに固定する（明るいすりガラスに暗い色を重ね、文字は白）
    func applyAppearance() {
        NSApp.appearance = NSAppearance(named: .aqua)
    }

    /// 「最前面に固定」をウインドウに反映する
    func applyWindowLevel() {
        let level: NSWindow.Level = (alwaysOnTop || dropMode) ? .floating : .normal
        for window in NSApp.windows where window.canBecomeMain {
            window.level = level
        }
    }

    // MARK: Inputs

    func addSources(_ urls: [URL]) {
        for url in urls {
            let u = url.standardizedFileURL
            if !sources.contains(u) { sources.append(u) }
        }
    }

    func clearSources() { sources.removeAll() }

    /// コピー先を決める。選んだフォルダは「最近使ったフォルダ」の先頭に入る
    func setDestination(_ url: URL) {
        let u = url.standardizedFileURL
        destination = u
        recentFolders.removeAll { $0.path == u.path }
        recentFolders.insert(u, at: 0)
        if recentFolders.count > 10 { recentFolders = Array(recentFolders.prefix(10)) }
        saveFolders()
    }

    func isFavorite(_ url: URL) -> Bool {
        favoriteFolders.contains { $0.path == url.standardizedFileURL.path }
    }

    func toggleFavorite(_ url: URL) {
        let u = url.standardizedFileURL
        if isFavorite(u) {
            removeFavorite(u)
        } else {
            favoriteFolders.append(u)
            saveFolders()
        }
    }

    func removeFavorite(_ url: URL) {
        let path = url.standardizedFileURL.path
        favoriteFolders.removeAll { $0.path == path }
        saveFolders()
    }

    func clearRecents() {
        recentFolders = []
        saveFolders()
    }

    private func saveFolders() {
        let d = UserDefaults.standard
        d.set(recentFolders.map { $0.path }, forKey: DefaultsKey.recents)
        d.set(favoriteFolders.map { $0.path }, forKey: DefaultsKey.favorites)
    }

    // MARK: Analyze

    func analyze() {
        guard let dest = destination, !sources.isEmpty, !busy else { return }
        isAnalyzing = true
        analyzeDone = 0
        analyzeTotal = 0
        summaryText = nil

        let srcs = sources
        let opts = options

        analyzeTask = Task.detached { [weak self] in
            let engine = CopyEngine()
            do {
                let rows = try engine.analyze(sources: srcs, destination: dest, options: opts) { done, total in
                    DispatchQueue.main.async {
                        self?.analyzeDone = done
                        self?.analyzeTotal = total
                    }
                }
                let result = PreviewResult(rows: rows, operation: opts.operation)
                DispatchQueue.main.async { self?.finishAnalyze(result, error: nil) }
            } catch is CancellationError {
                DispatchQueue.main.async { self?.finishAnalyze(nil, error: nil) }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async { self?.finishAnalyze(nil, error: message) }
            }
        }
    }

    private func finishAnalyze(_ result: PreviewResult?, error: String?) {
        isAnalyzing = false
        analyzeTask = nil
        if let error = error {
            summaryText = L("差分を確認できませんでした: %@", error)
        } else if let result = result {
            preview = result
        }
    }

    // MARK: Run

    func start() {
        guard let dest = destination, !sources.isEmpty, !busy else { return }
        isRunning = true
        cancelRequested = false
        logs = []
        summaryText = nil
        progress = CopyProgress()

        let srcs = sources
        let opts = options

        task = Task.detached { [weak self] in
            let engine = CopyEngine()
            let summary = await engine.run(
                sources: srcs,
                destination: dest,
                options: opts,
                ask: { info in await self?.ask(info) },
                progress: { p in DispatchQueue.main.async { self?.progress = p } },
                log: { kind, text in DispatchQueue.main.async { self?.appendLog(kind, text) } }
            )
            DispatchQueue.main.async { self?.finish(summary, operation: opts.operation) }
        }
    }

    func cancel() {
        cancelRequested = true
        task?.cancel()
        analyzeTask?.cancel()
        if let c = continuation {
            continuation = nil
            pending = nil
            c.resume(returning: nil)
        }
    }

    /// 競合ダイアログの結果を受け取る（メインスレッド）
    func resolve(_ decision: ConflictDecision?) {
        pending = nil
        if let c = continuation {
            continuation = nil
            c.resume(returning: decision)
        }
    }

    // MARK: Internals

    private func ask(_ info: ConflictInfo) async -> ConflictDecision? {
        await withCheckedContinuation { (cont: CheckedContinuation<ConflictDecision?, Never>) in
            DispatchQueue.main.async {
                if self.cancelRequested {
                    cont.resume(returning: nil)
                    return
                }
                self.continuation = cont
                self.pending = ConflictRequest(info: info)
            }
        }
    }

    private func appendLog(_ kind: LogKind, _ text: String) {
        logs.append(LogEntry(kind: kind, text: text))
    }

    private func finish(_ s: CopySummary, operation: OperationMode) {
        isRunning = false
        task = nil
        if let err = s.fatalError {
            summaryText = L("開始できませんでした: %@", err)
            appendLog(.error, err)
            return
        }
        var parts: [String] = []
        if s.copied > 0 {
            parts.append(operation == .move ? L("新規移動 %ld", s.copied) : L("新規コピー %ld", s.copied))
        }
        if s.overwritten > 0 { parts.append(L("上書き %ld", s.overwritten)) }
        if s.renamed > 0 { parts.append(L("別名保存 %ld", s.renamed)) }
        if s.skipped > 0 { parts.append(L("スキップ %ld", s.skipped)) }
        if s.failed > 0 { parts.append(L("失敗 %ld", s.failed)) }
        if s.movedSources > 0 { parts.append(L("移動元をゴミ箱へ %ld", s.movedSources)) }
        if s.replacedAway > 0 { parts.append(L("置き換えでゴミ箱へ %ld", s.replacedAway)) }
        if s.removedDirs > 0 { parts.append(L("空フォルダ整理 %ld", s.removedDirs)) }
        let body = parts.isEmpty ? L("処理したファイルはありません") : parts.joined(separator: " / ")
        summaryText = s.cancelled ? L("中止しました。 %@", body) : L("完了しました。 %@", body)

        // エラーも中止もなく終わったときだけ、少し待ってからアプリを終了する。
        // ウインドウを閉じる方式だと、最小化中のウインドウ（見えていない扱い）が残って終了しないため、
        // アプリの終了を直接呼ぶ。
        if autoCloseWhenDone && !s.cancelled && s.failed == 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self = self, !self.busy, self.pending == nil else { return }
                NSApp.terminate(nil)
            }
        }
    }
}
