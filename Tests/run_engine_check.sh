#!/bin/bash
# CopyEngine の動作確認を実行します（実ファイルを一時フォルダで使用）
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="$(mktemp -d)/engine_check"
swiftc -O Sources/SabunCopy/CopyEngine.swift Tests/EngineCheck/main.swift -o "$OUT"
"$OUT"
status=$?

# 後始末：一時フォルダと、移動テストでゴミ箱に入ったテスト用ファイル
rm -rf "${TMPDIR:-/tmp}"/sabun-test-* 2>/dev/null || true
rm -f "$HOME"/.Trash/sabuntest_* 2>/dev/null || true
exit $status
