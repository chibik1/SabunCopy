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
    /// 置き換え：同名フォルダはコピー元と同じ中身にする（コピー先にしかないものはゴミ箱へ）
    var replaceFolders = false
    /// 権限が足りない分を、最後にパスワードを聞いて管理者権限で処理する
    var allowAdmin = false
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
    var replacedAway = 0
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
    case trash      // 置き換えで、コピー先にだけあるのでゴミ箱へ
    case error
}

struct PreviewRow: Identifiable, Sendable {
    let id = UUID()
    let path: String
    let outcome: PreviewOutcome
    let size: Int64
    /// 書き込むのに管理者権限が要る（実行時にパスワードを聞く）
    var needsAdmin = false
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
    /// 管理者権限での実行役（テストで差し替える）
    var adminRunner: Privileged.Runner = Privileged.osascript
    private var adminEnabled = false
    /// 照合の方式ごとの件数（テストと確認用）
    private(set) var cloneVerifiedByIdentity = 0   // クローンと確認できたので読み直さなかった
    private(set) var streamedCopies = 0            // 読みながらハッシュを取って書いた
    /// テスト用：同じドライブでも、読みながら書く方式を使う
    var testForceStream = false
    /// テスト用：書き終えた直後（照合の前）にコピー先へ手を加える
    var testAfterWrite: ((URL) -> Void)?

    // MARK: Plan

    func buildPlan(sources: [URL], destination: URL) throws -> [PlanItem] {
        var items: [PlanItem] = []
        let destReal = realPath(destination)

        for src in sources {
            let name = src.lastPathComponent
            let base = destination.appendingPathComponent(name)
            let (isSymlink, isDir, size) = try kind(of: src, label: name)

            // コピー元と同じ場所に書こうとしていないか（シンボリックリンクを解決した実体のパスで見る）
            let srcLocation = isSymlink
                ? URL(fileURLWithPath: realPath(src.deletingLastPathComponent())).appendingPathComponent(name).path
                : realPath(src)
            if URL(fileURLWithPath: destReal).appendingPathComponent(name).path == srcLocation {
                throw CopyError(message: L("「%@」はコピー元とコピー先が同じ場所です", name))
            }

            if isDir {
                // コピー先がコピー元の内側ではないか
                if destReal == srcLocation || destReal.hasPrefix(srcLocation + "/") {
                    throw CopyError(message: L("「%@」の中にはコピーできません（コピー先がコピー元の内側です）", name))
                }

                try ensureReadable(src, label: name)
                items.append(PlanItem(source: src, destination: base, relativePath: name,
                                      isDirectory: true, isSymlink: false, size: 0))

                // 相対パスはそのまま受け取る（/var と /private/var のようにパスの前半が食い違っても壊れない）。
                // 読めないものがあれば、一部だけの計画にはせず、ここで中止する。
                guard let en = fm.enumerator(atPath: src.path) else {
                    throw CopyError(message: L("フォルダの中身を読み取れません: %@", name))
                }
                for case let rel as String in en {
                    let url = src.appendingPathComponent(rel)
                    let label = name + "/" + rel
                    let (link, dir, childSize) = try kind(of: url, label: label)
                    if link { en.skipDescendants() }
                    if dir { try ensureReadable(url, label: label) }
                    items.append(PlanItem(source: url,
                                          destination: base.appendingPathComponent(rel),
                                          relativePath: label,
                                          isDirectory: dir,
                                          isSymlink: link,
                                          size: childSize))
                }
            } else {
                items.append(PlanItem(source: src, destination: base, relativePath: name,
                                      isDirectory: false, isSymlink: isSymlink, size: size))
            }
        }
        return items
    }

    /// 種類（リンク／フォルダ）とサイズ。属性が読めないときは握りつぶさずエラーにする。
    private func kind(of url: URL, label: String) throws -> (isSymlink: Bool, isDirectory: Bool, size: Int64) {
        do {
            let attrs = try fm.attributesOfItem(atPath: url.path)   // lstat：リンクはリンクとして見る
            let type = attrs[.type] as? FileAttributeType
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            return (type == .typeSymbolicLink, type == .typeDirectory, size)
        } catch {
            throw CopyError(message: L("読み取れません: %@ — %@", label, error.localizedDescription))
        }
    }

    private func ensureReadable(_ dir: URL, label: String) throws {
        do {
            _ = try fm.contentsOfDirectory(atPath: dir.path)
        } catch {
            throw CopyError(message: L("読み取れません: %@ — %@", label, error.localizedDescription))
        }
    }

    /// シンボリックリンクをすべて解決した実体のパス（解決できなければ標準化したパス）
    private func realPath(_ url: URL) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(url.path, &buffer) != nil { return String(cString: buffer) }
        return url.standardizedFileURL.path
    }

    // MARK: Replace（置き換え）

    /// 置き換えでゴミ箱へ送る、コピー先にだけある項目（フォルダはいちばん上のものだけ）
    private func replaceOrphans(plan: [PlanItem]) -> [(url: URL, path: String)] {
        let known = Set(plan.map { $0.relativePath })
        var result: [(URL, String)] = []
        for top in plan where top.isDirectory && !top.relativePath.contains("/") {
            // コピー先がフォルダ（リンクでない）のときだけ
            guard let type = (try? fm.attributesOfItem(atPath: top.destination.path))?[.type] as? FileAttributeType,
                  type == .typeDirectory,
                  let en = fm.enumerator(atPath: top.destination.path) else { continue }
            for case let rel as String in en {
                let label = top.relativePath + "/" + rel
                let name = (rel as NSString).lastPathComponent
                if known.contains(label) { continue }
                if name == ".DS_Store" { continue }
                if name.hasPrefix(".sabun-") && name.hasSuffix(".tmp") { continue }
                en.skipDescendants()
                result.append((top.destination.appendingPathComponent(rel), label))
            }
        }
        return result
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
                rows.append(PreviewRow(path: item.relativePath, outcome: .new, size: item.size,
                                       needsAdmin: !canWrite(into: dst.deletingLastPathComponent())))
                continue
            }
            if isDirectory(dst) {
                rows.append(PreviewRow(path: item.relativePath, outcome: .error, size: item.size))
                continue
            }
            let outcome = plannedOutcome(snapshot(of: item.source), snapshot(of: dst),
                                         isSymlink: item.isSymlink, options: options)
            let writes = outcome == .overwrite || outcome == .ask || outcome == .keepBoth
            rows.append(PreviewRow(path: item.relativePath, outcome: outcome, size: item.size,
                                   needsAdmin: writes && !canWrite(into: dst.deletingLastPathComponent())))
        }
        progress(files.count, files.count)
        if options.replaceFolders && options.compare == .none {
            for o in replaceOrphans(plan: plan) {
                rows.append(PreviewRow(path: o.path, outcome: .trash, size: 0))
            }
        }
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
        adminEnabled = options.allowAdmin
        var adminOps: [AdminOp] = []

        for item in plan {
            if Task.isCancelled { summary.cancelled = true; break }

            if item.isDirectory {
                do {
                    try ensureDirectory(item.destination)
                } catch let need as NeedsAdmin {
                    adminOps.append(need.op)
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
            } catch let need as NeedsAdmin {
                adminOps.append(need.op)
                log(.info, L("管理者権限が必要: %@", item.relativePath))
            } catch {
                summary.failed += 1
                log(.error, "\(item.relativePath) — \(error.localizedDescription)")
            }

            p.filesDone += 1
            p.bytesDone += item.size
            progress(p)
        }

        // 管理者権限：権限が足りなかった分を、パスワードを 1 回聞いてまとめて処理する
        if !adminOps.isEmpty && !summary.cancelled {
            await runAdmin(adminOps, options: options, summary: &summary, log: log)
        }
        adminEnabled = false

        // 置き換え：コピー先にしかないものをゴミ箱へ（コピーが全部成功したときだけ）
        if options.replaceFolders && options.compare == .none && !summary.cancelled {
            if summary.failed == 0 {
                for o in replaceOrphans(plan: plan) {
                    do {
                        try fm.trashItem(at: o.url, resultingItemURL: nil)
                        summary.replacedAway += 1
                        log(.info, L("置き換え：コピー先にしかないためゴミ箱へ: %@", o.path))
                    } catch {
                        summary.failed += 1
                        log(.error, L("ゴミ箱へ移せません: %@ — %@", o.path, error.localizedDescription))
                    }
                }
            } else {
                log(.info, L("エラーがあったため、コピー先にしかないものは残しました"))
            }
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
            do {
                try ensureDirectory(dst.deletingLastPathComponent())
            } catch is NeedsAdmin {
                throw NeedsAdmin(op: AdminOp(kind: .file, result: .copied, item: item,
                                             destination: dst, relativePath: item.relativePath))
            }
            try copyViaTemp(item, to: dst, verify: verifyNow, replacing: false, as: .copied)
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
                try copyViaTemp(item, to: dst, verify: verifyNow, replacing: true, as: .overwritten)
                log(.overwritten, L("上書き（コピー元が新しい）: %@", item.relativePath))
                try finishMove(item, options: options)
                return .overwritten
            } else {
                log(.skipped, isMove ? L("スキップ（コピー先が同じか新しい・移動元は残します）: %@", item.relativePath)
                                 : L("スキップ（コピー先が同じか新しい）: %@", item.relativePath))
                return .skipped
            }

        case .overwrite:
            // 中身がまったく同じなら書き直さない（速く、確実）。
            // サイズと更新日時が同じときだけ中身を比べる（違えば比べるまでもなく上書き）
            let sameMeta = !item.isSymlink && srcSnap.size == dstSnap.size
                && abs(srcSnap.modified.timeIntervalSince(dstSnap.modified)) < 2
            let sameContent = sameMeta ? try contentsEqual(srcSnap, dstSnap) : false
            if sameContent {
                if isMove {
                    try trashSource(item)
                    log(.skipped, L("内容が同一のため上書きせず、移動元をゴミ箱へ: %@", item.relativePath))
                    return .skippedRemoved
                }
                log(.skipped, L("内容が同一のため上書きしませんでした: %@", item.relativePath))
                return .skipped
            }
            try copyViaTemp(item, to: dst, verify: verifyNow, replacing: true, as: .overwritten)
            log(.overwritten, rulePhrase.isEmpty ? L("上書き: %@", item.relativePath)
                                              : L("上書き（%@）: %@", rulePhrase, item.relativePath))
            try finishMove(item, options: options)
            return .overwritten

        case .keepBoth:
            let newURL = uniqueURL(for: dst)
            try copyViaTemp(item, to: newURL, verify: verifyNow, replacing: false, as: .renamed)
            log(.renamed, L("別名で保存: %@ → %@", item.relativePath, newURL.lastPathComponent))
            try finishMove(item, options: options)
            return .renamed
        }
    }

    private func contentsEqual(_ s: FileSnapshot, _ d: FileSnapshot) throws -> Bool {
        guard s.size == d.size else { return false }
        if isClone(s.url, d.url) { return true }   // クローン同士は中身を共有している（読まずに分かる）
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
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            if adminEnabled && Privileged.isPermissionError(error) {
                throw NeedsAdmin(op: AdminOp(kind: .directory, result: .directory, item: nil,
                                             destination: url, relativePath: url.path))
            }
            throw error
        }
    }

    /// そのフォルダ（無ければ、いちばん近い既存の親）に、今のユーザで書き込めるか
    private func canWrite(into dir: URL) -> Bool {
        var d = dir
        while !fm.fileExists(atPath: d.path) {
            let parent = d.deletingLastPathComponent()
            if parent.path == d.path { break }
            d = parent
        }
        return fm.isWritableFile(atPath: d.path)
    }

    // MARK: Admin

    private func runAdmin(_ ops: [AdminOp], options: CopyOptions,
                          summary: inout CopySummary, log: LogHandler) async {
        let files = ops.filter { $0.kind == .file }.count
        log(.info, L("管理者権限が必要な %ld 件を処理します（パスワードを確認します）", ops.count))
        let prompt = L("SabunCopy が管理者権限で %ld 件をコピーしようとしています。", max(files, ops.count))
        var ok = Set<Int>()
        var failure: Privileged.RunError?
        for chunk in Privileged.scripts(for: ops) {
            switch await adminRunner(chunk.script, prompt) {
            case .success(let out):
                ok.formUnion(Privileged.succeeded(in: out))
            case .failure(let e):
                failure = e
            }
            if failure != nil { break }
        }

        let isMove = options.operation == .move
        for (i, op) in ops.enumerated() {
            guard ok.contains(i) else {
                summary.failed += 1
                if let f = failure, f.cancelled {
                    log(.error, L("パスワードの確認がキャンセルされたため、コピーしませんでした: %@", op.relativePath))
                } else if let f = failure {
                    log(.error, L("管理者権限で実行できませんでした（%@）: %@", f.message, op.relativePath))
                } else {
                    log(.error, L("管理者権限でもコピーできませんでした: %@", op.relativePath))
                }
                continue
            }
            guard op.kind == .file, let item = op.item else {
                log(.info, L("管理者権限でフォルダを作成: %@", op.destination.lastPathComponent))
                continue
            }
            // 照合（移動のときは必ず）。読み取りは今のユーザでできる
            if (options.verify || isMove) && !item.isSymlink {
                let same = (try? sha256(of: item.source)) == (try? sha256(of: op.destination))
                if !same {
                    summary.failed += 1
                    log(.error, L("照合が一致しないため失敗扱いにしました: %@", item.relativePath))
                    continue
                }
            }
            switch op.result {
            case .copied:
                summary.copied += 1
                log(.copied, L("管理者権限でコピー: %@", item.relativePath))
            case .overwritten:
                summary.overwritten += 1
                log(.overwritten, L("管理者権限で上書き: %@", item.relativePath))
            case .renamed:
                summary.renamed += 1
                log(.renamed, L("管理者権限で別名で保存: %@", item.relativePath))
            case .directory:
                break
            }
            if isMove {
                do { try trashSource(item) } catch {
                    summary.failed += 1
                    log(.error, "\(item.relativePath) — \(error.localizedDescription)")
                }
            }
        }
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

    /// 同じフォルダの一時ファイルへ書き、照合まで済んでから最終の名前に切り替える。
    /// 途中で失敗しても（強制終了しても）、最終の名前に中途半端なファイルが残らない。
    /// 上書きのときも、新しい内容が揃うまで既存のファイルには触れない。
    private func copyViaTemp(_ item: PlanItem, to final: URL, verify: Bool, replacing: Bool,
                             as result: AdminOp.Result) throws {
        let tmp = final.deletingLastPathComponent()
            .appendingPathComponent(".sabun-\(UUID().uuidString).tmp")
        do {
            try copyAndVerify(item, to: tmp, verify: verify)   // 切り替える前に照合まで済ませる
            if !replacing {
                try fm.moveItem(at: tmp, to: final)                // 同名ができていたら失敗する（上書きしない）
            } else if item.isSymlink {
                try atomicRename(tmp, to: final)                   // リンクは rename で一度に置き換える
            } else {
                _ = try fm.replaceItemAt(final, withItemAt: tmp)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            if adminEnabled && Privileged.isPermissionError(error) {
                throw NeedsAdmin(op: AdminOp(kind: .file, result: result, item: item,
                                             destination: final, relativePath: item.relativePath))
            }
            throw error
        }
        if replacing { restoreTimestamp(item, at: final) }
    }

    // MARK: Copy + verify

    /// コピーの方式を自動で選ぶ。
    /// - 同じ APFS ボリューム：OS のコピー（クローン）。コピー元と同じ fileContentIdentifier なら
    ///   クローン（データを共有）なので、読み直さずに一致とみなす。違えば通常どおり読み比べる。
    /// - それ以外：コピー元を読みながらハッシュを取り、そのまま書く。キャッシュを使わず書き、
    ///   キャッシュを使わず読み直すので、照合はディスク上の内容を確かめる（F_NOCACHE）。
    private func copyAndVerify(_ item: PlanItem, to tmp: URL, verify: Bool) throws {
        let dir = tmp.deletingLastPathComponent()
        if item.isSymlink {
            try fm.copyItem(at: item.source, to: tmp)
            return
        }
        if !testForceStream && canClone(from: item.source, into: dir) {
            try fm.copyItem(at: item.source, to: tmp)
            restoreTimestamp(item, at: tmp)
            guard verify else { return }
            if isClone(item.source, tmp) {
                cloneVerifiedByIdentity += 1
                return
            }
            testAfterWrite?(tmp)
            try verifyIfNeeded(item, copy: tmp, enabled: true)
            return
        }
        let sourceHash = try streamCopy(from: item.source, to: tmp, hashing: verify)
        streamedCopies += 1
        // 権限・日時・ACL・拡張属性（リソースフォークを含む）を写す
        if copyfile(item.source.path, tmp.path, nil, copyfile_flags_t(COPYFILE_STAT | COPYFILE_ACL | COPYFILE_XATTR)) != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        restoreTimestamp(item, at: tmp)
        testAfterWrite?(tmp)
        if let expected = sourceHash {
            let actual = try sha256Uncached(of: tmp)
            if actual != expected {
                throw CopyError(message: L("照合に失敗しました（コピー元とコピー先の内容が一致しません）"))
            }
        }
    }

    /// 同じボリュームで、そのボリュームがクローンに対応しているか
    private func canClone(from source: URL, into dir: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.volumeIdentifierKey, .volumeSupportsFileCloningKey]
        guard let s = try? source.resourceValues(forKeys: [.volumeIdentifierKey]),
              let d = try? dir.resourceValues(forKeys: keys),
              let sv = s.volumeIdentifier as? NSObject, let dv = d.volumeIdentifier as? NSObject,
              d.volumeSupportsFileCloning == true else { return false }
        return sv.isEqual(dv)
    }

    /// APFS では、クローンとその元だけが同じ fileContentIdentifier を持てる（Apple のドキュメント）
    private func isClone(_ a: URL, _ b: URL) -> Bool {
        func id(_ u: URL) -> Int64? {
            var u = u
            u.removeAllCachedResourceValues()
            return (try? u.resourceValues(forKeys: [.fileContentIdentifierKey]))?.fileContentIdentifier
        }
        guard let x = id(a), let y = id(b) else { return false }
        return x == y
    }

    private static let ioChunk = 8 * 1024 * 1024
    private static let ioAlign = 16 * 1024   // ページ境界にそろえる（F_NOCACHE の読み書きを速くする）

    /// コピー元を読みながら（必要なら）ハッシュを取り、一時ファイルに書く。キャッシュは使わない。
    private func streamCopy(from src: URL, to dst: URL, hashing: Bool) throws -> String? {
        let inFD = open(src.path, O_RDONLY)
        guard inFD >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(inFD) }
        let outFD = open(dst.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard outFD >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var closed = false
        defer { if !closed { close(outFD) } }
        _ = fcntl(inFD, F_NOCACHE, 1)
        _ = fcntl(outFD, F_NOCACHE, 1)

        let buf = UnsafeMutableRawPointer.allocate(byteCount: Self.ioChunk, alignment: Self.ioAlign)
        defer { buf.deallocate() }
        var hasher = SHA256()
        while true {
            if Task.isCancelled { throw CancellationError() }
            let n = read(inFD, buf, Self.ioChunk)
            if n < 0 {
                if errno == EINTR { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            if n == 0 { break }
            if hashing { hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buf, count: n)) }
            var off = 0
            while off < n {
                let w = write(outFD, buf + off, n - off)
                if w < 0 {
                    if errno == EINTR { continue }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                off += w
            }
        }
        closed = true
        if close(outFD) != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return hashing ? hasher.finalize().map { String(format: "%02x", $0) }.joined() : nil
    }

    /// キャッシュを使わずに読んでハッシュを取る（ディスク上の内容を確かめる）
    private func sha256Uncached(of url: URL) throws -> String {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        let buf = UnsafeMutableRawPointer.allocate(byteCount: Self.ioChunk, alignment: Self.ioAlign)
        defer { buf.deallocate() }
        var hasher = SHA256()
        while true {
            let n = read(fd, buf, Self.ioChunk)
            if n < 0 {
                if errno == EINTR { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            if n == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buf, count: n))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func atomicRename(_ from: URL, to: URL) throws {
        if rename(from.path, to.path) != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
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
        // 読んだデータを 1 回ごとに解放する（区切りが無いと、読んだ分がファイルの大きさまで溜まり続ける。
        // 2 GB のファイルで最大 2 GB → 10 MB になることを測って確認）
        while true {
            let more: Bool = try autoreleasepool {
                let chunk = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
                if chunk.isEmpty { return false }
                hasher.update(data: chunk)
                return true
            }
            if !more { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func formatBytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}
