import Foundation
import SwiftUI
import AppKit

private enum DefaultsKey {
    static let autoClose = "autoCloseWhenDone"
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

/// 差分プレビューの結果（実行時の設定のスナップショット付き）
struct PreviewResult: Identifiable {
    let id = UUID()
    let rows: [PreviewRow]
    let operation: OperationMode
    let compare: CompareMode
    let skipIdentical: Bool
    let policyLabel: String

    func count(_ status: PreviewStatus) -> Int {
        rows.filter { $0.status == status }.count
    }
}

/// 競合時の動作（モード）。ask = 毎回確認
enum PolicyChoice: String, CaseIterable, Identifiable {
    case ask, newer, skip, overwrite, keepBoth
    var id: String { rawValue }

    var label: String {
        switch self {
        case .ask: return "毎回確認"
        case .newer: return "新しいほうだけ上書き"
        case .skip: return "常にスキップ"
        case .overwrite: return "常に上書き"
        case .keepBoth: return "常に両方残す"
        }
    }

    var action: ConflictAction? {
        switch self {
        case .ask: return nil
        case .newer: return .overwriteIfNewer
        case .skip: return .skip
        case .overwrite: return .overwrite
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

    @Published var operation: OperationMode = .copy
    @Published var compare: CompareMode = .sizeAndTime
    @Published var skipIdentical = true
    @Published var verify = false
    @Published var policy: PolicyChoice = .ask

    /// すべての処理が終わったらウインドウを自動で閉じる（次回起動時も保持）
    @Published var autoCloseWhenDone: Bool {
        didSet { UserDefaults.standard.set(autoCloseWhenDone, forKey: DefaultsKey.autoClose) }
    }
    /// コピー先の履歴とお気に入り（次回起動時も保持）
    @Published private(set) var recentFolders: [URL]
    @Published private(set) var favoriteFolders: [URL]

    @Published var isRunning = false
    @Published var isAnalyzing = false
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
    var canStart: Bool { destination != nil && !sources.isEmpty && !busy }

    init() {
        let d = UserDefaults.standard
        autoCloseWhenDone = d.bool(forKey: DefaultsKey.autoClose)
        recentFolders = (d.stringArray(forKey: DefaultsKey.recents) ?? []).map { URL(fileURLWithPath: $0) }
        favoriteFolders = (d.stringArray(forKey: DefaultsKey.favorites) ?? []).map { URL(fileURLWithPath: $0) }
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
        let mode = compare
        let op = operation
        let skip = skipIdentical
        let policyLabel = policy.label

        analyzeTask = Task.detached { [weak self] in
            let engine = CopyEngine()
            do {
                let rows = try engine.analyze(sources: srcs, destination: dest, compare: mode) { done, total in
                    DispatchQueue.main.async {
                        self?.analyzeDone = done
                        self?.analyzeTotal = total
                    }
                }
                let result = PreviewResult(rows: rows, operation: op, compare: mode,
                                           skipIdentical: skip, policyLabel: policyLabel)
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
            summaryText = "差分を確認できませんでした: \(error)"
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
        let options = CopyOptions(operation: operation,
                                  compare: compare,
                                  skipIdentical: skipIdentical,
                                  verify: verify,
                                  initialPolicy: policy.action)

        task = Task.detached { [weak self] in
            let engine = CopyEngine()
            let summary = await engine.run(
                sources: srcs,
                destination: dest,
                options: options,
                ask: { info in await self?.ask(info) },
                progress: { p in DispatchQueue.main.async { self?.progress = p } },
                log: { kind, text in DispatchQueue.main.async { self?.appendLog(kind, text) } }
            )
            DispatchQueue.main.async { self?.finish(summary, operation: options.operation) }
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
            summaryText = "開始できませんでした: \(err)"
            appendLog(.error, err)
            return
        }
        var parts: [String] = []
        if s.copied > 0 { parts.append("新規\(operation.label) \(s.copied)") }
        if s.overwritten > 0 { parts.append("上書き \(s.overwritten)") }
        if s.renamed > 0 { parts.append("別名保存 \(s.renamed)") }
        if s.skipped > 0 { parts.append("スキップ \(s.skipped)") }
        if s.failed > 0 { parts.append("失敗 \(s.failed)") }
        if s.movedSources > 0 { parts.append("移動元をゴミ箱へ \(s.movedSources)") }
        if s.removedDirs > 0 { parts.append("空フォルダ整理 \(s.removedDirs)") }
        let body = parts.isEmpty ? "処理したファイルはありません" : parts.joined(separator: " / ")
        summaryText = (s.cancelled ? "中止しました。 " : "完了しました。 ") + body

        // エラーも中止もなく終わったときだけ、少し待ってからウインドウを閉じる
        if autoCloseWhenDone && !s.cancelled && s.failed == 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self = self, !self.busy, self.pending == nil else { return }
                NSApp.windows.filter { $0.isVisible && $0.canBecomeMain }.forEach { $0.close() }
            }
        }
    }
}
