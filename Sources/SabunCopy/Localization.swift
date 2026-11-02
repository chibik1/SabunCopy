import Foundation

/// 表示用の文字列を Localizable.strings（日本語・英語）から引く。
/// キーは日本語の原文。翻訳は Resources/en.lproj / ja.lproj にある。
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

/// 書式つき（%@ は文字列、%ld は整数）
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), arguments: args)
}
