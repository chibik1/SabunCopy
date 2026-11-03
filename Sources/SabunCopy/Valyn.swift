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

/// ダーク／ライトで色が切り替わる動的な色
enum VNS {
    private static func ns(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
    static func dyn(_ dark: UInt32, _ light: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua ? ns(light) : ns(dark)
        }
    }
    /// アクセントカラーに白／黒を少し混ぜた色（グラデーション・淡い青用）
    static func accent(mix: NSColor, _ fraction: CGFloat) -> NSColor {
        NSColor(name: nil) { _ in
            NSColor.controlAccentColor.blended(withFraction: fraction, of: mix) ?? NSColor.controlAccentColor
        }
    }
    /// すりガラスのとき、行やチップも少し透かす（alpha = 1 - k × 透明度）
    static func dynGlass(_ dark: UInt32, _ light: UInt32, k: Double) -> NSColor {
        NSColor(name: nil) { appearance in
            let base = appearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua ? ns(light) : ns(dark)
            return base.withAlphaComponent(CGFloat(1 - k * CopyModel.shared.glass))
        }
    }
    /// ライトでも、すりガラスが一定以上のときは文字を白にする（暗めのガラスに白文字）
    static let lightGlassOn = 0.3
    static func inkAdaptive(dark: UInt32, light: UInt32, whiteAlpha: CGFloat, darkAlpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua {
                if CopyModel.shared.glass > lightGlassOn { return NSColor.white.withAlphaComponent(whiteAlpha) }
                return ns(light)
            }
            return darkAlpha < 1 ? NSColor.white.withAlphaComponent(darkAlpha) : ns(dark)
        }
    }
    static let ground = dyn(0x121519, 0xe9edf2)
}

enum V {
    // Color（左がダーク、右がライト）
    static let ground = Color(nsColor: VNS.ground)     // surface-ground
    static let row = Color(nsColor: VNS.dynGlass(0x1b1f25, 0xf7f9fb, k: 0.85))        // surface-row
    static let chip = Color(nsColor: VNS.dynGlass(0x262b32, 0xdce2ea, k: 0.8))       // surface-chip
    /// OS 標準のアクセントカラー（チェックボックスなどと同じ青。システム設定で変えた色にも従う）
    static let blue = Color(nsColor: .controlAccentColor)
    /// 青いパーツ共通のごく薄いグラデーション（上がわずかに明るい）
    static let blueFill = LinearGradient(
        colors: [Color(nsColor: VNS.accent(mix: .white, 0.10)), Color(nsColor: VNS.accent(mix: .black, 0.08))],
        startPoint: .top, endPoint: .bottom)
    static let blueTint = Color(nsColor: VNS.accent(mix: .white, 0.30))   // brand-blue-tint
    static let onBrand = Color(hex: 0xffffff)
    static let barMuted = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .aqua ? NSColor(srgbRed: 0.72, green: 0.75, blue: 0.79, alpha: 1)
                                                      : NSColor.white.withAlphaComponent(0.5)
    })
    static let text = Color(nsColor: VNS.inkAdaptive(dark: 0xffffff, light: 0x1b2027, whiteAlpha: 1))       // text-primary
    static let muted = Color(nsColor: VNS.inkAdaptive(dark: 0x9ea19b, light: 0x5b6470, whiteAlpha: 0.8, darkAlpha: 0.8))      // text-muted
    static let light = Color(hex: 0xffffff)      // button-light
    /// スライドトグルのつまみ。真っ白よりひと段やわらかい白
    static let thumb = Color(nsColor: VNS.dyn(0xe4e9f0, 0xffffff))
    /// つまみの上の文字（どちらのテーマでも濃い色）
    static let thumbInk = Color(hex: 0x121519)
    /// 押したときに重ねる色（ダークは白、ライトは黒）
    static let press = Color(nsColor: VNS.dyn(0xffffff, 0x000000))
    /// Valyn に定義が無いので、エラー表示だけに使う控えめな赤
    static let danger = Color(nsColor: VNS.dyn(0xff6e70, 0xd62f3b))

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
            .background(shape.fill(kind == .blue ? AnyShapeStyle(V.blueFill) : AnyShapeStyle(V.chip)))
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
            .overlay(shape.fill(V.press.opacity(configuration.isPressed ? 0.08 : 0)))
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
            .background(shape.fill(primary ? AnyShapeStyle(V.blueFill) : AnyShapeStyle(V.chip)))
            .overlay(shape.fill(V.press.opacity(configuration.isPressed ? 0.10 : 0)))
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
        return ceil(widest) + 38   // 左10 + 右8 + 文字と矢印の間6 + 矢印10 + ゆとり4
    }

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        // macOS の Menu は独自のラベルを崩すので、見た目は自前で描き、
        // その上に透明な Menu を重ねてクリックを受ける
        HStack(spacing: 0) {
            Text(label(selection))
                .font(VFont.ui(13, .medium))
                .lineLimit(1)
                .fixedSize()
                .padding(.trailing, 6)
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
            VMenuTrigger(entries: {
                options.map { option in
                    VMenuEntry.item(label(option), checked: option == selection) {
                        selection = option
                    }
                }
            })
        )
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label(selection))
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Menu（NSMenu を直接開く）

/// メニューの 1 項目（階層・見出し・区切りも表せる）
struct VMenuEntry {
    enum Kind { case item, header, separator, submenu }

    var kind: Kind
    var title = ""
    var symbol: String?
    var checked = false
    var enabled = true
    var action: (() -> Void)?
    var children: [VMenuEntry] = []

    static func item(_ title: String, symbol: String? = nil, checked: Bool = false,
                     enabled: Bool = true, action: @escaping () -> Void) -> VMenuEntry {
        VMenuEntry(kind: .item, title: title, symbol: symbol, checked: checked, enabled: enabled, action: action)
    }
    static func header(_ title: String) -> VMenuEntry { VMenuEntry(kind: .header, title: title, enabled: false) }
    static var separator: VMenuEntry { VMenuEntry(kind: .separator) }
    static func submenu(_ title: String, enabled: Bool = true, _ children: [VMenuEntry]) -> VMenuEntry {
        VMenuEntry(kind: .submenu, title: title, enabled: enabled, children: children)
    }
}

/// 押された項目の処理を持たせる入れ物（NSMenuItem が保持する）
private final class VMenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}

/// クリックされたら、真下に NSMenu を開く透明なビュー。
/// SwiftUI の Menu は見た目を自由に描けず、重ねるとクリックも通らないため、これを使う。
struct VMenuTrigger: NSViewRepresentable {
    let entries: () -> [VMenuEntry]

    func makeNSView(context: Context) -> TriggerView {
        let view = TriggerView()
        view.entries = entries
        return view
    }

    func updateNSView(_ view: TriggerView, context: Context) {
        view.entries = entries
        view.isActive = context.environment.isEnabled
    }

    final class TriggerView: NSView {
        var entries: (() -> [VMenuEntry])?
        var isActive = true

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard isActive, let entries = entries else { return }
            let menu = Self.makeMenu(entries())
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: isFlipped ? bounds.height : 0), in: self)
        }

        static func makeMenu(_ entries: [VMenuEntry]) -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            for entry in entries {
                switch entry.kind {
                case .separator:
                    menu.addItem(.separator())
                case .header:
                    let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    menu.addItem(item)
                case .submenu:
                    let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
                    item.isEnabled = entry.enabled
                    item.submenu = makeMenu(entry.children)
                    menu.addItem(item)
                case .item:
                    let item = NSMenuItem(title: entry.title, action: #selector(VMenuAction.fire), keyEquivalent: "")
                    let target = VMenuAction(entry.action ?? {})
                    item.target = target
                    item.representedObject = target      // ここで保持する
                    item.isEnabled = entry.enabled
                    item.state = entry.checked ? .on : .off
                    if let symbol = entry.symbol {
                        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                    }
                    menu.addItem(item)
                }
            }
            return menu
        }
    }
}

// MARK: - Slide toggle（コピー／移動）

/// brand-blue のトラックの上を、白いつまみが約 0.22 秒でスライドする。
struct VSlideToggle: View {
    @Binding var selection: OperationMode

    private let width: CGFloat = 144
    private let height: CGFloat = 44
    private let inset: CGFloat = 4

    private var segment: CGFloat { (width - inset * 2) / 2 }

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(V.blueFill)

            Capsule()
                .fill(V.thumb)
                .overlay(
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Rectangle().fill(Color.black.opacity(0.18)).frame(height: 2)
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
                            .foregroundColor(selection == mode ? V.thumbInk : V.onBrand)
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
                        .background(Capsule().fill(selected ? AnyShapeStyle(V.blueFill) : AnyShapeStyle(Color.clear)))
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
                    .fill(V.blueFill)
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

/// ウインドウの設定（透明なタイトルバー・サイズ固定）。背景は VGlassBackground（containerBackground）が担当する。
struct VWindowStyler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { StylerView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class StylerView: NSView {
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window = window else { return }
            apply(to: window)
            // SwiftUI がツールバーを組み直すと設定が戻ることがあるので、前面になるたびに当て直す
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    guard let window = self?.window else { return }
                    self?.apply(to: window)
                }
            }
            DispatchQueue.main.async { [weak self] in
                if let window = self?.window { self?.apply(to: window) }
            }
        }

        deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

        private func apply(to window: NSWindow) {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden            // タイトルは SwiftUI 側で中央に描く
            window.titlebarSeparatorStyle = .none
            // 背景（containerBackground）が信号ボタンを覆わないよう、タイトルバーの層を最前面に出す
            if let container = window.standardWindowButton(.closeButton)?.superview?.superview,
               let frame = container.superview, frame.subviews.last !== container {
                frame.addSubview(container, positioned: .above, relativeTo: nil)
            }
            // 大きさは固定（最小サイズのまま）
            window.styleMask.remove(.resizable)
            window.standardWindowButton(.zoomButton)?.isEnabled = false
            // 画面をタイトルバーの下まで広げる（歯車をタイトルバーの高さに重ねるため）
            window.styleMask.insert(.fullSizeContentView)
            if #unavailable(macOS 15) { window.backgroundColor = VNS.ground }   // containerBackground が使えない古い OS
        }
    }
}

/// すりガラスの背景。SwiftUI 標準の containerBackground（WWDC24「Tailor macOS windows with SwiftUI」）で
/// ウインドウの背景を素材に替える。ぼかし具合は素材の厚み（ultraThin … ultraThick）で段階的に変える。
struct VGlassBackground: ViewModifier {
    var blur: Double
    @Environment(\.colorScheme) private var scheme

    private var material: Material {
        switch Int((blur * 4).rounded()) {
        case ...0: return .ultraThinMaterial
        case 1: return .thinMaterial
        case 2: return .regularMaterial
        case 3: return .thickMaterial
        default: return .ultraThickMaterial
        }
    }

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .containerBackground(for: .window) {
                    ZStack {
                        Rectangle().fill(material)
                        // ライトは白文字にするので、暗めのガラス色を重ねる
                        if scheme == .light {
                            Color(red: 0.13, green: 0.15, blue: 0.19).opacity(0.62)
                        }
                    }
                }
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            content
        }
    }
}
