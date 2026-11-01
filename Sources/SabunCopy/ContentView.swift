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
    enum Kind: String, CaseIterable, Identifiable {
        case all, new, changed, skipped
        var id: String { rawValue }
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
        case .skip: return "forward.circle"
        case .ask: return "questionmark.circle"
        case .keepBoth: return "doc.on.doc"
        case .error: return "exclamationmark.triangle.fill"
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

    var color: Color {
        switch self {
        case .new: return .green
        case .overwrite: return .orange
        case .same: return .secondary
        case .skip: return .secondary
        case .ask: return .blue
        case .keepBoth: return .blue
        case .error: return .red
        }
    }
}

private extension LogKind {
    var icon: String {
        switch self {
        case .copied: return "plus.circle"
        case .overwritten: return "arrow.triangle.2.circlepath"
        case .renamed: return "doc.on.doc"
        case .skipped: return "forward.circle"
        case .error: return "exclamationmark.triangle.fill"
        case .info: return "info.circle"
        }
    }

    var color: Color {
        switch self {
        case .copied: return .green
        case .overwritten: return .orange
        case .renamed: return .blue
        case .skipped: return .secondary
        case .error: return .red
        case .info: return .secondary
        }
    }
}

// MARK: - Main window

struct ContentView: View {
    @ObservedObject private var model = CopyModel.shared

    var body: some View {
        VStack(spacing: 8) {
            sourceRow
            destinationRow
            settingsBox
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
        .padding(12)
        .frame(minWidth: 480, minHeight: 440)
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

    // MARK: Source / destination

    private var sourceRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "square.and.arrow.up")
                .foregroundColor(.secondary)
                .frame(width: 22, height: 28)
                .help("コピー元")

            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(model.srcTargeted ? Color.accentColor : Color.secondary.opacity(0.6),
                                  style: StrokeStyle(lineWidth: 1.5, dash: model.sources.isEmpty ? [6] : []))
                if model.sources.isEmpty {
                    Text("コピー元をドロップ")
                        .font(.callout)
                        .foregroundColor(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(model.sources, id: \.self) { url in
                                Label(url.lastPathComponent,
                                      systemImage: isExistingDirectory(url) ? "folder" : "doc")
                                    .font(.callout)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                    }
                }
            }
            .frame(height: 58)
            .dropDestination(for: URL.self) { urls, _ in
                model.addSources(urls)
                return true
            } isTargeted: { model.srcTargeted = $0 }

            VStack(spacing: 4) {
                Button {
                    model.addSources(pickURLs(files: true, multiple: true,
                                              message: "コピーするファイル・フォルダを選択"))
                } label: {
                    Image(systemName: "plus").frame(width: 16)
                }
                .help("追加…")

                Button {
                    model.clearSources()
                } label: {
                    Image(systemName: "trash").frame(width: 16)
                }
                .help("クリア")
                .disabled(model.sources.isEmpty)
            }
            .controlSize(.small)
        }
        .disabled(model.busy)
    }

    private var destinationRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.and.arrow.down")
                .foregroundColor(.secondary)
                .frame(width: 22)
                .help("コピー先")

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(model.dstTargeted ? Color.accentColor : Color.secondary.opacity(0.6),
                                  style: StrokeStyle(lineWidth: 1.5, dash: model.destination == nil ? [6] : []))
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill").foregroundColor(.accentColor)
                    if let dest = model.destination {
                        Text(tildePath(dest))
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("コピー先のフォルダをドロップ")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
            }
            .frame(height: 28)
            .dropDestination(for: URL.self) { urls, _ in
                if let dir = urls.first(where: isExistingDirectory) {
                    model.setDestination(dir)
                    return true
                }
                return false
            } isTargeted: { model.dstTargeted = $0 }

            HStack(spacing: 4) {
                Button {
                    if let url = pickURLs(files: false, multiple: false,
                                          message: "コピー先のフォルダを選択").first {
                        model.setDestination(url)
                    }
                } label: {
                    Image(systemName: "folder").frame(width: 16)
                }
                .help("フォルダを選ぶ…")

                destinationMenu

                if let dest = model.destination {
                    let favorite = model.isFavorite(dest)
                    Button {
                        model.toggleFavorite(dest)
                    } label: {
                        Image(systemName: favorite ? "star.fill" : "star")
                            .foregroundColor(favorite ? .yellow : .primary)
                            .frame(width: 16)
                    }
                    .help(favorite ? "お気に入りから外す" : "お気に入りに追加")
                }
            }
            .controlSize(.small)
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
        }
        .menuStyle(.button)
        .fixedSize()
        .help("最近・お気に入り")
    }

    // MARK: Settings（動作・比較・処理）

    private func column<V: View>(_ title: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            content()
        }
    }

    private var settingsBox: some View {
        HStack(alignment: .bottom, spacing: 14) {
            column("動作") {
                Picker("動作", selection: $model.operation) {
                    ForEach(OperationMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("コピー、または移動（照合したあと、移動元をゴミ箱へ入れます）")
            }

            column("比較") {
                HStack(spacing: 4) {
                    Picker("比較", selection: $model.compare) {
                        ForEach(CompareMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .help("同名ファイルを比べる基準。空欄（—）なら比べず、右の「処理」で扱いを決めます。同じ値のときはスキップします")

                    if model.compare != .none {
                        Picker("残すほう", selection: $model.preferHigh) {
                            Text(model.compare.highLabel).tag(true)
                            Text(model.compare.lowLabel).tag(false)
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                        .help("どちらを残すか")
                    }
                }
            }

            column("処理") {
                if model.compare == .none {
                    Picker("処理", selection: $model.policy) {
                        ForEach(PolicyChoice.allCases) { choice in
                            Text(choice.label).tag(choice)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .help("同名ファイルがあったときの扱い")
                } else {
                    Picker("処理", selection: .constant(true)) {
                        Text("残す").tag(true)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .disabled(true)
                    .help("比較で選んだほうを残します")
                }
            }

            Spacer(minLength: 0)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.10)))
        .disabled(model.busy)
    }

    // MARK: Gear popover

    private var optionsPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
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
        .toggleStyle(.checkbox)
        .padding(14)
    }

    // MARK: Actions / progress / log

    private var actionRow: some View {
        HStack(spacing: 8) {
            if model.isAnalyzing {
                ProgressView().controlSize(.small)
                Text("解析中 \(model.analyzeDone) / \(model.analyzeTotal)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if model.busy {
                Button {
                    model.cancel()
                } label: {
                    Label("中止", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
            } else {
                Button {
                    model.analyze()
                } label: {
                    Image(systemName: "eye")
                        .frame(minHeight: 30)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .help("差分を確認")
                .disabled(!model.canStart)

                Button {
                    model.start()
                } label: {
                    Label(model.operation == .move ? "移動開始" : "コピー開始", systemImage: "play.fill")
                        .font(.title3.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canStart)
            }
        }
    }

    private var progressPane: some View {
        VStack(alignment: .leading, spacing: 3) {
            ProgressView(value: model.progress.fraction)
            HStack {
                Text(model.progress.current)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("\(model.progress.filesDone) / \(model.progress.filesTotal)")
                    .font(.caption)
            }
            .foregroundColor(.secondary)
            if let s = model.summaryText {
                Text(s).font(.callout)
            }
        }
    }

    private var logPane: some View {
        ScrollViewReader { proxy in
            List(model.logs) { entry in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: entry.kind.icon)
                        .foregroundColor(entry.kind.color)
                    Text(entry.text)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                .id(entry.id)
            }
            .onChange(of: model.logs.count) { _ in
                if let id = model.logs.last?.id {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
        }
        .frame(minHeight: 70)
    }
}

// MARK: - Preview sheet

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
        VStack(alignment: .leading, spacing: 10) {
            Text("差分の確認").font(.headline)

            HStack(spacing: 6) {
                chip(.new)
                chip(.overwrite)
                chip(.ask)
                chip(.keepBoth)
                chip(.same)
                chip(.skip)
                if result.count(.error) > 0 { chip(.error) }
            }

            Picker("表示", selection: $filter.kind) {
                ForEach(PreviewFilter.Kind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            List(filtered) { row in
                HStack(spacing: 8) {
                    Image(systemName: row.outcome.icon).foregroundColor(row.outcome.color)
                    Text(row.path)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(row.outcome.label).font(.caption).foregroundColor(.secondary)
                    Text(ByteCountFormatter.string(fromByteCount: row.size, countStyle: .file))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 64, alignment: .trailing)
                }
            }
            .frame(minHeight: 240)

            HStack {
                Text("\(result.rows.count) ファイル")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("閉じる") { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button(result.operation == .move ? "この内容で移動開始" : "この内容でコピー開始") { onStart() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 620, height: 520)
    }

    private func chip(_ outcome: PreviewOutcome) -> some View {
        Label("\(outcome.label) \(result.count(outcome))", systemImage: outcome.icon)
            .font(.caption.weight(.medium))
            .foregroundColor(outcome.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(outcome.color.opacity(0.15)))
    }
}

// MARK: - Conflict sheet

struct ConflictSheet: View {
    let info: ConflictInfo
    let onDecide: (ConflictDecision?) -> Void
    @StateObject private var choice = ConflictChoice()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("同じ名前のファイルがあります").font(.headline)
            Text(info.relativePath)
                .font(.system(.body, design: .monospaced))
                .lineLimit(2)
                .truncationMode(.middle)

            HStack(alignment: .top, spacing: 12) {
                fileBox(title: "コピー元", snap: info.source, other: info.destination)
                fileBox(title: "コピー先（既存）", snap: info.destination, other: info.source)
            }

            if info.identical {
                Text("サイズと更新日時が同じです（同一ファイルの可能性が高い）")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Toggle("以降の競合すべてに同じ処理を適用", isOn: $choice.applyToAll)

            HStack {
                Button("中止") { onDecide(nil) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("スキップ") { decide(.skip) }
                Button("両方残す") { decide(.keepBoth) }
                Button("上書き") { decide(.overwrite) }
                Button("新しいほうだけ上書き") { decide(.overwriteIfNewer) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600)
    }

    private func decide(_ action: ConflictAction) {
        onDecide(ConflictDecision(action: action, applyToAll: choice.applyToAll))
    }

    private func fileBox(title: String, snap: FileSnapshot, other: FileSnapshot) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption).foregroundColor(.secondary)
                Text(ByteCountFormatter.string(fromByteCount: snap.size, countStyle: .file))
                    .font(.headline)
                Text(snap.modified.formatted(date: .abbreviated, time: .standard))
                if let badge = badge(snap, other) {
                    Text(badge)
                        .font(.caption.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(badge == "新しい" ? Color.green.opacity(0.25) : Color.gray.opacity(0.25))
                        .clipShape(Capsule())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private func badge(_ snap: FileSnapshot, _ other: FileSnapshot) -> String? {
        let diff = snap.modified.timeIntervalSince(other.modified)
        if diff > 2 { return "新しい" }
        if diff < -2 { return "古い" }
        return nil
    }
}
