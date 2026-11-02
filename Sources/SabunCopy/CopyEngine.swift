import Foundation
import CryptoKit

// MARK: - Options

enum OperationMode: String, CaseIterable, Identifiable, Sendable {
    case copy, move
    var id: String { rawValue }
    var label: String { self == .copy ? L("コピー") : L("移動") }
}

/// 同名ファイルを比べる基準。none（空欄）のときは比べず、「処理」で扱いを決める。
enum CompareMode: String, CaseIterable, Identifiable, Sendable {
    case none, time, size
    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "—"
        case .time: return L("更新日時")
        case .size: return L("サイズ")
        }
    }

    /// 残すほうの名前（高いほう／低いほう）
    var highLabel: String { self == .size ? L("大きい") : L("新しい") }
    var lowLabel: String { self == .size ? L("小さい") : L("古い") }
}

enum ConflictAction: Sendable {
    case overwrite          // 上書き
    case overwriteIfNewer   // 確認ダイアログ用：コピー元が新しいときだけ上書き
    case skip               // スキップ
    case keepBoth           // 両方残す（コピー元を別名で保存）
}

struct CopyOptions: Sendable {
    var operation: OperationMode = .copy
    var compare: CompareMode = .none
    /// true = 新しい／大きいほうを残す、false = 古い／小さいほうを残す
    var preferHigh = true
    var verify = false
    /// compare が none のときの処理。nil = 毎回確認
    var initialPolicy: ConflictAction?
}

// MARK: - Types

struct FileSnapshot: Sendable {
    let url: URL
    let size: Int64
    let modified: Date
}

struct ConflictInfo: Sendable {
    let source: FileSnapshot
    let destination: FileSnapshot
    let relativePath: String
    let identical: Bool
}

struct ConflictDecision: Sendable {
    let action: ConflictAction
    let applyToAll: Bool
}

struct CopyProgress: Sendable {
    var filesDone = 0
    var filesTotal = 0
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0
    var current = ""

    var fraction: Double {
        if bytesTotal > 0 { return min(1, Double(bytesDone) / Double(bytesTotal)) }
        if filesTotal > 0 { return min(1, Double(filesDone) / Double(filesTotal)) }
        return 0
    }
}

enum LogKind: Sendable {
    case copied, overwritten, renamed, skipped, error, info
}

struct CopySummary: Sendable {
    var copied = 0
    var overwritten = 0
    var renamed = 0
    var skipped = 0
    var failed = 0
    var movedSources = 0
    var removedDirs = 0
    var cancelled = false
    var fatalError: String?
}

struct PlanItem: Sendable {
    let source: URL
    let destination: URL
    let relativePath: String
    let isDirectory: Bool
    let isSymlink: Bool
    let size: Int64
}

/// 実行したらどうなるか（差分プレビュー用）
enum PreviewOutcome: Sendable {
    case new        // コピー先に無い → そのまま
    case overwrite  // 上書き
    case same       // 比較基準で同一 → スキップ
    case skip       // スキップ（コピー先を残す／処理がスキップ）
    case ask        // 実行時に確認
    case keepBoth   // 別名で両方残す
    case error
}

struct PreviewRow: Identifiable, Sendable {
    let id = UUID()
    let path: String
    let outcome: PreviewOutcome
    let size: Int64
}

struct CopyError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Engine

final class CopyEngine: @unchecked Sendable {
    typealias AskHandler = @Sendable (ConflictInfo) async -> ConflictDecision?
    typealias ProgressHandler = @Sendable (CopyProgress) -> Void
    typealias LogHandler = @Sendable (LogKind, String) -> Void

    private enum Outcome {
        case copied, overwritten, renamed, skipped, skippedRemoved, cancelled
    }

    private let fm = FileManager.default
    private var removedFiles = 0
    private var removedDirs = 0

    // MARK: Plan

    func buildPlan(sources: [URL], destination: URL) throws -> [PlanItem] {
        var items: [PlanItem] = []
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]

        for src in sources {
            let name = src.lastPathComponent
            let base = destination.appendingPathComponent(name)
            let values = try src.resourceValues(forKeys: keys)
            let isSymlink = values.isSymbolicLink ?? false
            let isDir = (values.isDirectory ?? false) && !isSymlink

            if base.standardizedFileURL.path == src.standardizedFileURL.path {
                throw CopyError(message: L("「%@」はコピー元とコピー先が同じ場所です", name))
            }

            if isDir {
                let srcPath = src.standardizedFileURL.path
                let destPath = destination.standardizedFileURL.path
                if destPath == srcPath || destPath.hasPrefix(srcPath + "/") {
                    throw CopyError(message: L("「%@」の中にはコピーできません（コピー先がコピー元の内側です）", name))
                }

                items.append(PlanItem(source: src, destination: base, relativePath: name,
                                      isDirectory: true, isSymlink: false, size: 0))

                // 相対パスはそのまま受け取る（/var と /private/var のようにパスの前半が食い違っても壊れない）
                guard let en = fm.enumerator(atPath: src.path) else { continue }
                for case let rel as String in en {
                    let url = src.appendingPathComponent(rel)
                    let v = try? url.resourceValues(forKeys: keys)
                    let link = v?.isSymbolicLink ?? false
                    let dir = (v?.isDirectory ?? false) && !link
                    if link { en.skipDescendants() }
                    items.append(PlanItem(source: url,
                                          destination: base.appendingPathComponent(rel),
                                          relativePath: name + "/" + rel,
                                          isDirectory: dir,
                                          isSymlink: link,
                                          size: Int64(v?.fileSize ?? 0)))
                }
            } else {
                items.append(PlanItem(source: src, destination: base, relativePath: name,
                                      isDirectory: false, isSymlink: isSymlink,
                                      size: Int64(values.fileSize ?? 0)))
            }
        }
        return items
    }

    // MARK: Decide（実行と差分プレビューで同じ判断を使う）

    /// 同名ファイルがあるときの判断
    private func plannedOutcome(_ s: FileSnapshot, _ d: FileSnapshot,
                                isSymlink: Bool, options: CopyOptions) -> PreviewOutcome {
        if options.compare != .none {
            if isSymlink {
                let a = try? fm.destinationOfSymbolicLink(atPath: s.url.path)
                let b = try? fm.destinationOfSymbolicLink(atPath: d.url.path)
                return (a != nil && a == b) ? .same : .overwrite
            }
            let rank: Int
            switch options.compare {
            case .time:
                let dt = s.modified.timeIntervalSince(d.modified)
                rank = abs(dt) < 2 ? 0 : (dt > 0 ? 1 : -1)
            case .size:
                rank = s.size == d.size ? 0 : (s.size > d.size ? 1 : -1)
            case .none:
                rank = 0
            }
            if rank == 0 { return .same }
            let sourceWins = options.preferHigh ? rank > 0 : rank < 0
            return sourceWins ? .overwrite : .skip
        }

        switch options.initialPolicy {
        case .some(.overwrite): return .overwrite
        case .some(.skip): return .skip
        case .some(.keepBoth): return .keepBoth
        default: return .ask
        }
    }

    // MARK: Analyze (差分プレビュー)

    func analyze(sources: [URL],
                 destination: URL,
                 options: CopyOptions,
                 progress: (Int, Int) -> Void) throws -> [PreviewRow] {
        let plan = try buildPlan(sources: sources, destination: destination)
        let files = plan.filter { !$0.isDirectory }
        var rows: [PreviewRow] = []
        rows.reserveCapacity(files.count)

        for (index, item) in files.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            progress(index, files.count)

            let dst = item.destination
            if !exists(dst) {
                rows.append(PreviewRow(path: item.relativePath, outcome: .new, size: item.size))
                continue
            }
            if isDirectory(dst) {
                rows.append(PreviewRow(path: item.relativePath, outcome: .error, size: item.size))
                continue
            }
            let outcome = plannedOutcome(snapshot(of: item.source), snapshot(of: dst),
                                         isSymlink: item.isSymlink, options: options)
            rows.append(PreviewRow(path: item.relativePath, outcome: outcome, size: item.size))
        }
        progress(files.count, files.count)
        return rows
    }

    // MARK: Run

    func run(sources: [URL],
             destination: URL,
             options: CopyOptions,
             ask: AskHandler,
             progress: ProgressHandler,
             log: LogHandler) async -> CopySummary {
        var summary = CopySummary()
        removedFiles = 0
        removedDirs = 0

        let plan: [PlanItem]
        do {
            plan = try buildPlan(sources: sources, destination: destination)
        } catch {
            summary.fatalError = error.localizedDescription
            return summary
        }

        var p = CopyProgress()
        p.filesTotal = plan.filter { !$0.isDirectory }.count
        p.bytesTotal = plan.reduce(0) { $0 + $1.size }
        progress(p)
        log(.info, L("%@：%ld ファイル（%@）", options.operation.label, p.filesTotal, formatBytes(p.bytesTotal)))

        var sticky: ConflictAction? = nil

        for item in plan {
            if Task.isCancelled { summary.cancelled = true; break }

            if item.isDirectory {
                do {
                    try ensureDirectory(item.destination)
                } catch {
                    summary.failed += 1
                    log(.error, L("フォルダを作成できません: %@ — %@", item.relativePath, error.localizedDescription))
                }
                continue
            }

            p.current = item.relativePath
            progress(p)

            do {
                let outcome = try await processFile(item, options: options, sticky: &sticky, ask: ask, log: log)
                switch outcome {
                case .copied: summary.copied += 1
                case .overwritten: summary.overwritten += 1
                case .renamed: summary.renamed += 1
                case .skipped, .skippedRemoved: summary.skipped += 1
                case .cancelled: break
                }
                if outcome == .cancelled {
                    summary.cancelled = true
                    break
                }
            } catch {
                summary.failed += 1
                log(.error, "\(item.relativePath) — \(error.localizedDescription)")
            }

            p.filesDone += 1
            p.bytesDone += item.size
            progress(p)
        }

        // 移動：空になったフォルダを片付ける（深いほうから）
        if options.operation == .move && !summary.cancelled {
            for item in plan.reversed() where item.isDirectory {
                if removeIfEmpty(item.source) {
                    removedDirs += 1
                    log(.info, L("空になったフォルダをゴミ箱へ: %@", item.relativePath))
                }
            }
        }

        summary.movedSources = removedFiles
        summary.removedDirs = removedDirs
        return summary
    }

    // MARK: Per-file

    private func processFile(_ item: PlanItem,
                             options: CopyOptions,
                             sticky: inout ConflictAction?,
                             ask: AskHandler,
                             log: LogHandler) async throws -> Outcome {
        let dst = item.destination
        let isMove = options.operation == .move
        let verifyNow = options.verify || isMove   // 移動は必ず照合してから元を消す

        guard exists(dst) else {
            try ensureDirectory(dst.deletingLastPathComponent())
            try fm.copyItem(at: item.source, to: dst)
            restoreTimestamp(item, at: dst)
            try verifyIfNeeded(item, copy: dst, enabled: verifyNow)
            log(.copied, isMove ? L("移動: %@", item.relativePath) : L("コピー: %@", item.relativePath))
            try finishMove(item, options: options)
            return .copied
        }

        if isDirectory(dst) {
            throw CopyError(message: L("コピー先に同名のフォルダがあるためコピーできません"))
        }

        let srcSnap = snapshot(of: item.source)
        let dstSnap = snapshot(of: dst)
        let planned = plannedOutcome(srcSnap, dstSnap, isSymlink: item.isSymlink, options: options)

        // 比較基準で同一 → スキップ
        if planned == .same {
            if isMove {
                // 比較基準が弱いので、内容が本当に同じか確かめてから移動元を片付ける
                var safeToRemove = item.isSymlink
                if !safeToRemove { safeToRemove = try contentsEqual(srcSnap, dstSnap) }
                if safeToRemove {
                    try trashSource(item)
                    log(.skipped, L("同一のためスキップし、移動元をゴミ箱へ: %@", item.relativePath))
                    return .skippedRemoved
                }
                log(.skipped, L("スキップ（比較では同一でも内容が異なるため移動元を残しました）: %@", item.relativePath))
                return .skipped
            }
            log(.skipped, L("同一のためスキップ: %@", item.relativePath))
            return .skipped
        }

        let action: ConflictAction
        switch planned {
        case .overwrite: action = .overwrite
        case .skip: action = .skip
        case .keepBoth: action = .keepBoth
        default:
            if let s = sticky {
                action = s
            } else {
                let identical = srcSnap.size == dstSnap.size
                    && abs(srcSnap.modified.timeIntervalSince(dstSnap.modified)) < 2
                let info = ConflictInfo(source: srcSnap,
                                        destination: dstSnap,
                                        relativePath: item.relativePath,
                                        identical: identical)
                guard let decision = await ask(info) else { return .cancelled }
                if decision.applyToAll { sticky = decision.action }
                action = decision.action
            }
        }

        // 比較で決まった上書きのときに添える、ルールの説明
        let rulePhrase: String
        switch (options.compare, options.preferHigh) {
        case (.time, true): rulePhrase = L("更新日時が新しいほうを残す")
        case (.time, false): rulePhrase = L("更新日時が古いほうを残す")
        case (.size, true): rulePhrase = L("サイズが大きいほうを残す")
        case (.size, false): rulePhrase = L("サイズが小さいほうを残す")
        case (.none, _): rulePhrase = ""
        }

        switch action {
        case .skip:
            let keptDestination = options.compare != .none
            if keptDestination {
                log(.skipped, isMove ? L("スキップ（コピー先を残す・移動元は残します）: %@", item.relativePath)
                                     : L("スキップ（コピー先を残す）: %@", item.relativePath))
            } else {
                log(.skipped, isMove ? L("スキップ（移動元は残します）: %@", item.relativePath)
                                     : L("スキップ: %@", item.relativePath))
            }
            return .skipped

        case .overwriteIfNewer:
            if srcSnap.modified > dstSnap.modified.addingTimeInterval(2) {
                try copyReplacing(item)
                try verifyIfNeeded(item, copy: dst, enabled: verifyNow)
                log(.overwritten, L("上書き（コピー元が新しい）: %@", item.relativePath))
                try finishMove(item, options: options)
                return .overwritten
            } else {
                log(.skipped, isMove ? L("スキップ（コピー先が同じか新しい・移動元は残します）: %@", item.relativePath)
                                 : L("スキップ（コピー先が同じか新しい）: %@", item.relativePath))
                return .skipped
            }

        case .overwrite:
            try copyReplacing(item)
            try verifyIfNeeded(item, copy: dst, enabled: verifyNow)
            log(.overwritten, rulePhrase.isEmpty ? L("上書き: %@", item.relativePath)
                                              : L("上書き（%@）: %@", rulePhrase, item.relativePath))
            try finishMove(item, options: options)
            return .overwritten

        case .keepBoth:
            let newURL = uniqueURL(for: dst)
            try fm.copyItem(at: item.source, to: newURL)
            restoreTimestamp(item, at: newURL)
            try verifyIfNeeded(item, copy: newURL, enabled: verifyNow)
            log(.renamed, L("別名で保存: %@ → %@", item.relativePath, newURL.lastPathComponent))
            try finishMove(item, options: options)
            return .renamed
        }
    }

    private func contentsEqual(_ s: FileSnapshot, _ d: FileSnapshot) throws -> Bool {
        guard s.size == d.size else { return false }
        return try sha256(of: s.url) == sha256(of: d.url)
    }

    // MARK: Move helpers

    private func finishMove(_ item: PlanItem, options: CopyOptions) throws {
        guard options.operation == .move else { return }
        try trashSource(item)
    }

    private func trashSource(_ item: PlanItem) throws {
        do {
            try fm.trashItem(at: item.source, resultingItemURL: nil)
            removedFiles += 1
        } catch {
            throw CopyError(message: L("コピーは完了しましたが、移動元をゴミ箱へ移せませんでした（%@）", error.localizedDescription))
        }
    }

    private func removeIfEmpty(_ url: URL) -> Bool {
        guard let names = try? fm.contentsOfDirectory(atPath: url.path) else { return false }
        guard names.filter({ $0 != ".DS_Store" }).isEmpty else { return false }
        do {
            try fm.trashItem(at: url, resultingItemURL: nil)
            return true
        } catch {
            return false
        }
    }

    // MARK: Helpers

    private func exists(_ url: URL) -> Bool {
        (try? fm.attributesOfItem(atPath: url.path)) != nil // lstat なのでリンク切れも検出できる
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private func ensureDirectory(_ url: URL) throws {
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
            if isDir.boolValue { return }
            throw CopyError(message: L("同名のファイルがあるためフォルダを作成できません"))
        }
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func snapshot(of url: URL) -> FileSnapshot {
        let attrs = (try? fm.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let date = (attrs[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
        return FileSnapshot(url: url, size: size, modified: date)
    }

    private func restoreTimestamp(_ item: PlanItem, at url: URL) {
        guard !item.isSymlink else { return }
        if let date = (try? fm.attributesOfItem(atPath: item.source.path))?[.modificationDate] as? Date {
            try? fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
    }

    /// 一時ファイルにコピーしてから置き換える（途中で失敗しても既存ファイルを壊さない）
    private func copyReplacing(_ item: PlanItem) throws {
        let dst = item.destination
        if item.isSymlink {
            try fm.removeItem(at: dst)
            try fm.copyItem(at: item.source, to: dst)
            return
        }
        let tmp = dst.deletingLastPathComponent()
            .appendingPathComponent(".sabun-\(UUID().uuidString).tmp")
        do {
            try fm.copyItem(at: item.source, to: tmp)
            _ = try fm.replaceItemAt(dst, withItemAt: tmp)
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
        restoreTimestamp(item, at: dst)
    }

    private func uniqueURL(for url: URL) -> URL {
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !exists(candidate) { return candidate }
            n += 1
        }
    }

    private func verifyIfNeeded(_ item: PlanItem, copy: URL, enabled: Bool) throws {
        guard enabled, !item.isSymlink else { return }
        let a = try sha256(of: item.source)
        let b = try sha256(of: copy)
        if a != b {
            throw CopyError(message: L("照合に失敗しました（コピー元とコピー先の内容が一致しません）"))
        }
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func formatBytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}
