import SwiftUI
import AppKit

// 自作 Mac アプリ共通のデザインシステム「Mac Apps」(tokens.json v1) の Swift 版。
// 値の出どころは Figma の macOS 27 キット。文字 4.5:1・操作部品の縁 3:1 を満たすよう
// 一部だけ明るさを調整してある（理由は Mac Apps の README を参照）。

// MARK: - Color helpers

private extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                  green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255,
                  alpha: alpha)
    }
}

/// Dark / Light をウインドウの外観に合わせて切り替える色
private func themed(_ dark: UInt32, _ light: UInt32, alpha: CGFloat = 1) -> Color {
    Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return NSColor(hex: isDark ? dark : light, alpha: alpha)
    }))
}

// MARK: - Tokens

enum DS {
    /// 既定は Dark。nil にするとシステムの外観に従う。
    static let defaultAppearance: NSAppearance? = NSAppearance(named: .darkAqua)

    // Surface
    static let window = themed(0x1e1e1e, 0xffffff)         // surface-window
    static let panel = themed(0x292929, 0xf7f7f7)          // surface-panel
    static let raised = themed(0x343434, 0xffffff)         // surface-raised
    static let field = themed(0x181818, 0xf2f2f2)          // surface-field

    // Ink / line
    static let ink = themed(0xdddddd, 0x262626)
    static let inkMuted = themed(0x9d9d9d, 0x6e6e6e)
    static let divider = themed(0x343434, 0xe6e6e6)
    static let borderControl = themed(0x7e7e7e, 0x8a8a8a)

    // Accent
    static let accent = themed(0x27a2ff, 0x0165e2)
    static let onAccent = themed(0x000000, 0xffffff)
    static let focusRing = themed(0x5cb3ff, 0x0165e2)

    // Table
    static let rowAlt = themed(0xffffff, 0x000000, alpha: 0.05) // mac-row-alt

    // Status（必ずアイコンと言葉を添える）
    static let statusNew = themed(0x30d158, 0x217e38)
    static let statusNewer = themed(0xff9230, 0xb15300)
    static let statusDanger = themed(0xff6e70, 0xde0004)
    static let statusDiffer = themed(0xe56af5, 0xb81fcd)
    static let statusSame = themed(0x9d9d9d, 0x6e6e6e)

    // Spacing
    static let space1: CGFloat = 4
    static let space2: CGFloat = 8
    static let space3: CGFloat = 12
    static let space4: CGFloat = 16
    static let space5: CGFloat = 20
    static let space6: CGFloat = 24

    // Radius
    static let radiusSm: CGFloat = 4
    static let radiusMd: CGFloat = 6
    static let radiusLg: CGFloat = 12
    static let radiusCheckbox: CGFloat = 4

    // Control size
    static let controlHeightSmall: CGFloat = 20
    static let controlHeight: CGFloat = 24          // medium
    static let controlHeightLarge: CGFloat = 28
    static let buttonPadX: CGFloat = 16
}

enum DSFont {
    static let title = Font.system(size: 15, weight: .semibold)
    static let headline = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 13)
    static let callout = Font.system(size: 12)
    static let caption = Font.system(size: 11)
    static let monoBody = Font.system(size: 13, design: .monospaced)
    static let monoCaption = Font.system(size: 11, design: .monospaced)
}

// MARK: - Button

struct DSButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, danger }

    let kind: Kind
    var large = false

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let height = large ? DS.controlHeightLarge : DS.controlHeight
        let radius = large ? height / 2 : DS.radiusSm   // Large 以上はカプセル形
        let shape = RoundedRectangle(cornerRadius: radius)

        return configuration.label
            .font(DSFont.body)
            .foregroundColor(foreground)
            .padding(.horizontal, DS.buttonPadX)
            .frame(minHeight: height)
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(stroke, lineWidth: kind == .primary ? 0 : 1))
            .overlay(shape.fill(Color.white.opacity(configuration.isPressed ? 0.10 : 0)))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(shape)
    }

    private var foreground: Color {
        switch kind {
        case .primary: return DS.onAccent
        case .secondary: return DS.ink
        case .danger: return DS.statusDanger
        }
    }

    private var fill: Color {
        kind == .primary ? DS.accent : DS.raised
    }

    private var stroke: Color {
        switch kind {
        case .primary: return .clear
        case .secondary: return DS.borderControl
        case .danger: return DS.statusDanger
        }
    }
}

// MARK: - Checkbox

struct DSCheckboxStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: DS.space2) {
                ZStack {
                    RoundedRectangle(cornerRadius: DS.radiusCheckbox)
                        .fill(configuration.isOn ? DS.accent : DS.field)
                    RoundedRectangle(cornerRadius: DS.radiusCheckbox)
                        .strokeBorder(configuration.isOn ? DS.accent : DS.borderControl, lineWidth: 1.5)
                    if configuration.isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(DS.onAccent)
                    }
                }
                .frame(width: 16, height: 16)

                configuration.label
                    .font(DSFont.body)
                    .foregroundColor(DS.ink)
            }
            .frame(minHeight: DS.controlHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}

// MARK: - Segmented control

struct DSSegmented<T: Hashable & Identifiable>: View {
    let options: [T]
    @Binding var selection: T
    let label: (T) -> String

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                let selected = option == selection
                Button {
                    selection = option
                } label: {
                    Text(label(option))
                        .font(DSFont.body)
                        .foregroundColor(selected ? DS.onAccent : DS.ink)
                        .padding(.horizontal, DS.space3)
                        .frame(minWidth: 60, minHeight: DS.controlHeight)
                        .background(selected ? DS.accent : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .background(DS.raised)
        .clipShape(RoundedRectangle(cornerRadius: DS.radiusSm))
        .overlay(RoundedRectangle(cornerRadius: DS.radiusSm).strokeBorder(DS.borderControl, lineWidth: 1))
        .fixedSize()
        .opacity(isEnabled ? 1 : 0.4)
    }
}

// MARK: - Pop-up menu

/// ポップアップ風のラベル（メニューのラベルとして使う）
struct DSMenuLabel: View {
    let text: String
    var width: CGFloat?

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: DS.space1) {
            Text(text)
                .font(DSFont.body)
                .foregroundColor(DS.ink)
                .lineLimit(1)
            if width != nil { Spacer(minLength: DS.space1) }
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(DS.inkMuted)
        }
        .padding(.horizontal, DS.space2)
        .frame(width: width, height: DS.controlHeight)
        .background(DS.raised)
        .clipShape(RoundedRectangle(cornerRadius: DS.radiusMd))
        .overlay(RoundedRectangle(cornerRadius: DS.radiusMd).strokeBorder(DS.borderControl, lineWidth: 1))
        .opacity(isEnabled ? 1 : 0.4)
    }
}

struct DSPopUp<T: Hashable & Identifiable>: View {
    let options: [T]
    @Binding var selection: T
    var width: CGFloat = 200
    let label: (T) -> String

    var body: some View {
        Menu {
            ForEach(options) { option in
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
            DSMenuLabel(text: label(selection), width: width)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: - Pane / drop zone / chip

/// グループ（surface-panel）。タイトルは headline。
struct DSPane<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.space2) {
            Text(title)
                .font(DSFont.headline)
                .foregroundColor(DS.ink)
            content()
        }
        .padding(DS.space2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.radiusMd).fill(DS.panel))
    }
}

/// 凹んだ領域（surface-field）。空のときは破線、ドラッグ中は accent の実線。
struct DSDropZone<Content: View>: View {
    let isTargeted: Bool
    let isEmpty: Bool
    let height: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.radiusMd)
        ZStack {
            shape.fill(DS.field)
            shape.strokeBorder(
                isTargeted ? DS.accent : DS.borderControl,
                style: StrokeStyle(lineWidth: 1.5, dash: (isEmpty && !isTargeted) ? [6] : [])
            )
            content()
        }
        .frame(height: height)
    }
}

/// 状態チップ（アイコン＋言葉＋色）
struct DSChip: View {
    let icon: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: DS.space1) {
            Image(systemName: icon)
            Text(text)
        }
        .font(DSFont.caption)
        .foregroundColor(color)
        .padding(.horizontal, DS.space2)
        .frame(height: DS.controlHeightSmall)
        .background(Capsule().fill(DS.field))
    }
}

/// 凹んだ一覧（ログ・差分行）の入れ物
struct DSWell<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .background(RoundedRectangle(cornerRadius: DS.radiusMd).fill(DS.field))
            .clipShape(RoundedRectangle(cornerRadius: DS.radiusMd))
    }
}

/// シートの外枠（surface-raised・余白 space-5）
struct DSSheet<Content: View>: View {
    let width: CGFloat
    var height: CGFloat?
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(DS.space5)
            .frame(width: width, height: height)
            .background(DS.raised)
            .foregroundColor(DS.ink)
    }
}
