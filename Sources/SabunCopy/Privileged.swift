import Foundation

/// 管理者権限が必要になった 1 件分の操作
struct AdminOp: Sendable {
    enum Kind: Sendable { case directory, file }
    /// 成功したときに数える結果
    enum Result: Sendable { case directory, copied, overwritten, renamed }

    let kind: Kind
    let result: Result
    let item: PlanItem?          // ファイルのとき：コピー元
    let destination: URL         // ファイルのとき：最終の名前／フォルダのとき：作るフォルダ
    let relativePath: String
}

/// 権限が足りずに書けなかったことを、エンジン内で伝えるためのエラー
struct NeedsAdmin: Error {
    let op: AdminOp
}

/// 管理者権限でのコピー。
/// macOS 標準のパスワード画面（AppleScript の `do shell script … with administrator privileges`、
/// Apple TN2065）で、まとめた命令を 1 回で実行する。
/// - 承認は同じ命令に限って 5 分間有効。命令が変われば聞き直される。
/// - 命令の長さには上限がある（kern.argmax）。件数が多くても 1 回で済むよう、本体はファイルで渡す。
/// - サンドボックスのアプリでは動かない（SabunCopy はサンドボックス外）。
enum Privileged {
    /// 実行役。テストでは普通のシェルに差し替える。
    /// 戻り値：標準出力（成功時）またはエラー文（失敗・キャンセル時）
    typealias Runner = @Sendable (_ script: String, _ prompt: String) async -> Swift.Result<String, RunError>

    struct RunError: Error, Sendable {
        let message: String
        let cancelled: Bool
    }

    /// 権限不足のエラーか（EACCES / EPERM / Cocoa の書き込み権限なし）
    static func isPermissionError(_ error: Error) -> Bool {
        var e: NSError? = error as NSError
        while let ns = e {
            if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteNoPermissionError { return true }
            if ns.domain == NSPOSIXErrorDomain && (ns.code == Int(EACCES) || ns.code == Int(EPERM)) { return true }
            e = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// シェルの単一引用符で囲む（中の ' は '\'' にする）
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 操作ごとに「OK 番号」か「NG 番号」を 1 行出すシェルスクリプト（全件を 1 本にまとめる）
    static func script(for ops: [AdminOp]) -> String {
        ops.enumerated().map { command(for: $0.element, index: $0.offset) }.joined(separator: "\n") + "\nexit 0\n"
    }

    /// パスワード画面で実行する短い起動命令。
    /// 承認は「同じ命令」に限って 5 分間有効で、命令が変わるたびに聞き直される（TN2065）。
    /// そこで件数がいくら多くても、本体はファイルに書いて、この短い命令 1 本だけを実行する。
    /// 本体は root だけが触れる一時フォルダへ写してから SHA-256 を確かめ、一致したときだけ実行する
    /// （書いてから実行するまでの間に差し替えられても、実行しない）。
    static func launcher(scriptAt file: URL, sha256 hash: String) -> String {
        let f = quote(file.path)
        return """
        d=$(/usr/bin/mktemp -d /private/tmp/sabuncopy.XXXXXX) || exit 70
        if ! /bin/cp \(f) "$d/run.sh"; then /bin/rm -rf "$d"; exit 71; fi
        if [ -x /sbin/sha256sum ]; then h=$(/sbin/sha256sum "$d/run.sh" | /usr/bin/cut -c1-64); \
        else h=$(/usr/bin/shasum -a 256 "$d/run.sh" | /usr/bin/cut -c1-64); fi
        if [ "$h" != '\(hash)' ]; then /bin/rm -rf "$d"; echo 'SabunCopy: script changed' >&2; exit 72; fi
        /bin/sh "$d/run.sh"; r=$?
        /bin/rm -rf "$d"
        exit $r
        """
    }

    private static func command(for op: AdminOp, index i: Int) -> String {
        switch op.kind {
        case .directory:
            let d = quote(op.destination.path)
            return "if /bin/mkdir -p \(d); then echo 'OK \(i)'; else echo 'NG \(i)'; fi"
        case .file:
            guard let item = op.item else { return "echo 'NG \(i)'" }
            let f = quote(op.destination.path)
            let dir = op.destination.deletingLastPathComponent()
            let d = quote(dir.path)
            let t = quote(dir.appendingPathComponent(".sabun-\(UUID().uuidString).tmp").path)
            let s = quote(item.source.path)
            // ・同名のフォルダ（リンクではない）があれば何もしない
            // ・一時名にコピー（-R -P：リンクはリンクのまま、-p：日時と属性を保つ）
            // ・最終の名前がリンクなら、その先に書かないよう先にリンクだけ消す
            // ・mv で一度に置き換える。失敗したら一時ファイルを消す
            return """
            if [ -d \(f) ] && [ ! -L \(f) ]; then echo 'NG \(i)'; \
            elif /bin/mkdir -p \(d) && /bin/cp -RPp \(s) \(t); then \
            if [ -L \(f) ]; then /bin/rm -f \(f); fi; \
            if /bin/mv -f \(t) \(f); then echo 'OK \(i)'; else /bin/rm -rf \(t); echo 'NG \(i)'; fi; \
            else /bin/rm -rf \(t); echo 'NG \(i)'; fi
            """
        }
    }

    /// 出力から成功した番号を取り出す
    static func succeeded(in output: String) -> Set<Int> {
        var ok = Set<Int>()
        for line in output.components(separatedBy: .newlines) {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
            if parts.count == 2, parts[0] == "OK", let n = Int(parts[1]) { ok.insert(n) }
        }
        return ok
    }

    /// 標準の実行役：osascript で macOS のパスワード画面を出す。
    /// 命令と説明文は引数（argv）で渡すので、AppleScript の文字列に埋め込む必要がない。
    /// - 中止（Task のキャンセル）されたら osascript を終わらせ、パスワード画面も閉じる。
    /// - 終了は terminationHandler で受け、出力は別スレッドで読み切る（どちらかで止まらない）。
    static let osascript: Runner = { script, prompt in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = [
            "-e", "on run argv",
            "-e", "do shell script (item 1 of argv) with prompt (item 2 of argv) with administrator privileges",
            "-e", "end run",
            script, prompt,
        ]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let box = ProcessBox(p)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Swift.Result<String, RunError>, Never>) in
                let group = DispatchGroup()
                let collected = Collected()
                group.enter()
                p.terminationHandler = { _ in group.leave() }
                if box.terminatedByUs {   // 始める前に中止された
                    cont.resume(returning: .failure(RunError(message: "", cancelled: true)))
                    return
                }
                do { try p.run() } catch {
                    cont.resume(returning: .failure(RunError(message: error.localizedDescription, cancelled: false)))
                    return
                }
                // 書き込み側はこちらでは使わないので閉じる（読み取りが必ず終わるように）
                try? out.fileHandleForWriting.close()
                try? err.fileHandleForWriting.close()
                group.enter()
                DispatchQueue.global().async {
                    collected.set(out: out.fileHandleForReading.readDataToEndOfFile()); group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    collected.set(err: err.fileHandleForReading.readDataToEndOfFile()); group.leave()
                }
                group.notify(queue: .global()) {
                    let (o, e) = collected.strings
                    if p.terminationStatus == 0 {
                        cont.resume(returning: .success(o))
                    } else {
                        // -128 = パスワード画面でキャンセル
                        let cancelled = box.terminatedByUs || e.contains("-128")
                        cont.resume(returning: .failure(RunError(message: e.trimmingCharacters(in: .whitespacesAndNewlines),
                                                                 cancelled: cancelled)))
                    }
                }
            }
        } onCancel: {
            box.terminate()
        }
    }
}

/// 中止のときに osascript を終わらせるための入れ物
private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var stopped = false
    init(_ p: Process) { process = p }
    var terminatedByUs: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func terminate() {
        lock.lock(); stopped = true; lock.unlock()
        if process.isRunning { process.terminate() }
    }
}

/// 2 本の出力を別スレッドから受け取る入れ物
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var o = Data(), e = Data()
    func set(out d: Data) { lock.lock(); o = d; lock.unlock() }
    func set(err d: Data) { lock.lock(); e = d; lock.unlock() }
    var strings: (String, String) {
        lock.lock(); defer { lock.unlock() }
        return (String(data: o, encoding: .utf8) ?? "", String(data: e, encoding: .utf8) ?? "")
    }
}
