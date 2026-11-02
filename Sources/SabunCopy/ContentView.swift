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
            case .all: return "すべて"
            case .new: return "新規"
            case .changed: return "上書き・確認"
            case .skipped: return "スキップ"
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
        case .error: return "exclamationmark.triangle"
        }
    }

    var label: String {
        switch self {
        case .new: return "新規"
        case .overwrite: return "上書き"
        case .same: return "同一"
        case .skip: return "スキップ"
        case .ask: return "確認"
        case .keepBoth: return "両方残す"
        case .error: return "エラー"
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

    var body: some View {
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
        .frame(minWidth: 480, maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundColor(V.text)
        .background(V.ground.ignoresSafeArea())
        .background(VWindowStyler())
        .onAppear { model.applyWindowLevel() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.showOptions.toggle()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("設定")
                .popover(isPresented: $model.showOptions, arrowEdge: .bottom) {
                    optionsPopover
                }
            }
        }
        .sheet(item: $model.pending) { req in
            ConflictSheet(info: req.info) { decision in
                model.resolve(decision)
            }
            .interactiveDismissDisabled()
        }
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
                                              message: "コピーするファイル・フォルダを選択"))
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
                                          message: "コピー先のフォルダを選択").first {
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
                    .help(favorite ? "お気に入りから外す" : "お気に入りに追加")
                }
            }
        }
        .disabled(model.busy)
    }

    private var existingFavorites: [URL] { model.favoriteFolders.filter(isExistingDirectory) }
    private var existingRecents: [URL] { model.recentFolders.filter(isExistingDirectory) }

    private var destinationMenu: some View {
        Menu {
            Section("お気に入り") {
                if existingFavorites.isEmpty {
                    Text("（まだありません。★で追加できます）")
                }
                ForEach(existingFavorites, id: \.self) { url in
                    Button {
                        model.setDestination(url)
                    } label: {
                        Label(tildePath(url), systemImage: "star.fill")
                    }
                }
            }
            Section("最近使ったフォルダ") {
                if existingRecents.isEmpty {
                    Text("（履歴はありません）")
                }
                ForEach(existingRecents, id: \.self) { url in
                    Button {
                        model.setDestination(url)
                    } label: {
                        Label(tildePath(url), systemImage: "clock")
                    }
                }
            }
            Divider()
            Menu("お気に入りから外す") {
                ForEach(model.favoriteFolders, id: \.self) { url in
                    Button(tildePath(url)) { model.removeFavorite(url) }
                }
            }
            .disabled(model.favoriteFolders.isEmpty)
            Button("最近の履歴を消去") { model.clearRecents() }
                .disabled(model.recentFolders.isEmpty)
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 13))
                .foregroundColor(V.text)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: V.rSm, style: .continuous).fill(V.chip))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("最近・お気に入り")
    }

    // MARK: Settings

    private func column<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
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
                            label: { $0.label })
                        .help("同名ファイルを比べる基準。空欄（—）なら比べず、右の「処理」で扱いを決めます。同じ値のときはスキップします")

                    if model.compare != .none {
                        VSelect(options: [true, false],
                                selection: $model.preferHigh,
                                label: { $0 ? model.compare.highLabel : model.compare.lowLabel })
                            .help("どちらを残すか")
                    }
                }
            }

            column("処理") {
                if model.compare == .none {
                    VSelect(options: PolicyChoice.allCases,
                            selection: $model.policy,
                            label: { $0.label })
                        .help("同名ファイルがあったときの扱い")
                } else {
                    VSelect(options: [true],
                            selection: .constant(true),
                            label: { _ in "残す" })
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

    // MARK: Gear popover

    private var optionsPopover: some View {
        VStack(alignment: .leading, spacing: V.s3) {
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
                        Text(model.operation == .move ? "移動開始" : "コピー開始")
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
                    Text("差分を解析中… \(model.analyzeDone) / \(model.analyzeTotal)")
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
                    || $0.outcome == .keepBoth || $0.outcome == .error
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
                    Text("\(result.rows.count) ファイル")
                        .font(VFont.ui(11))
                        .foregroundColor(V.muted)
                    Spacer()
                    Button("閉じる") { onClose() }
                        .buttonStyle(VSheetButtonStyle())
                        .keyboardShortcut(.cancelAction)
                    Button(result.operation == .move ? "この内容で移動開始" : "この内容でコピー開始") { onStart() }
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
                    fileCard(title: "コピー元", snap: info.source, other: info.destination)
                    fileCard(title: "コピー先（既存）", snap: info.destination, other: info.source)
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
        if diff > 2 { return ("新しい", true) }
        if diff < -2 { return ("古い", false) }
        return nil
    }
}
