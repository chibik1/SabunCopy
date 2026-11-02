import SwiftUI
import AppKit

// Valyn デザインシステム（design/design-system/tokens.json）の Swift 版。
// ダークのみ。数値はモック（design/mockup/*.dc.html）に合わせてある。

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: 1)
    }
}

enum V {
    // Color
    static let ground = Color(hex: 0x080c06)     // surface-ground
    static let row = Color(hex: 0x11150f)        // surface-row
    static let chip = Color(hex: 0x1b211a)       // surface-chip
    static let blue = Color(hex: 0x4079bc)       // brand-blue
    static let blueTint = Color(hex: 0x6a99cc)   // brand-blue-tint
    static let onBrand = Color(hex: 0xffffff)
    static let barMuted = Color(hex: 0x383836)
    static let text = Color(hex: 0xffffff)       // text-primary
    static let muted = Color(hex: 0x9ea19b)      // text-muted
    static let light = Color(hex: 0xffffff)      // button-light
    /// Valyn に定義が無いので、エラー表示だけに使う控えめな赤
    static let danger = Color(hex: 0xff6e70)

    // Radius
    static let rSm: CGFloat = 8
    static let rMd: CGFloat = 12
    static let rLg: CGFloat = 18

    // Space
    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s5: CGFloat = 24
}

enum VFont {
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    static func mono(_ size: CGFloat) -> Font {
        .system(size: size, design: .monospaced)
    }
}

// MARK: - Buttons

/// エンボスのボタン（emboss-blue / emboss-chip）。押すと 1px 下がる。
struct VEmbossStyle: ButtonStyle {
    enum Kind { case blue, chip }

    let kind: Kind
    var radius: CGFloat = V.rMd

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let highlight: Double = kind == .blue ? 0.30 : 0.14
        let shade: Double = kind == .blue ? 0.30 : 0.40

        return configuration.label
            .background(shape.fill(kind == .blue ? V.blue : V.chip))
            .overlay(
                VStack(spacing: 0) {
                    Rectangle().fill(Color.white.opacity(highlight)).frame(height: 1)
                    Spacer(minLength: 0)
                    Rectangle().fill(Color.black.opacity(shade)).frame(height: 2)
                }
                .clipShape(shape)
                .allowsHitTesting(false)
            )
            .shadow(color: Color.black.opacity(0.4), radius: 2, x: 0, y: 2)
            .offset(y: configuration.isPressed ? 1 : 0)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(shape)
    }
}

/// 小さな四角いボタン（surface-chip・影なし）
struct VChipStyle: ButtonStyle {
    var width: CGFloat = 28
    var height: CGFloat = 28
    var radius: CGFloat = V.rSm

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return configuration.label
            .frame(width: width, height: height)
            .background(shape.fill(V.chip))
            .overlay(shape.fill(Color.white.opacity(configuration.isPressed ? 0.08 : 0)))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(shape)
    }
}

/// シートのボタン（surface-chip または brand-blue・高さ 34）
struct VSheetButtonStyle: ButtonStyle {
    var primary = false

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: V.rSm, style: .continuous)
        return configuration.label
            .font(VFont.ui(primary ? 14 : 13, .medium))
            .foregroundColor(primary ? V.onBrand : V.text)
            .padding(.horizontal, primary ? 18 : 14)
            .frame(height: 34)
            .background(shape.fill(primary ? V.blue : V.chip))
            .overlay(shape.fill(Color.white.opacity(configuration.isPressed ? 0.10 : 0)))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(shape)
    }
}

// MARK: - Select（ポップアップ）

struct VSelect<T: Hashable>: View {
    let options: [T]
    @Binding var selection: T
    let label: (T) -> String
    /// 幅の基準にする文字列。省略すると選択肢の表示名。
    /// いちばん長いものが収まる幅に固定する（言語が変わっても、選んでも、幅は動かない）。
    var measure: [String]? = nil

    private var fixedWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let strings = measure ?? options.map(label)
        let widest = strings
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        return ceil(widest) + 34   // 左10 + 右8 + 矢印10 + 間6
    }

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        // macOS の Menu は独自のラベルを崩すので、見た目は自前で描き、
        // その上に透明な Menu を重ねてクリックを受ける
        HStack(spacing: 6) {
            Text(label(selection))
                .font(VFont.ui(13, .medium))
                .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .bold))
        }
        .foregroundColor(isEnabled ? V.text : V.muted)
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(width: fixedWidth, height: 30)
        .background(RoundedRectangle(cornerRadius: V.rSm, style: .continuous).fill(V.chip))
        .overlay(
            Menu {
                ForEach(options, id: \.self) { option in
                    Button {
                        selection = option
                    } label: {
                        if option == selection {
                            Label(label(option), systemImage: "checkmark")
                        } else {
                            Text(label(option))
                        }
                    }
                }
            } label: {
                Color.clear
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .opacity(0.011)
        )
        .fixedSize()
    }
}

// MARK: - Slide toggle（コピー／移動）

/// brand-blue のトラックの上を、白いつまみが約 0.22 秒でスライドする。
struct VSlideToggle: View {
    @Binding var selection: OperationMode

    private let width: CGFloat = 156
    private let height: CGFloat = 44
    private let inset: CGFloat = 4

    private var segment: CGFloat { (width - inset * 2) / 2 }

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(V.blue)

            Capsule()
                .fill(V.light)
                .overlay(
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Rectangle().fill(Color(hex: 0x080c06).opacity(0.2)).frame(height: 2)
                    }
                    .clipShape(Capsule())
                    .allowsHitTesting(false)
                )
                .shadow(color: Color.black.opacity(0.4), radius: 1.5, x: 0, y: 1)
                .frame(width: segment, height: height - inset * 2)
                .offset(x: inset + (selection == .copy ? 0 : segment))
                .animation(.timingCurve(0.3, 0.7, 0.2, 1, duration: 0.22), value: selection)

            HStack(spacing: 0) {
                ForEach(OperationMode.allCases) { mode in
                    Button {
                        selection = mode
                    } label: {
                        Text(mode.label)
                            .font(VFont.ui(14, .bold))
                            .foregroundColor(selection == mode ? V.ground : V.onBrand)
                            .frame(width: segment, height: height - inset * 2)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == mode ? .isSelected : [])
                }
            }
            .padding(.horizontal, inset)
        }
        .frame(width: width, height: height)
    }
}

// MARK: - Pill segmented（差分の確認の絞り込み）

struct VPillSegmented<T: Hashable>: View {
    let options: [T]
    @Binding var selection: T
    let label: (T) -> String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button {
                    selection = option
                } label: {
                    Text(label(option))
                        .font(VFont.ui(13, selected ? .bold : .medium))
                        .foregroundColor(selected ? V.onBrand : V.text)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .background(Capsule().fill(selected ? V.blue : Color.clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .frame(height: 30)
        .background(Capsule().fill(V.chip))
    }
}

// MARK: - Checkbox

struct VCheckStyle: ToggleStyle {
    /// true = 四角を左（シートの表記）、false = 右（歯車のポップアップ）
    var boxLeading = false

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let box = ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(configuration.isOn ? V.blue : V.chip)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(configuration.isOn ? V.blue : V.barMuted, lineWidth: 1.5)
            if configuration.isOn {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(V.onBrand)
            }
        }
        .frame(width: 16, height: 16)

        return Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                if boxLeading { box }
                configuration.label
                    .font(VFont.ui(13))
                    .foregroundColor(V.text)
                if !boxLeading {
                    Spacer(minLength: 8)
                    box
                }
                if boxLeading { Spacer(minLength: 0) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}

// MARK: - Misc

/// 進捗バー（高さ 6）
struct VProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(V.chip)
                Capsule()
                    .fill(V.blue)
                    .frame(width: geo.size.width * CGFloat(max(0, min(1, fraction))))
            }
        }
        .frame(height: 6)
    }
}

/// 状態チップ（アイコン＋言葉）
struct VPill: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 12))
            Text(text).font(VFont.ui(11, .medium))
        }
        .foregroundColor(V.text)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(V.chip))
    }
}

/// シートの外枠（surface-ground）
struct VSheet<Content: View>: View {
    let width: CGFloat
    var height: CGFloat?
    var padding: CGFloat = 20
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(width: width, height: height, alignment: .topLeading)
            .background(V.ground)
            .foregroundColor(V.text)
    }
}

/// ウインドウのタイトルバーを surface-ground に溶け込ませる
struct VWindowStyler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { StylerView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class StylerView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window = window else { return }
            // ダーク外観にして、タイトルとツールバーの文字・アイコンを白にする
            window.appearance = NSAppearance(named: .darkAqua)
            window.titlebarAppearsTransparent = true
            window.backgroundColor = NSColor(srgbRed: 8.0 / 255, green: 12.0 / 255, blue: 6.0 / 255, alpha: 1)
            // 大きさは固定（最小サイズのまま）
            window.styleMask.remove(.resizable)
            window.standardWindowButton(.zoomButton)?.isEnabled = false
        }
    }
}
