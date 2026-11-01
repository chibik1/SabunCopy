// CopyEngine の動作確認（実ファイルを使う簡易テスト）
// 実行: ./Tests/run_engine_check.sh
// 一時フォルダに「新規／同一／コピー元が新しい／コピー先が新しい／サイズ違い」のファイルを作り、
// 比較（更新日時・サイズ）と処理（上書き・スキップ・両方残す・確認）、移動の結果を検査する。
import Foundation

let fm = FileManager.default
let root = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("sabun-test-\(UUID().uuidString)")

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

/// 名前に sabuntest_ を付けておく（移動でゴミ箱に入ったとき見分けるため）
func makeCase(_ name: String) throws -> (src: URL, dst: URL) {
    let base = root.appendingPathComponent(name)
    let s = base.appendingPathComponent("src/proj")
    let d = base.appendingPathComponent("dst/proj")
    try write(s.appendingPathComponent("sabuntest_new.txt"), "N", mtime: new)
    try write(s.appendingPathComponent("sabuntest_same.txt"), "SAME", mtime: new)
    try write(d.appendingPathComponent("sabuntest_same.txt"), "SAME", mtime: new)
    try write(s.appendingPathComponent("sabuntest_srcnewer.txt"), "SRC-NEW", mtime: new)
    try write(d.appendingPathComponent("sabuntest_srcnewer.txt"), "OLD", mtime: old)
    try write(s.appendingPathComponent("sabuntest_dstnewer.txt"), "SRC-OLD", mtime: old)
    try write(d.appendingPathComponent("sabuntest_dstnewer.txt"), "DST-NEW", mtime: new)
    try write(s.appendingPathComponent("sabuntest_bigsrc.txt"), "BIGGER-SOURCE", mtime: new)
    try write(d.appendingPathComponent("sabuntest_bigsrc.txt"), "small", mtime: new)
    try write(s.appendingPathComponent("sabuntest_bigdst.txt"), "tiny", mtime: new)
    try write(d.appendingPathComponent("sabuntest_bigdst.txt"), "BIGGER-DEST!!", mtime: new)
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

func f(_ dir: URL, _ n: String) -> URL { dir.appendingPathComponent("sabuntest_\(n).txt") }

func main() async throws {
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
        let copy = r.dst.appendingPathComponent("sabuntest_srcnewer (2).txt")
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
    // 10. 差分プレビューの判断が実行と一致する
    do {
        let (src, dstRoot) = try makeCase("analyze")
        var o = CopyOptions(); o.compare = .time; o.preferHigh = true
        let rows = try CopyEngine().analyze(sources: [src], destination: dstRoot, options: o) { _, _ in }
        func outcome(_ n: String) -> PreviewOutcome? {
            rows.first { $0.path.hasSuffix("sabuntest_\(n).txt") }?.outcome
        }
        check("プレビュー: 新規", outcome("new") == .new)
        check("プレビュー: 同一", outcome("same") == .same)
        check("プレビュー: 上書き", outcome("srcnewer") == .overwrite)
        check("プレビュー: スキップ（コピー先が新しい）", outcome("dstnewer") == .skip)
    }
}

do {
    try await main()
} catch {
    print("ERROR", error)
    failures += 1
}
print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
print("temp:", root.path)
exit(failures == 0 ? 0 : 1)
