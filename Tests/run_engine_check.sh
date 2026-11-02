#!/bin/bash
# CopyEngine の動作確認を実行します（実ファイルを一時フォルダで使用）
set -euo pipefail
cd "$(dirname "$0")/.."

OUTDIR="$(mktemp -d)"
OUT="$OUTDIR/engine_check"
# 実行ごとの ID。後片付けはこの ID を含むものだけを消す（他の実行や利用者のファイルには触れない）
export SABUN_TEST_ID="$(uuidgen | tr -d - | cut -c1-12)"
TESTDIR="${TMPDIR:-/tmp}/sabun-test-$SABUN_TEST_ID"

cleanup() {
    chmod -R u+rwx "$TESTDIR" 2>/dev/null || true   # 権限を落としたテスト用フォルダも消せるように
    rm -rf "$TESTDIR" "$OUTDIR"
    # 移動テストでゴミ箱に入った、この実行のテスト用ファイルだけ
    rm -f "$HOME"/.Trash/sabuntest_"$SABUN_TEST_ID"_* 2>/dev/null || true
}
trap cleanup EXIT

swiftc -O Sources/SabunCopy/CopyEngine.swift Sources/SabunCopy/Localization.swift Tests/EngineCheck/main.swift -o "$OUT"
"$OUT"
