// CopyEngine の動作確認（実ファイルを使う簡易テスト）
// 実行: ./Tests/run_engine_check.sh
// 一時フォルダに「新規／同一／コピー元が新しい／コピー先が新しい／サイズ違い」のファイルを作り、
// 比較（更新日時・サイズ）と処理（上書き・スキップ・両方残す・確認）、移動の結果を検査する。
import Foundation

let fm = FileManager.default
/// 実行ごとの ID。後片付けはこの ID を含むものだけを対象にする（他の実行や利用者のファイルに触れない）
let runID = ProcessInfo.processInfo.environment["SABUN_TEST_ID"] ?? String(UUID().uuidString.prefix(12))
/// テスト用ファイル名の接頭辞（移動テストでゴミ箱に入っても、この実行のものだと分かる）
let P = "sabuntest_\(runID)_"
let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sabun-test-\(runID)")

let old = Date(timeIntervalSinceNow: -86400 * 10)
let new = Date(timeIntervalSinceNow: -3600)

var failures = 0
func check(_ label: String, _ ok: Bool) {
    print(ok ? "PASS" : "FAIL", label)
    if !ok { failures += 1 }
}

func write(_ url: URL, _ text: String, mtime: Date) throws {
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
    try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
}

func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

final class Counter: @unchecked Sendable {
    var asked = 0
}

func makeCase(_ name: String) throws -> (src: URL, dst: URL) {
    let base = root.appendingPathComponent(name)
    let s = base.appendingPathComponent("src/proj")
    let d = base.appendingPathComponent("dst/proj")
    try write(s.appendingPathComponent("\(P)new.txt"), "N", mtime: new)
    try write(s.appendingPathComponent("\(P)same.txt"), "SAME", mtime: new)
    try write(d.appendingPathComponent("\(P)same.txt"), "SAME", mtime: new)
    try write(s.appendingPathComponent("\(P)srcnewer.txt"), "SRC-NEW", mtime: new)
    try write(d.appendingPathComponent("\(P)srcnewer.txt"), "OLD", mtime: old)
    try write(s.appendingPathComponent("\(P)dstnewer.txt"), "SRC-OLD", mtime: old)
    try write(d.appendingPathComponent("\(P)dstnewer.txt"), "DST-NEW", mtime: new)
    try write(s.appendingPathComponent("\(P)bigsrc.txt"), "BIGGER-SOURCE", mtime: new)
    try write(d.appendingPathComponent("\(P)bigsrc.txt"), "small", mtime: new)
    try write(s.appendingPathComponent("\(P)bigdst.txt"), "tiny", mtime: new)
    try write(d.appendingPathComponent("\(P)bigdst.txt"), "BIGGER-DEST!!", mtime: new)
    return (s, base.appendingPathComponent("dst"))
}

@discardableResult
func run(_ name: String, _ options: CopyOptions, counter: Counter = Counter()) async throws
    -> (summary: CopySummary, src: URL, dst: URL) {
    let (src, dstRoot) = try makeCase(name)
    let engine = CopyEngine()
    let summary = await engine.run(
        sources: [src], destination: dstRoot, options: options,
        ask: { _ in counter.asked += 1; return ConflictDecision(action: .skip, applyToAll: false) },
        progress: { _ in }, log: { _, _ in })
    return (summary, src, dstRoot.appendingPathComponent("proj"))
}

func f(_ dir: URL, _ n: String) -> URL { dir.appendingPathComponent("\(P)\(n).txt") }

func runAll() async throws {
    // 1. 比較＝更新日時 / 新しいほうを残す
    do {
        var o = CopyOptions(); o.compare = .time; o.preferHigh = true
        let r = try await run("time-high", o)
        check("time/新しい: 新規はコピー", text(f(r.dst, "new")) == "N")
        check("time/新しい: 同一は触らない", text(f(r.dst, "same")) == "SAME")
        check("time/新しい: コピー元が新しい→上書き", text(f(r.dst, "srcnewer")) == "SRC-NEW")
        check("time/新しい: コピー先が新しい→残す", text(f(r.dst, "dstnewer")) == "DST-NEW")
        check("time/新しい: 日時同じ→スキップ（サイズ違いでも）", text(f(r.dst, "bigsrc")) == "small")
        check("time/新しい: 集計 新規1 上書1 スキップ4",
              r.summary.copied == 1 && r.summary.overwritten == 1 && r.summary.skipped == 4)
        let leftovers = ((try? fm.contentsOfDirectory(atPath: r.dst.path)) ?? []).filter { $0.hasPrefix(".sabun-") }
        check("一時ファイル(.sabun-*)がコピー先に残らない", leftovers.isEmpty)
    }
    // 2. 比較＝更新日時 / 古いほうを残す
    do {
        var o = CopyOptions(); o.compare = .time; o.preferHigh = false
        let r = try await run("time-low", o)
        check("time/古い: コピー元が新しい→残さない（スキップ）", text(f(r.dst, "srcnewer")) == "OLD")
        check("time/古い: コピー元が古い→上書き", text(f(r.dst, "dstnewer")) == "SRC-OLD")
    }
    // 3. 比較＝サイズ / 大きいほうを残す
    do {
        var o = CopyOptions(); o.compare = .size; o.preferHigh = true
        let r = try await run("size-high", o)
        check("size/大きい: コピー元が大きい→上書き", text(f(r.dst, "bigsrc")) == "BIGGER-SOURCE")
        check("size/大きい: コピー先が大きい→残す", text(f(r.dst, "bigdst")) == "BIGGER-DEST!!")
        check("size/大きい: サイズ同じ→スキップ", text(f(r.dst, "dstnewer")) == "DST-NEW")
        check("size/大きい: 日時が違ってもサイズでコピー元が大きければ上書き", text(f(r.dst, "srcnewer")) == "SRC-NEW")
    }
    // 4. 比較＝サイズ / 小さいほうを残す
    do {
        var o = CopyOptions(); o.compare = .size; o.preferHigh = false
        let r = try await run("size-low", o)
        check("size/小さい: コピー元が大きい→残さない", text(f(r.dst, "bigsrc")) == "small")
        check("size/小さい: コピー元が小さい→上書き", text(f(r.dst, "bigdst")) == "tiny")
    }
    // 5. 比較なし / 上書き
    do {
        var o = CopyOptions(); o.compare = .none; o.initialPolicy = .overwrite
        let r = try await run("none-overwrite", o)
        check("なし/上書き: すべて上書き",
              text(f(r.dst, "srcnewer")) == "SRC-NEW" && text(f(r.dst, "dstnewer")) == "SRC-OLD"
              && text(f(r.dst, "bigsrc")) == "BIGGER-SOURCE")
    }
    // 6. 比較なし / スキップ
    do {
        var o = CopyOptions(); o.compare = .none; o.initialPolicy = .skip
        let r = try await run("none-skip", o)
        check("なし/スキップ: 競合は触らず新規だけコピー",
              text(f(r.dst, "new")) == "N" && text(f(r.dst, "srcnewer")) == "OLD" && text(f(r.dst, "dstnewer")) == "DST-NEW")
    }
    // 7. 比較なし / 両方残す
    do {
        var o = CopyOptions(); o.compare = .none; o.initialPolicy = .keepBoth
        let r = try await run("none-keepboth", o)
        let copy = r.dst.appendingPathComponent("\(P)srcnewer (2).txt")
        check("なし/両方残す: 元のファイルはそのまま", text(f(r.dst, "srcnewer")) == "OLD")
        check("なし/両方残す: 別名でコピー元を保存", text(copy) == "SRC-NEW")
    }
    // 8. 比較なし / 確認（ダイアログを呼ぶ）
    do {
        let c = Counter()
        var o = CopyOptions(); o.compare = .none; o.initialPolicy = nil
        let r = try await run("none-ask", o, counter: c)
        check("なし/確認: 競合5件ぶん確認を求める", c.asked == 5)
        check("なし/確認: スキップを返したので変更なし", text(f(r.dst, "srcnewer")) == "OLD")
    }
    // 9. 移動 / 更新日時・新しいほうを残す
    do {
        var o = CopyOptions(); o.operation = .move; o.compare = .time; o.preferHigh = true
        let r = try await run("move", o)
        check("移動: 新規は移動（移動元が消える）",
              text(f(r.dst, "new")) == "N" && !fm.fileExists(atPath: f(r.src, "new").path))
        check("移動: 上書きした分も移動元が消える",
              text(f(r.dst, "srcnewer")) == "SRC-NEW" && !fm.fileExists(atPath: f(r.src, "srcnewer").path))
        check("移動: 内容が同一のものは移動元だけ消える",
              text(f(r.dst, "same")) == "SAME" && !fm.fileExists(atPath: f(r.src, "same").path))
        check("移動: スキップしたもの（コピー先が新しい）は移動元に残る",
              fm.fileExists(atPath: f(r.src, "dstnewer").path) && text(f(r.dst, "dstnewer")) == "DST-NEW")
        check("移動: 日時が同じでも内容が違うものは移動元を消さない",
              fm.fileExists(atPath: f(r.src, "bigsrc").path) && text(f(r.dst, "bigsrc")) == "small")
        check("移動: 残りがあるフォルダは消さない", fm.fileExists(atPath: r.src.path))
    }
    // 11. 安全性（コードレビューの指摘）
    let quiet: (CopyEngine, [URL], URL, CopyOptions) async -> CopySummary = { engine, sources, dest, options in
        await engine.run(sources: sources, destination: dest, options: options,
                         ask: { _ in nil }, progress: { _ in }, log: { _, _ in })
    }
    do { // 読めないフォルダがあるなら、一部だけコピーせず中止する
        let base = root.appendingPathComponent("unreadable")
        let src = base.appendingPathComponent("src/proj")
        let dstRoot = base.appendingPathComponent("dst")
        try write(src.appendingPathComponent("\(P)ok.txt"), "OK", mtime: new)
        let locked = src.appendingPathComponent("locked")
        try write(locked.appendingPathComponent("\(P)hidden.txt"), "HIDDEN", mtime: new)
        try fm.createDirectory(at: dstRoot, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        let summary = await quiet(CopyEngine(), [src], dstRoot, CopyOptions())
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        check("読めないフォルダがあれば、何もコピーせず中止する",
              summary.fatalError != nil && !fm.fileExists(atPath: dstRoot.appendingPathComponent("proj").path))
    }
    do { // コピー先がシンボリックリンク経由でコピー元の内側
        let base = root.appendingPathComponent("symlink-inside")
        let src = base.appendingPathComponent("src/proj")
        try write(src.appendingPathComponent("sub/\(P)a.txt"), "A", mtime: new)
        let link = base.appendingPathComponent("linkdest")
        try fm.createSymbolicLink(at: link, withDestinationURL: src.appendingPathComponent("sub"))
        let summary = await quiet(CopyEngine(), [src], link, CopyOptions())
        check("コピー先がリンク経由でコピー元の内側なら中止する", summary.fatalError != nil)
    }
    do { // リンク経由で、コピー元と同じ場所へ書こうとする
        let base = root.appendingPathComponent("symlink-same")
        let srcParent = base.appendingPathComponent("src")
        let src = srcParent.appendingPathComponent("proj")
        try write(src.appendingPathComponent("\(P)a.txt"), "A", mtime: new)
        let link = base.appendingPathComponent("linkdest")
        try fm.createSymbolicLink(at: link, withDestinationURL: srcParent)
        var o = CopyOptions(); o.initialPolicy = .overwrite
        let summary = await quiet(CopyEngine(), [src], link, o)
        check("リンク経由でコピー元と同じ場所に書くなら中止する", summary.fatalError != nil)
        check("そのとき、コピー元のファイルは無事", text(src.appendingPathComponent("\(P)a.txt")) == "A")
    }
    do { // シンボリックリンクの上書き
        let base = root.appendingPathComponent("symlink-overwrite")
        let s = base.appendingPathComponent("src/proj")
        let d = base.appendingPathComponent("dst/proj")
        try fm.createDirectory(at: s, withIntermediateDirectories: true)
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: s.appendingPathComponent("\(P)link"), withDestinationURL: URL(fileURLWithPath: "/tmp/A-\(runID)"))
        try fm.createSymbolicLink(at: d.appendingPathComponent("\(P)link"), withDestinationURL: URL(fileURLWithPath: "/tmp/B-\(runID)"))
        var o = CopyOptions(); o.initialPolicy = .overwrite
        _ = await quiet(CopyEngine(), [s], base.appendingPathComponent("dst"), o)
        let target = try? fm.destinationOfSymbolicLink(atPath: d.appendingPathComponent("\(P)link").path)
        check("シンボリックリンクを上書きできる", target == "/tmp/A-\(runID)")
        let leftovers = ((try? fm.contentsOfDirectory(atPath: d.path)) ?? []).filter { $0.hasPrefix(".sabun-") }
        check("リンクの上書きでも一時ファイルが残らない", leftovers.isEmpty)
    }
    do { // 書き込めないコピー先：失敗として数え、中途半端なものを残さない
        let base = root.appendingPathComponent("readonly-dst")
        let src = base.appendingPathComponent("src/proj")
        try write(src.appendingPathComponent("\(P)new.txt"), "N", mtime: new)
        let dstProj = base.appendingPathComponent("dst/proj")
        try fm.createDirectory(at: dstProj, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dstProj.path)
        let summary = await quiet(CopyEngine(), [src], base.appendingPathComponent("dst"), CopyOptions())
        let names = (try? fm.contentsOfDirectory(atPath: dstProj.path)) ?? []
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dstProj.path)
        check("書き込めないコピー先は失敗として数える", summary.failed == 1 && summary.copied == 0)
        check("失敗したあとにファイルが残らない", names.isEmpty)
    }
    // 10. 差分プレビューの判断が実行と一致する
    do {
        let (src, dstRoot) = try makeCase("analyze")
        var o = CopyOptions(); o.compare = .time; o.preferHigh = true
        let rows = try CopyEngine().analyze(sources: [src], destination: dstRoot, options: o) { _, _ in }
        func outcome(_ n: String) -> PreviewOutcome? {
            rows.first { $0.path.hasSuffix("\(P)\(n).txt") }?.outcome
        }
        check("プレビュー: 新規", outcome("new") == .new)
        check("プレビュー: 同一", outcome("same") == .same)
        check("プレビュー: 上書き", outcome("srcnewer") == .overwrite)
        check("プレビュー: スキップ（コピー先が新しい）", outcome("dstnewer") == .skip)
    }
    // 11. 置き換え：コピー先にしかないものはゴミ箱へ、他は上書き。通常の上書きでは残る
    do {
        func prepare(_ name: String) throws -> (src: URL, dstRoot: URL, extra: URL, extraDir: URL) {
            let (src, dstRoot) = try makeCase(name)
            let d = dstRoot.appendingPathComponent("proj")
            let extra = d.appendingPathComponent("\(P)extra.txt")
            let extraDir = d.appendingPathComponent("\(P)extradir")
            try write(extra, "EXTRA", mtime: new)
            try write(extraDir.appendingPathComponent("\(P)deep.txt"), "DEEP", mtime: new)
            return (src, dstRoot, extra, extraDir)
        }
        let a = try prepare("replace")
        var o = CopyOptions(); o.initialPolicy = .overwrite; o.replaceFolders = true
        let rows = try CopyEngine().analyze(sources: [a.src], destination: a.dstRoot, options: o) { _, _ in }
        check("プレビュー: 置き換えで消えるものを列挙（フォルダは1件）",
              rows.filter { $0.outcome == .trash }.count == 2)
        let summary = await quiet(CopyEngine(), [a.src], a.dstRoot, o)
        let d = a.dstRoot.appendingPathComponent("proj")
        check("置き換え: コピー先にしかないファイルが消える", !fm.fileExists(atPath: a.extra.path))
        check("置き換え: コピー先にしかないフォルダが消える", !fm.fileExists(atPath: a.extraDir.path))
        check("置き換え: 同名は上書き・新規はコピー",
              text(d.appendingPathComponent("\(P)dstnewer.txt")) == "SRC-OLD"
              && text(d.appendingPathComponent("\(P)new.txt")) == "N")
        check("置き換え: 件数", summary.replacedAway == 2 && summary.failed == 0)

        let b = try prepare("overwrite-keeps")
        var o2 = CopyOptions(); o2.initialPolicy = .overwrite
        _ = await quiet(CopyEngine(), [b.src], b.dstRoot, o2)
        check("通常の上書きではコピー先にしかないものが残る",
              fm.fileExists(atPath: b.extra.path) && fm.fileExists(atPath: b.extraDir.path))
    }
}

do {
    try await runAll()
} catch {
    print("ERROR", error)
    failures += 1
}
print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
print("temp:", root.path)
exit(failures == 0 ? 0 : 1)
