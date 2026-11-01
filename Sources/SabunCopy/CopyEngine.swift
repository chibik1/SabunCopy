import Foundation
import CryptoKit

// MARK: - Options

enum OperationMode: String, CaseIterable, Identifiable, Sendable {
    case copy, move
    var id: String { rawValue }
    var label: String { self == .copy ? "コピー" : "移動" }
}

enum CompareMode: String, CaseIterable, Identifiable, Sendable {
    case timeOnly, sizeAndTime, sizeOnly, hash
    var id: String { rawValue }

    var label: String {
        switch self {
        case .timeOnly: return "更新日時"
        case .sizeAndTime: return "サイズ＋更新日時"
        case .sizeOnly: return "サイズ"
        case .hash: return "内容（SHA-256）"
        }
    }

    var detail: String {
        switch self {
        case .timeOnly: return "更新日時が同じなら同一とみなします（速い）"
        case .sizeAndTime: return "サイズと更新日時が両方同じなら同一とみなします（rsyncと同じ標準的な判定・速い）"
        case .sizeOnly: return "サイズが同じなら同一とみなします（日時が違ってもスキップ）"
        case .hash: return "ハッシュ値で内容まで比較します（確実ですが、大きなファイルは時間がかかります）"
        }
    }
}

enum ConflictAction: Sendable {
    case overwrite          // 常に上書き
    case overwriteIfNewer   // コピー元が新しいときだけ上書き
    case skip               // スキップ
    case keepBoth           // 両方残す（コピー元を別名で保存）
}

struct CopyOptions: Sendable {
    var operation: OperationMode = .copy
    var compare: CompareMode = .sizeAndTime
    var skipIdentical = true
    var verify = false
    var initialPolicy: ConflictAction?
}

// MARK: - Types

struct FileSnapshot: Sendable {
    let url: URL
    let size: Int64
    let modified: Date
}

struct Comparison: Sendable {
    let identical: Bool
    let srcNewer: Bool
    let dstNewer: Bool
}

struct ConflictInfo: Sendable {
    let source: FileSnapshot
    let destination: FileSnapshot
    let relativePath: String
    let identical: Bool
    let compareLabel: String
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

enum PreviewStatus: Sendable {
    case new            // コピー先に無い
    case identical      // 比較基準では同一
    case srcNewer       // コピー元のほうが新しい
    case dstNewer       // コピー先のほうが新しい
    case differ         // 日時は同じだが内容（サイズ/ハッシュ）が違う
    case error
}

struct PreviewRow: Identifiable, Sendable {
    let id = UUID()
    let path: String
    let status: PreviewStatus
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
                throw CopyError(message: "「\(name)」はコピー元とコピー先が同じ場所です")
            }

            if isDir {
                let srcPath = src.standardizedFileURL.path
                let destPath = destination.standardizedFileURL.path
                if destPath == srcPath || destPath.hasPrefix(srcPath + "/") {
                    throw CopyError(message: "「\(name)」の中にはコピーできません（コピー先がコピー元の内側です）")
                }

                items.append(PlanItem(source: src, destination: base, relativePath: name,
                                      isDirectory: true, isSymlink: false, size: 0))

                guard let en = fm.enumerator(at: src,
                                             includingPropertiesForKeys: Array(keys),
                                             options: [],
                                             errorHandler: { _, _ in true }) else { continue }
                for case let url as URL in en {
                    let v = try? url.resourceValues(forKeys: keys)
                    let link = v?.isSymbolicLink ?? false
                    let dir = (v?.isDirectory ?? false) && !link
                    let rel = String(url.path.dropFirst(src.path.count)) // "/sub/file"
                    items.append(PlanItem(source: url,
                                          destination: URL(fileURLWithPath: base.path + rel),
                                          relativePath: name + rel,
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

    // MARK: Analyze (差分プレビュー)

    func analyze(sources: [URL],
                 destination: URL,
                 compare mode: CompareMode,
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
                rows.append(PreviewRow(path: item.relativePath, status: .new, size: item.size))
                continue
            }
            if isDirectory(dst) {
                rows.append(PreviewRow(path: item.relativePath, status: .error, size: item.size))
                continue
            }
            let s = snapshot(of: item.source)
            let d = snapshot(of: dst)
            let c = compare(s, d, mode: mode, isSymlink: item.isSymlink)
            let status: PreviewStatus
            if c.identical { status = .identical }
            else if c.srcNewer { status = .srcNewer }
            else if c.dstNewer { status = .dstNewer }
            else { status = .differ }
            rows.append(PreviewRow(path: item.relativePath, status: status, size: item.size))
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
        log(.info, "\(options.operation.label)：\(p.filesTotal) ファイル（\(formatBytes(p.bytesTotal))）／比較基準：\(options.compare.label)")

        var sticky: ConflictAction? = options.initialPolicy

        for item in plan {
            if Task.isCancelled { summary.cancelled = true; break }

            if item.isDirectory {
                do {
                    try ensureDirectory(item.destination)
                } catch {
                    summary.failed += 1
                    log(.error, "フォルダを作成できません: \(item.relativePath) — \(error.localizedDescription)")
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
                    log(.info, "空になったフォルダをゴミ箱へ: \(item.relativePath)")
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
        let verb = isMove ? "移動" : "コピー"

        guard exists(dst) else {
            try ensureDirectory(dst.deletingLastPathComponent())
            try fm.copyItem(at: item.source, to: dst)
            restoreTimestamp(item, at: dst)
            try verifyIfNeeded(item, copy: dst, enabled: verifyNow)
            log(.copied, "\(verb): \(item.relativePath)")
            try finishMove(item, options: options)
            return .copied
        }

        if isDirectory(dst) {
            throw CopyError(message: "コピー先に同名のフォルダがあるためコピーできません")
        }

        let srcSnap = snapshot(of: item.source)
        let dstSnap = snapshot(of: dst)
        let cmp = compare(srcSnap, dstSnap, mode: options.compare, isSymlink: item.isSymlink)

        // 比較基準で同一なら自動スキップ
        if cmp.identical && options.skipIdentical {
            if isMove {
                var safeToRemove = options.compare == .hash || item.isSymlink
                if !safeToRemove { safeToRemove = try contentsEqual(srcSnap, dstSnap) }
                if safeToRemove {
                    try trashSource(item)
                    log(.skipped, "同一のためスキップし、移動元をゴミ箱へ: \(item.relativePath)")
                    return .skippedRemoved
                } else {
                    log(.skipped, "スキップ（比較基準では同一でも内容が異なるため移動元を残しました）: \(item.relativePath)")
                    return .skipped
                }
            }
            log(.skipped, "同一のためスキップ: \(item.relativePath)")
            return .skipped
        }

        let action: ConflictAction
        if let s = sticky {
            action = s
        } else {
            let info = ConflictInfo(source: srcSnap,
                                    destination: dstSnap,
                                    relativePath: item.relativePath,
                                    identical: cmp.identical,
                                    compareLabel: options.compare.label)
            guard let decision = await ask(info) else { return .cancelled }
            if decision.applyToAll { sticky = decision.action }
            action = decision.action
        }

        switch action {
        case .skip:
            log(.skipped, "スキップ\(isMove ? "（移動元は残します）" : ""): \(item.relativePath)")
            return .skipped

        case .overwriteIfNewer:
            if cmp.srcNewer {
                try copyReplacing(item)
                try verifyIfNeeded(item, copy: dst, enabled: verifyNow)
                log(.overwritten, "上書き（コピー元が新しい）: \(item.relativePath)")
                try finishMove(item, options: options)
                return .overwritten
            } else {
                log(.skipped, "スキップ（コピー先が同じか新しい）\(isMove ? "（移動元は残します）" : ""): \(item.relativePath)")
                return .skipped
            }

        case .overwrite:
            try copyReplacing(item)
            try verifyIfNeeded(item, copy: dst, enabled: verifyNow)
            log(.overwritten, "上書き: \(item.relativePath)")
            try finishMove(item, options: options)
            return .overwritten

        case .keepBoth:
            let newURL = uniqueURL(for: dst)
            try fm.copyItem(at: item.source, to: newURL)
            restoreTimestamp(item, at: newURL)
            try verifyIfNeeded(item, copy: newURL, enabled: verifyNow)
            log(.renamed, "別名で保存: \(item.relativePath) → \(newURL.lastPathComponent)")
            try finishMove(item, options: options)
            return .renamed
        }
    }

    // MARK: Compare

    private func compare(_ s: FileSnapshot, _ d: FileSnapshot, mode: CompareMode, isSymlink: Bool) -> Comparison {
        let dt = s.modified.timeIntervalSince(d.modified)
        let sameTime = abs(dt) < 2
        let sameSize = s.size == d.size

        let identical: Bool
        if isSymlink {
            let a = try? fm.destinationOfSymbolicLink(atPath: s.url.path)
            let b = try? fm.destinationOfSymbolicLink(atPath: d.url.path)
            identical = (a != nil) && (a == b)
        } else {
            switch mode {
            case .timeOnly:
                identical = sameTime
            case .sizeAndTime:
                identical = sameSize && sameTime
            case .sizeOnly:
                identical = sameSize
            case .hash:
                if !sameSize {
                    identical = false
                } else if let a = try? sha256(of: s.url), let b = try? sha256(of: d.url) {
                    identical = (a == b)
                } else {
                    identical = false
                }
            }
        }
        return Comparison(identical: identical, srcNewer: dt > 2, dstNewer: dt < -2)
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
            throw CopyError(message: "コピーは完了しましたが、移動元をゴミ箱へ移せませんでした（\(error.localizedDescription)）")
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
            throw CopyError(message: "同名のファイルがあるためフォルダを作成できません")
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
            throw CopyError(message: "照合に失敗しました（コピー元とコピー先の内容が一致しません）")
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
