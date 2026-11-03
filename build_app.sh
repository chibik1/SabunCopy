#!/bin/bash
# SabunCopy.app をビルドします（Xcode または Command Line Tools が必要）
#   ./build_app.sh            ビルドだけ
#   ./build_app.sh --install  ビルド後に ~/Applications へ入れ、Finder の右クリック(サービス)を登録
set -euo pipefail
cd "$(dirname "$0")"

# 消してよいのは SabunCopy 自身の .app だけ（同じ名前の別のものは消さずに止める）
safe_remove_app() {
    local path="$1"
    [[ -e "$path" ]] || return 0
    local id
    id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$path/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$id" != "local.sabuncopy" ]]; then
        echo "中止: $path は SabunCopy.app ではないようなので、消さずに止めます。" >&2
        exit 1
    fi
    rm -rf "$path"
}

swift build -c release
BIN="$(swift build -c release --show-bin-path)"

APP="SabunCopy.app"
safe_remove_app "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/SabunCopy" "$APP/Contents/MacOS/SabunCopy"
cp Info.plist "$APP/Contents/Info.plist"
# アプリアイコン
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# 多言語（日本語・英語）の文字列
cp -R Resources/*.lproj "$APP/Contents/Resources/"
codesign --force --deep --sign - "$APP"

echo "できました: $(pwd)/$APP"

if [[ "${1:-}" == "--install" ]]; then
    mkdir -p "$HOME/Applications"
    safe_remove_app "$HOME/Applications/$APP"
    cp -R "$APP" "$HOME/Applications/$APP"
    /System/Library/CoreServices/pbs -update || true
    echo "インストールしました: $HOME/Applications/$APP"
    echo "Finderの右クリック → サービス（または クイックアクション）に「SabunCopy」が出ます。"
    echo "出ない場合: システム設定 → キーボード → キーボードショートカット → サービス → ファイルおよびフォルダ で有効にしてください。"
fi
