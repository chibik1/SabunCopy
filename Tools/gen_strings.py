#!/usr/bin/env python3
"""翻訳表から Resources/{en,ja}.lproj の .strings を生成する。

キーは日本語の原文。コードの Text("…") / L("…") などに書いた文字列と一致させる。
  python3 Tools/gen_strings.py          # .strings を生成
  python3 Tools/gen_strings.py --check  # Swift のソースに翻訳漏れがないか確認
言語を足すときは、下の表に列を足して LANGS に追加する。
"""
import re, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent

# 日本語（キー） -> 英語
EN = {
 # 動作・比較
 "コピー": "Copy", "移動": "Move",
 "更新日時": "Date", "サイズ": "Size",
 "新しい": "Newer", "古い": "Older", "大きい": "Larger", "小さい": "Smaller",
 "残す": "Keep",
 "確認": "Ask", "上書き": "Overwrite", "スキップ": "Skip", "両方残す": "Keep both",
 "比較": "Compare", "処理": "Action",
 # 状態
 "新規": "New", "同一": "Same", "エラー": "Error", "すべて": "All", "上書き・確認": "Overwrite / Ask",
 # メイン画面
 "設定": "Settings",
 "コピー元": "Source", "コピー元をドロップ": "Drop source here",
 "コピーするファイル・フォルダを選択": "Choose files or folders to copy",
 "追加…": "Add…", "クリア": "Clear",
 "コピー先": "Destination", "コピー先のフォルダをドロップ": "Drop destination folder here",
 "コピー先のフォルダを選択": "Choose the destination folder",
 "フォルダを選ぶ…": "Choose folder…",
 "お気に入り": "Favorites", "お気に入りに追加": "Add to favorites", "お気に入りから外す": "Remove from favorites",
 "（まだありません。★で追加できます）": "(None yet. Add with ★)",
 "最近使ったフォルダ": "Recent folders", "（履歴はありません）": "(No history)",
 "最近の履歴を消去": "Clear recents", "最近・お気に入り": "Recents and favorites",
 "コピー、または移動（照合したあと、移動元をゴミ箱へ入れます）": "Copy, or move (verifies, then puts the source in the Trash)",
 "同名ファイルを比べる基準。空欄（—）なら比べず、右の「処理」で扱いを決めます。同じ値のときはスキップします":
   "What to compare when a file with the same name exists. Leave it blank (—) to skip comparing and decide with “Action” on the right. Equal values are skipped.",
 "どちらを残すか": "Which one to keep",
 "同名ファイルがあったときの扱い": "What to do when a file with the same name exists",
 "比較で選んだほうを残します": "Keeps the one chosen by “Compare”",
 "ハッシュ照合": "Verify with hash",
 "コピー後にSHA-256で内容が一致するかを確かめます。移動のときは常にオンです":
   "After copying, checks with SHA-256 that the contents match. Always on for Move.",
 "最前面に固定": "Keep on top",
 "ウインドウを他のウインドウより常に前に表示します": "Keeps the window in front of other windows.",
 "処理後に閉じる": "Close when done",
 "すべて終わったらウインドウを閉じます。エラーや中止のときは閉じません。閉じるとアプリも終了します":
   "Closes the window when everything is done (not on errors or cancel). Closing the window quits the app.",
 "中止": "Stop", "差分を確認": "Preview changes",
 "移動開始": "Start moving", "コピー開始": "Start copying",
 "差分を解析中… %ld / %ld": "Analyzing… %ld / %ld",
 # 差分の確認
 "差分の確認": "Preview Changes", "%ld ファイル": "%ld files", "閉じる": "Close",
 "この内容で移動開始": "Move with these settings", "この内容でコピー開始": "Copy with these settings",
 # 競合ダイアログ
 "同じ名前のファイルがあります": "A file with the same name exists",
 "コピー先（既存）": "Destination (existing)",
 "サイズと更新日時が同じです（同一ファイルの可能性が高い）": "Size and date are the same (probably the same file)",
 "以降の競合すべてに同じ処理を適用": "Apply to all remaining conflicts",
 "新しいほうだけ上書き": "Overwrite if newer",
 # エラー
 "「%@」はコピー元とコピー先が同じ場所です": "“%@” has the same source and destination.",
 "「%@」の中にはコピーできません（コピー先がコピー元の内側です）":
   "Can’t copy “%@” into itself (the destination is inside the source).",
 "コピー先に同名のフォルダがあるためコピーできません": "Can’t copy: a folder with the same name exists at the destination",
 "同名のファイルがあるためフォルダを作成できません": "Can’t create the folder: a file with the same name exists",
 "照合に失敗しました（コピー元とコピー先の内容が一致しません）":
   "Verification failed (source and destination contents don’t match)",
 "コピーは完了しましたが、移動元をゴミ箱へ移せませんでした（%@）": "Copied, but couldn’t move the source to Trash (%@)",
 "差分を確認できませんでした: %@": "Couldn’t check differences: %@",
 "開始できませんでした: %@": "Couldn’t start: %@",
 "フォルダを作成できません: %@ — %@": "Couldn’t create folder: %@ — %@",
 # ログ
 "%@：%ld ファイル（%@）": "%@: %ld files (%@)",
 "空になったフォルダをゴミ箱へ: %@": "Moved emptied folder to Trash: %@",
 "コピー: %@": "Copied: %@", "移動: %@": "Moved: %@",
 "同一のためスキップし、移動元をゴミ箱へ: %@": "Identical; skipped and moved source to Trash: %@",
 "スキップ（比較では同一でも内容が異なるため移動元を残しました）: %@":
   "Skipped (same by comparison, but contents differ; source kept): %@",
 "同一のためスキップ: %@": "Identical; skipped: %@",
 "スキップ: %@": "Skipped: %@",
 "スキップ（移動元は残します）: %@": "Skipped (source kept): %@",
 "スキップ（コピー先を残す）: %@": "Skipped (kept destination): %@",
 "スキップ（コピー先を残す・移動元は残します）: %@": "Skipped (kept destination and source): %@",
 "上書き（コピー元が新しい）: %@": "Overwritten (source is newer): %@",
 "スキップ（コピー先が同じか新しい）: %@": "Skipped (destination is the same or newer): %@",
 "スキップ（コピー先が同じか新しい・移動元は残します）: %@":
   "Skipped (destination is the same or newer; source kept): %@",
 "上書き: %@": "Overwritten: %@", "上書き（%@）: %@": "Overwritten (%@): %@",
 "別名で保存: %@ → %@": "Saved as copy: %@ → %@",
 "更新日時が新しいほうを残す": "keep newer by date", "更新日時が古いほうを残す": "keep older by date",
 "サイズが大きいほうを残す": "keep larger by size", "サイズが小さいほうを残す": "keep smaller by size",
 # 結果の要約
 "新規コピー %ld": "Copied %ld", "新規移動 %ld": "Moved %ld", "上書き %ld": "Overwritten %ld",
 "別名保存 %ld": "Saved as copy %ld", "スキップ %ld": "Skipped %ld", "失敗 %ld": "Failed %ld",
 "移動元をゴミ箱へ %ld": "Sources to Trash %ld", "空フォルダ整理 %ld": "Emptied folders %ld",
 "処理したファイルはありません": "No files processed",
 "中止しました。 %@": "Cancelled. %@", "完了しました。 %@": "Done. %@",
}

# Finder の右クリック（サービス）の名前。キーは Info.plist の NSMenuItem default。
SERVICES = {
 "SabunCopy: Add as Source": {"en": "SabunCopy: Add as Source", "ja": "SabunCopy：コピー元に追加"},
 "SabunCopy: Set as Destination": {"en": "SabunCopy: Set as Destination", "ja": "SabunCopy：コピー先にする"},
}

LANGS = ["en", "ja"]


def esc(s):
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def write(path, entries, header):
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = [f"/* {header} */"]
    for k, v in entries:
        lines.append(f'"{esc(k)}" = "{esc(v)}";')
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def generate():
    for lang in LANGS:
        base = ROOT / "Resources" / f"{lang}.lproj"
        table = EN if lang == "en" else {k: k for k in EN}   # 日本語はキーそのまま
        write(base / "Localizable.strings", sorted(table.items()), "UI strings (key = Japanese source)")
        write(base / "InfoPlist.strings",
              [("CFBundleName", "SabunCopy"), ("CFBundleDisplayName", "SabunCopy")], "App name")
        write(base / "ServicesMenu.strings",
              [(k, v[lang]) for k, v in SERVICES.items()], "Finder services")
    print("generated:", ", ".join(f"{l}.lproj" for l in LANGS), f"({len(EN)} strings)")


CJK = re.compile(r"[\u3040-\u30ff\u4e00-\u9fff\uff00-\uffef]")
LITERAL = re.compile(r'"((?:[^"\\]|\\.)*)"')


def check():
    missing, interpolated = [], []
    for path in sorted((ROOT / "Sources").rglob("*.swift")):
        for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            code = line.split("//")[0] if "//" in line and '"' not in line.split("//")[0][-1:] else line
            for m in LITERAL.finditer(code):
                text = m.group(1)
                if not CJK.search(text):
                    continue
                if "\\(" in text:
                    interpolated.append((path.name, n, text))
                elif text not in EN and text not in ("確認",):
                    missing.append((path.name, n, text))
    for f, n, t in interpolated:
        print(f"  補間つきの日本語リテラル（L() の書式にする）: {f}:{n}: {t}")
    for f, n, t in missing:
        print(f"  翻訳がありません: {f}:{n}: {t}")
    print("OK: 翻訳もれなし" if not (missing or interpolated) else f"{len(missing)+len(interpolated)} 件")
    return not (missing or interpolated)


if __name__ == "__main__":
    if "--check" in sys.argv:
        sys.exit(0 if check() else 1)
    generate()
