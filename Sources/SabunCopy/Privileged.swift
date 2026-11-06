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
/// - 命令の長さは約 262,000 バイトまで（kern.argmax）。超える分は分けて実行する。
/// - サンドボックスのアプリでは動かない（SabunCopy はサンドボックス外）。
enum Privileged {
    /// 実行役。テストでは普通のシェルに差し替える。
    /// 戻り値：標準出力（成功時）またはエラー文（失敗・キャンセル時）
    typealias Runner = @Sendable (_ script: String, _ prompt: String) async -> Swift.Result<String, RunError>

    struct RunError: Error, Sendable {
        let message: String
        let cancelled: Bool
    }

    /// 1 回に渡す命令の上限（仕様の 262,144 バイトに余裕を持たせる）
    static let chunkLimit = 200_000

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

    /// 操作ごとに「OK 番号」か「NG 番号」を 1 行出すシェルスクリプトを作る（上限ごとに分ける）
    static func scripts(for ops: [AdminOp]) -> [(script: String, indices: [Int])] {
        var chunks: [(String, [Int])] = []
        var current = ""
        var indices: [Int] = []
        for (i, op) in ops.enumerated() {
            let line = command(for: op, index: i) + "\n"
            if !current.isEmpty && current.utf8.count + line.utf8.count > chunkLimit {
                chunks.append((current + "exit 0\n", indices))
                current = ""
                indices = []
            }
            current += line
            indices.append(i)
        }
        if !current.isEmpty { chunks.append((current + "exit 0\n", indices)) }
        return chunks
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
    static let osascript: Runner = { script, prompt in
        await withCheckedContinuation { cont in
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
            do { try p.run() } catch {
                cont.resume(returning: .failure(RunError(message: error.localizedDescription, cancelled: false)))
                return
            }
            // 出力が多くてもパイプが詰まらないよう、終わるのを待つ前に読み切る
            DispatchQueue.global().async {
                let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                p.waitUntilExit()
                if p.terminationStatus == 0 {
                    cont.resume(returning: .success(o))
                } else {
                    // -128 = ユーザがキャンセル
                    cont.resume(returning: .failure(RunError(message: e.trimmingCharacters(in: .whitespacesAndNewlines),
                                                             cancelled: e.contains("-128"))))
                }
            }
        }
    }
}
