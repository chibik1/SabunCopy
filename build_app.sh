#!/bin/bash
# SabunCopy.app をビルドします（Xcode または Command Line Tools が必要）
#   ./build_app.sh            ビルドだけ
#   ./build_app.sh --install  ビルド後に ~/Applications へ入れ、Finder の右クリック(サービス)を登録
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)"

APP="SabunCopy.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/SabunCopy" "$APP/Contents/MacOS/SabunCopy"
cp Info.plist "$APP/Contents/Info.plist"
# 多言語（日本語・英語）の文字列
cp -R Resources/*.lproj "$APP/Contents/Resources/"
codesign --force --deep --sign - "$APP"

echo "できました: $(pwd)/$APP"

if [[ "${1:-}" == "--install" ]]; then
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/$APP"
    cp -R "$APP" "$HOME/Applications/$APP"
    /System/Library/CoreServices/pbs -update || true
    echo "インストールしました: $HOME/Applications/$APP"
    echo "Finderの右クリック → サービス（または クイックアクション）に「SabunCopy」が出ます。"
    echo "出ない場合: システム設定 → キーボード → キーボードショートカット → サービス → ファイルおよびフォルダ で有効にしてください。"
fi
