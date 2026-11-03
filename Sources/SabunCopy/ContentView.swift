import SwiftUI
import AppKit

private func pickURLs(files: Bool, multiple: Bool, message: String) -> [URL] {
    let panel = NSOpenPanel()
    panel.canChooseFiles = files
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = multiple
    panel.canCreateDirectories = true
    panel.message = message
    return panel.runModal() == .OK ? panel.urls : []
}

private func tildePath(_ url: URL) -> String {
    url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
}

/// 競合ダイアログ内のチェック状態（@State マクロを避けるため ObservableObject で持つ）
final class ConflictChoice: ObservableObject {
    @Published var applyToAll = false
}

/// 差分プレビューの表示フィルタ
final class PreviewFilter: ObservableObject {
    enum Kind: String, CaseIterable {
        case all, new, changed, skipped
        var label: String {
            switch self {
            case .all: return L("すべて")
            case .new: return L("新規")
            case .changed: return L("上書き・確認")
            case .skipped: return L("スキップ")
            }
        }
    }
    @Published var kind: Kind = .all
}

// MARK: - Presentation

private extension PreviewOutcome {
    var icon: String {
        switch self {
        case .new: return "plus.circle"
        case .overwrite: return "arrow.triangle.2.circlepath"
        case .same: return "equal.circle"
        case .skip: return "chevron.right.circle"
        case .ask: return "questionmark.circle"
        case .keepBoth: return "doc.on.doc"
        case .trash: return "trash"
        case .error: return "exclamationmark.triangle"
        }
    }

    var label: String {
        switch self {
        case .new: return L("新規")
        case .overwrite: return L("上書き")
        case .same: return L("同一")
        case .skip: return L("スキップ")
        case .ask: return L("確認")
        case .keepBoth: return L("両方残す")
        case .trash: return L("ゴミ箱へ")
        case .error: return L("エラー")
        }
    }
}

private extension LogKind {
    var icon: String {
        switch self {
        case .copied: return "plus.circle"
        case .overwritten: return "arrow.triangle.2.circlepath"
        case .renamed: return "doc.on.doc"
        case .skipped: return "chevron.right.circle"
        case .error: return "exclamationmark.triangle"
        case .info: return "info.circle"
        }
    }

    var color: Color {
        self == .error ? V.danger : V.muted
    }
}

// MARK: - Main window

struct ContentView: View {
    @ObservedObject private var model = CopyModel.shared

    private var fullBody: some View {
        VStack(spacing: V.s2) {
            sourceRow
            destinationRow
            settingsPanel
            actionRow
            progressPane
                .sheet(item: $model.preview) { result in
                    PreviewSheet(
                        result: result,
                        onClose: { model.preview = nil },
                        onStart: {
                            model.preview = nil
                            model.start()
                        }
                    )
                    .interactiveDismissDisabled()
                }
            logPane
        }
        .padding(.horizontal, V.s3)
        .padding(.top, V.s2)
        .padding(.bottom, V.s3)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    var body: some View {
        Group {
            if model.dropMode { dropModeBody } else { fullBody }
        }
        .foregroundColor(V.text)
        .background(VWindowStyler(theme: model.theme, glass: model.glass))
        // ドロップモードの切り替えと歯車：タイトルバーの高さ（信号ボタンと同じ行）の右端に重ねる
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 0) {
                DropModeButton()
                if !model.dropMode { GearButton() }
            }
            .padding(.trailing, 4)
            .ignoresSafeArea(.container, edges: .top)
        }
        .onAppear { model.applyWindowLevel() }
        .sheet(item: $model.pending) { req in
            ConflictSheet(info: req.info) { decision in
                model.resolve(decision)
            }
            .interactiveDismissDisabled()
        }
    }

    // MARK: Drop mode

    /// コピー元をドロップするだけの小さな表示
    private var dropModeBody: some View {
        ZStack {
            RoundedRectangle(cornerRadius: V.rSm, style: .continuous)
                .strokeBorder(model.srcTargeted ? V.blue : V.barMuted,
                              style: StrokeStyle(lineWidth: 1.5, dash: [6]))
            VStack(spacing: 6) {
                Image(systemName: model.sources.isEmpty ? "square.and.arrow.down" : "tray.full")
                    .font(.system(size: 20))
                    .foregroundColor(model.sources.isEmpty ? V.muted : V.blueTint)
                Text(model.sources.isEmpty ? L("コピー元をドロップ") : L("%ld 項目", model.sources.count))
                    .font(VFont.ui(12, model.sources.isEmpty ? .regular : .medium))
                    .foregroundColor(model.sources.isEmpty ? V.muted : V.text)
            }
            if !model.sources.isEmpty {
                Button {
                    model.clearSources()
                } label: {
                    Image(systemName: "trash").font(.system(size: 12))
                }
                .buttonStyle(VChipStyle(width: 24, height: 24))
                .help("クリア")
                .padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .frame(width: 236, height: 84)
        .padding(.horizontal, V.s3)
        .padding(.top, V.s2)
        .padding(.bottom, V.s3)
        .dropDestination(for: URL.self) { urls, _ in
            model.addSources(urls)
            return true
        } isTargeted: { model.srcTargeted = $0 }
        .fixedSize()
        .disabled(model.busy)
    }

    // MARK: Source

    private var sourceRow: some View {
        HStack(alignment: .top, spacing: V.s2) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 14))
                .foregroundColor(V.muted)
                .frame(width: 22, height: 28)
                .help("コピー元")

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: V.rSm, style: .continuous)
                    .strokeBorder(model.srcTargeted ? V.blue : V.barMuted,
                                  style: StrokeStyle(lineWidth: 1.5, dash: model.sources.isEmpty ? [6] : []))
                if model.sources.isEmpty {
                    Text("コピー元をドロップ")
                        .font(VFont.ui(12))
                        .foregroundColor(V.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(model.sources, id: \.self) { url in
                                HStack(spacing: 6) {
                                    Image(systemName: isExistingDirectory(url) ? "folder" : "doc")
                                        .font(.system(size: 12))
                                        .frame(width: 14)
                                    Text(url.lastPathComponent)
                                        .font(VFont.ui(12))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 0)
                                }
                                .frame(height: 15)
                            }
                        }
                        .padding(6)
                    }
                }
            }
            .frame(height: 58)
            .dropDestination(for: URL.self) { urls, _ in
                model.addSources(urls)
                return true
            } isTargeted: { model.srcTargeted = $0 }

            VStack(spacing: V.s1) {
                Button {
                    model.addSources(pickURLs(files: true, multiple: true,
                                              message: L("コピーするファイル・フォルダを選択")))
                } label: {
                    Image(systemName: "plus").font(.system(size: 13))
                }
                .buttonStyle(VChipStyle(width: 26, height: 26))
                .help("追加…")

                Button {
                    model.clearSources()
                } label: {
                    Image(systemName: "trash").font(.system(size: 13))
                }
                .buttonStyle(VChipStyle(width: 26, height: 26))
                .help("クリア")
                .disabled(model.sources.isEmpty)
            }
        }
        .disabled(model.busy)
    }

    // MARK: Destination

    private var destinationRow: some View {
        HStack(spacing: V.s2) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 14))
                .foregroundColor(V.muted)
                .frame(width: 22)
                .help("コピー先")

            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 14))
                    .foregroundColor(V.blue)
                if let dest = model.destination {
                    Text(tildePath(dest))
                        .font(VFont.ui(13))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("コピー先のフォルダをドロップ")
                        .font(VFont.ui(13))
                        .foregroundColor(V.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .overlay(
                RoundedRectangle(cornerRadius: V.rSm, style: .continuous)
                    .strokeBorder(model.dstTargeted ? V.blue : V.barMuted,
                                  style: StrokeStyle(lineWidth: 1.5, dash: model.destination == nil ? [6] : []))
            )
            .contentShape(Rectangle())
            .dropDestination(for: URL.self) { urls, _ in
                if let dir = urls.first(where: isExistingDirectory) {
                    model.setDestination(dir)
                    return true
                }
                return false
            } isTargeted: { model.dstTargeted = $0 }

            HStack(spacing: V.s1) {
                Button {
                    if let url = pickURLs(files: false, multiple: false,
                                          message: L("コピー先のフォルダを選択")).first {
                        model.setDestination(url)
                    }
                } label: {
                    Image(systemName: "folder").font(.system(size: 13))
                }
                .buttonStyle(VChipStyle())
                .help("フォルダを選ぶ…")

                destinationMenu

                if let dest = model.destination {
                    let favorite = model.isFavorite(dest)
                    Button {
                        model.toggleFavorite(dest)
                    } label: {
                        Image(systemName: favorite ? "star.fill" : "star")
                            .font(.system(size: 13))
                            .foregroundColor(favorite ? V.blueTint : V.text)
                    }
                    .buttonStyle(VChipStyle())
                    .help(LocalizedStringKey(favorite ? "お気に入りから外す" : "お気に入りに追加"))
                }
            }
        }
        .disabled(model.busy)
    }

    private var existingFavorites: [URL] { model.favoriteFolders.filter(isExistingDirectory) }
    private var existingRecents: [URL] { model.recentFolders.filter(isExistingDirectory) }

    private var destinationMenu: some View {
        Image(systemName: "clock.arrow.circlepath")
            .font(.system(size: 13))
            .foregroundColor(V.text)
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: V.rSm, style: .continuous).fill(V.chip))
            .overlay(
                VMenuTrigger(entries: {
                    var entries: [VMenuEntry] = [.header(L("お気に入り"))]
                    if existingFavorites.isEmpty {
                        entries.append(.item(L("（まだありません。★で追加できます）"), enabled: false, action: {}))
                    }
                    for url in existingFavorites {
                        entries.append(.item(tildePath(url), symbol: "star.fill") { model.setDestination(url) })
                    }
                    entries.append(.separator)
                    entries.append(.header(L("最近使ったフォルダ")))
                    if existingRecents.isEmpty {
                        entries.append(.item(L("（履歴はありません）"), enabled: false, action: {}))
                    }
                    for url in existingRecents {
                        entries.append(.item(tildePath(url), symbol: "clock") { model.setDestination(url) })
                    }
                    entries.append(.separator)
                    entries.append(.submenu(L("お気に入りから外す"),
                                            enabled: !model.favoriteFolders.isEmpty,
                                            model.favoriteFolders.map { url in
                                                VMenuEntry.item(tildePath(url)) { model.removeFavorite(url) }
                                            }))
                    entries.append(.item(L("最近の履歴を消去"), enabled: !model.recentFolders.isEmpty) {
                        model.clearRecents()
                    })
                    return entries
                })
            )
            .help("最近・お気に入り")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L("最近・お気に入り"))
            .accessibilityAddTraits(.isButton)
    }

    // MARK: Settings

    private func column<C: View>(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(VFont.ui(11))
                .foregroundColor(V.muted)
            content()
        }
    }

    private var settingsPanel: some View {
        HStack(alignment: .bottom, spacing: V.s3) {
            VSlideToggle(selection: $model.operation)
                .help("コピー、または移動（照合したあと、移動元をゴミ箱へ入れます）")

            column("比較") {
                HStack(spacing: V.s1) {
                    VSelect(options: CompareMode.allCases,
                            selection: $model.compare,
                            label: { $0.label },
                            measure: CompareMode.allCases.map(\.label))
                        .help("同名ファイルを比べる基準。空欄（—）なら比べず、右の「処理」で扱いを決めます。同じ値のときはスキップします")

                    // 空欄のときも場所は空けておく（「処理」の位置を動かさない）
                    VSelect(options: [true, false],
                            selection: $model.preferHigh,
                            label: { $0 ? model.compare.highLabel : model.compare.lowLabel },
                            measure: [L("新しい"), L("古い"), L("大きい"), L("小さい")])
                        .opacity(model.compare == .none ? 0 : 1)
                        .allowsHitTesting(model.compare != .none)
                        .accessibilityHidden(model.compare == .none)
                        .help("どちらを残すか")
                }
            }

            column("処理") {
                if model.compare == .none {
                    VSelect(options: PolicyChoice.allCases,
                            selection: $model.policy,
                            label: { $0.label },
                            measure: PolicyChoice.allCases.map(\.label) + [L("残す")])
                        .help("同名ファイルがあったときの扱い")
                } else {
                    VSelect(options: [true],
                            selection: .constant(true),
                            label: { _ in L("残す") },
                            measure: PolicyChoice.allCases.map(\.label) + [L("残す")])
                        .disabled(true)
                        .help("比較で選んだほうを残します")
                }
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: V.rMd, style: .continuous).fill(V.row))
        .disabled(model.busy)
    }

    // MARK: Actions / progress / log

    private var actionRow: some View {
        HStack(spacing: V.s2) {
            if model.busy {
                Button {
                    model.cancel()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "stop.fill").font(.system(size: 16))
                        Text("中止").font(VFont.ui(17, .medium))
                    }
                    .foregroundColor(V.text)
                    .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(VEmbossStyle(kind: .chip))
            } else {
                Button {
                    model.analyze()
                } label: {
                    Image(systemName: "eye")
                        .font(.system(size: 18))
                        .foregroundColor(V.text)
                        .frame(width: 50, height: 50)
                }
                .buttonStyle(VEmbossStyle(kind: .chip))
                .help("差分を確認")
                .disabled(!model.canStart)

                Button {
                    model.start()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill").font(.system(size: 16))
                        Text(model.operation == .move ? L("移動開始") : L("コピー開始"))
                            .font(VFont.ui(17, .medium))
                    }
                    .foregroundColor(V.onBrand)
                    .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(VEmbossStyle(kind: .blue))
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canStart)
            }
        }
        .frame(height: 50)
    }

    private var progressPane: some View {
        VStack(alignment: .leading, spacing: V.s1) {
            VProgressBar(fraction: model.progress.fraction)
            HStack(spacing: V.s2) {
                if model.isAnalyzing {
                    Text(L("差分を解析中… %ld / %ld", model.analyzeDone, model.analyzeTotal))
                        .font(VFont.ui(11))
                        .lineLimit(1)
                } else if !model.busy, let summary = model.summaryText {
                    Text(summary)
                        .font(VFont.ui(11))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(summary)
                } else {
                    Text(model.progress.current.isEmpty ? " " : model.progress.current)
                        .font(VFont.mono(11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Text("\(model.progress.filesDone) / \(model.progress.filesTotal)")
                    .font(VFont.ui(11))
            }
            .foregroundColor(V.muted)
            .frame(height: 16)
        }
    }

    private var logPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(model.logs) { entry in
                        HStack(spacing: 5) {
                            Image(systemName: entry.kind.icon)
                                .font(.system(size: 11))
                                .foregroundColor(entry.kind.color)
                                .frame(width: 12)
                            Text(entry.text)
                                .font(VFont.mono(11))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .frame(height: 16)
                        .id(entry.id)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            .onChange(of: model.logs.count) { _ in
                if let id = model.logs.last?.id {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
        }
        .frame(height: 56)
        .background(RoundedRectangle(cornerRadius: V.rSm, style: .continuous).fill(V.row))
    }
}

// MARK: - Gear（タイトルバー右端）

/// 歯車のボタン。タイトルバーの右端に重ねる（ContentView の overlay）。
struct DropModeButton: View {
    @ObservedObject private var model = CopyModel.shared

    var body: some View {
        Button {
            model.dropMode.toggle()
        } label: {
            Image(systemName: model.dropMode ? "arrow.up.left.and.arrow.down.right"
                                             : "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 13))
                .foregroundColor(V.text)
                .frame(width: 36, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(model.dropMode ? "通常の表示に戻す" : "ドロップモード")
        .disabled(model.busy)
    }
}

struct GearButton: View {
    @ObservedObject private var model = CopyModel.shared

    var body: some View {
        Button {
            model.showOptions.toggle()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 14))
                .foregroundColor(V.text)
                .frame(width: 36, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("設定")
        .popover(isPresented: $model.showOptions, arrowEdge: .bottom) {
            OptionsPopover()
        }
    }
}

struct OptionsPopover: View {
    @ObservedObject private var model = CopyModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: V.s3) {
            VPillSegmented(options: ThemeChoice.allCases,
                           selection: $model.theme,
                           label: { $0.label })

            HStack(spacing: 8) {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.system(size: 12))
                    .foregroundColor(V.muted)
                    .help("すりガラス")
                Slider(value: $model.glass, in: 0...1)
                    .controlSize(.small)
                    .tint(V.blue)
            }

            Toggle(isOn: Binding(
                get: { model.verify || model.operation == .move },
                set: { model.verify = $0 }
            )) {
                Label("ハッシュ照合", systemImage: "checkmark.shield")
            }
            .disabled(model.operation == .move)
            .help("コピー後にSHA-256で内容が一致するかを確かめます。移動のときは常にオンです")

            Toggle(isOn: $model.alwaysOnTop) {
                Label("最前面に固定", systemImage: "pin")
            }
            .help("ウインドウを他のウインドウより常に前に表示します")

            Toggle(isOn: $model.autoCloseWhenDone) {
                Label("処理後に閉じる", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .help("すべて終わったらウインドウを閉じます。エラーや中止のときは閉じません。閉じるとアプリも終了します")
        }
        .toggleStyle(VCheckStyle())
        .padding(14)
        .frame(width: 206)
        .background(V.row)
    }
}

// MARK: - Preview sheet（差分の確認）

struct PreviewSheet: View {
    let result: PreviewResult
    let onClose: () -> Void
    let onStart: () -> Void
    @StateObject private var filter = PreviewFilter()

    private var filtered: [PreviewRow] {
        switch filter.kind {
        case .all:
            return result.rows
        case .new:
            return result.rows.filter { $0.outcome == .new }
        case .changed:
            return result.rows.filter {
                $0.outcome == .overwrite || $0.outcome == .ask
                    || $0.outcome == .keepBoth || $0.outcome == .trash || $0.outcome == .error
            }
        case .skipped:
            return result.rows.filter { $0.outcome == .same || $0.outcome == .skip }
        }
    }

    var body: some View {
        VSheet(width: 620, height: 520, padding: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Text("差分の確認")
                    .font(VFont.ui(15, .medium))

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 6)],
                          alignment: .leading, spacing: 6) {
                    pill(.new)
                    pill(.overwrite)
                    pill(.ask)
                    pill(.keepBoth)
                    if result.count(.trash) > 0 { pill(.trash) }
                    pill(.same)
                    pill(.skip)
                    if result.count(.error) > 0 { pill(.error) }
                }

                VPillSegmented(options: PreviewFilter.Kind.allCases,
                               selection: $filter.kind,
                               label: { $0.label })

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { row in
                            let accent = row.outcome == .overwrite ? V.blueTint : V.muted
                            HStack(spacing: 8) {
                                Image(systemName: row.outcome.icon)
                                    .font(.system(size: 13))
                                    .foregroundColor(accent)
                                    .frame(width: 16)
                                Text(row.path)
                                    .font(VFont.mono(11))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 8)
                                Text(row.outcome.label)
                                    .font(VFont.ui(11))
                                    .foregroundColor(accent)
                                Text(ByteCountFormatter.string(fromByteCount: row.size, countStyle: .file))
                                    .font(VFont.ui(11))
                                    .foregroundColor(V.muted)
                                    .frame(width: 64, alignment: .trailing)
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 28)
                        }
                    }
                    .padding(4)
                }
                .background(RoundedRectangle(cornerRadius: V.rMd, style: .continuous).fill(V.row))

                HStack(spacing: V.s2) {
                    Text(L("%ld ファイル", result.rows.count))
                        .font(VFont.ui(11))
                        .foregroundColor(V.muted)
                    Spacer()
                    Button("閉じる") { onClose() }
                        .buttonStyle(VSheetButtonStyle())
                        .keyboardShortcut(.cancelAction)
                    Button(result.operation == .move ? L("この内容で移動開始") : L("この内容でコピー開始")) { onStart() }
                        .buttonStyle(VSheetButtonStyle(primary: true))
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func pill(_ outcome: PreviewOutcome) -> some View {
        VPill(icon: outcome.icon, text: "\(outcome.label) \(result.count(outcome))")
    }
}

// MARK: - Conflict sheet（競合ダイアログ）

struct ConflictSheet: View {
    let info: ConflictInfo
    let onDecide: (ConflictDecision?) -> Void
    @StateObject private var choice = ConflictChoice()

    var body: some View {
        VSheet(width: 600) {
            VStack(alignment: .leading, spacing: 14) {
                Text("同じ名前のファイルがあります")
                    .font(VFont.ui(15, .medium))
                Text(info.relativePath)
                    .font(VFont.mono(13))
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(alignment: .top, spacing: V.s3) {
                    fileCard(title: L("コピー元"), snap: info.source, other: info.destination)
                    fileCard(title: L("コピー先（既存）"), snap: info.destination, other: info.source)
                }

                if info.identical {
                    Text("サイズと更新日時が同じです（同一ファイルの可能性が高い）")
                        .font(VFont.ui(11))
                        .foregroundColor(V.muted)
                }

                Toggle("以降の競合すべてに同じ処理を適用", isOn: $choice.applyToAll)
                    .toggleStyle(VCheckStyle(boxLeading: true))

                HStack(spacing: V.s2) {
                    Button("中止") { onDecide(nil) }
                        .buttonStyle(VSheetButtonStyle())
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("スキップ") { decide(.skip) }
                        .buttonStyle(VSheetButtonStyle())
                    Button("両方残す") { decide(.keepBoth) }
                        .buttonStyle(VSheetButtonStyle())
                    Button("上書き") { decide(.overwrite) }
                        .buttonStyle(VSheetButtonStyle())
                    Button("新しいほうだけ上書き") { decide(.overwriteIfNewer) }
                        .buttonStyle(VSheetButtonStyle(primary: true))
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func decide(_ action: ConflictAction) {
        onDecide(ConflictDecision(action: action, applyToAll: choice.applyToAll))
    }

    private func fileCard(title: String, snap: FileSnapshot, other: FileSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(VFont.ui(11))
                .foregroundColor(V.muted)
            Text(ByteCountFormatter.string(fromByteCount: snap.size, countStyle: .file))
                .font(VFont.ui(20, .medium))
            Text(snap.modified.formatted(date: .long, time: .standard))
                .font(VFont.ui(13))
            if let badge = badge(snap, other) {
                Text(badge.text)
                    .font(VFont.ui(11, .bold))
                    .foregroundColor(badge.isNewer ? V.ground : V.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(badge.isNewer ? V.light : V.chip))
                    .padding(.top, 4)
            }
        }
        .padding(V.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: V.rMd, style: .continuous).fill(V.row))
    }

    private func badge(_ snap: FileSnapshot, _ other: FileSnapshot) -> (text: String, isNewer: Bool)? {
        let diff = snap.modified.timeIntervalSince(other.modified)
        if diff > 2 { return (L("新しい"), true) }
        if diff < -2 { return (L("古い"), false) }
        return nil
    }
}
