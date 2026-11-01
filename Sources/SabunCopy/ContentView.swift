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

/// 競合ダイアログ内のチェック状態（@State マクロを避けるため ObservableObject で持つ）
final class ConflictChoice: ObservableObject {
    @Published var applyToAll = false
}

/// 差分プレビューの表示フィルタ
final class PreviewFilter: ObservableObject {
    enum Kind: String, CaseIterable, Identifiable {
        case all, new, changed, identical
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "すべて"
            case .new: return "新規"
            case .changed: return "差分あり"
            case .identical: return "同一"
            }
        }
    }
    @Published var kind: Kind = .all
}

struct ContentView: View {
    @ObservedObject private var model = CopyModel.shared

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                sourcePane
                destinationPane
            }
            optionsPane
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
        .padding(16)
        .frame(minWidth: 780, minHeight: 760)
        .sheet(item: $model.pending) { req in
            ConflictSheet(info: req.info) { decision in
                model.resolve(decision)
            }
            .interactiveDismissDisabled()
        }
    }

    // MARK: Panes

    private var sourcePane: some View {
        GroupBox("コピー元（ファイル・フォルダ）") {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                        .foregroundColor(model.srcTargeted ? .accentColor : .secondary)
                    if model.sources.isEmpty {
                        Text("ここにドラッグ&ドロップ\n（Finderの右クリックからも追加できます）")
                            .multilineTextAlignment(.center)
                            .foregroundColor(.secondary)
                    } else {
                        List(model.sources, id: \.self) { url in
                            Label(url.lastPathComponent,
                                  systemImage: isExistingDirectory(url) ? "folder" : "doc")
                        }
                        .listStyle(.plain)
                        .padding(4)
                    }
                }
                .frame(height: 150)
                .dropDestination(for: URL.self) { urls, _ in
                    model.addSources(urls)
                    return true
                } isTargeted: { model.srcTargeted = $0 }

                HStack {
                    Button("追加…") {
                        model.addSources(pickURLs(files: true, multiple: true,
                                                  message: "コピーするファイル・フォルダを選択"))
                    }
                    Button("クリア") { model.clearSources() }
                        .disabled(model.sources.isEmpty)
                }
            }
            .padding(4)
        }
        .disabled(model.busy)
    }

    private var destinationPane: some View {
        GroupBox("コピー先（フォルダ）") {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                        .foregroundColor(model.dstTargeted ? .accentColor : .secondary)
                    if let dest = model.destination {
                        VStack(spacing: 4) {
                            Image(systemName: "folder.fill").font(.title)
                            Text(dest.lastPathComponent).font(.headline)
                            Text(dest.path)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                        .padding(8)
                    } else {
                        Text("ここにフォルダをドラッグ&ドロップ")
                            .foregroundColor(.secondary)
                    }
                }
                .frame(height: 150)
                .dropDestination(for: URL.self) { urls, _ in
                    if let dir = urls.first(where: isExistingDirectory) {
                        model.setDestination(dir)
                        return true
                    }
                    return false
                } isTargeted: { model.dstTargeted = $0 }

                HStack(spacing: 8) {
                    Button("選択…") {
                        if let url = pickURLs(files: false, multiple: false,
                                              message: "コピー先のフォルダを選択").first {
                            model.setDestination(url)
                        }
                    }
                    destinationMenu
                    if let dest = model.destination {
                        Button {
                            model.toggleFavorite(dest)
                        } label: {
                            Image(systemName: model.isFavorite(dest) ? "star.fill" : "star")
                                .foregroundColor(model.isFavorite(dest) ? .yellow : .secondary)
                        }
                        .buttonStyle(.borderless)
                        .help(model.isFavorite(dest) ? "お気に入りから外す" : "お気に入りに追加")
                    }
                }
            }
            .padding(4)
        }
        .disabled(model.busy)
    }

    private var existingFavorites: [URL] { model.favoriteFolders.filter(isExistingDirectory) }
    private var existingRecents: [URL] { model.recentFolders.filter(isExistingDirectory) }

    private func tildePath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private var destinationMenu: some View {
        Menu("最近・お気に入り") {
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
        }
        .fixedSize()
    }

    private var optionsPane: some View {
        GroupBox("設定") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    Picker("操作", selection: $model.operation) {
                        ForEach(OperationMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)

                    Picker("比較基準", selection: $model.compare) {
                        ForEach(CompareMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .frame(width: 260)

                    Toggle("同一ファイルは自動スキップ", isOn: $model.skipIdentical)
                }
                Text(model.compare.detail)
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(spacing: 16) {
                    Picker("競合時の動作", selection: $model.policy) {
                        ForEach(PolicyChoice.allCases) { choice in
                            Text(choice.label).tag(choice)
                        }
                    }
                    .frame(width: 300)

                    Toggle("コピー後にSHA-256で照合", isOn: Binding(
                        get: { model.verify || model.operation == .move },
                        set: { model.verify = $0 }
                    ))
                    .disabled(model.operation == .move)
                }

                Toggle("すべての処理が終わったらウインドウを自動で閉じる", isOn: $model.autoCloseWhenDone)
                Text("エラーや中止のときは閉じません。ウインドウを閉じるとアプリも終了します。")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if model.operation == .move {
                    Text("移動：コピーして内容を照合したあと、移動元をゴミ箱へ入れます（スキップしたファイルは移動元に残ります）。")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
            .padding(4)
        }
        .disabled(model.busy)
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            if model.isAnalyzing {
                ProgressView().controlSize(.small)
                Text("差分を解析中… \(model.analyzeDone) / \(model.analyzeTotal)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if model.busy {
                Button("中止", role: .destructive) { model.cancel() }
            } else {
                Button("差分を確認") { model.analyze() }
                    .disabled(!model.canStart)
                Button(model.operation == .move ? "移動開始" : "コピー開始") { model.start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canStart)
            }
        }
    }

    private var progressPane: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: model.progress.fraction)
            HStack {
                Text(model.progress.current)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("\(model.progress.filesDone) / \(model.progress.filesTotal) ファイル")
            }
            .font(.caption)
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
                    Image(systemName: icon(for: entry.kind))
                        .foregroundColor(color(for: entry.kind))
                    Text(entry.text)
                        .font(.system(.caption, design: .monospaced))
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
        .frame(minHeight: 160)
    }

    private func icon(for kind: LogKind) -> String {
        switch kind {
        case .copied: return "plus.circle"
        case .overwritten: return "arrow.triangle.2.circlepath"
        case .renamed: return "doc.on.doc"
        case .skipped: return "forward.circle"
        case .error: return "exclamationmark.triangle.fill"
        case .info: return "info.circle"
        }
    }

    private func color(for kind: LogKind) -> Color {
        switch kind {
        case .copied: return .green
        case .overwritten: return .orange
        case .renamed: return .blue
        case .skipped: return .secondary
        case .error: return .red
        case .info: return .secondary
        }
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
            return result.rows.filter { $0.status == .new }
        case .identical:
            return result.rows.filter { $0.status == .identical }
        case .changed:
            return result.rows.filter {
                $0.status == .srcNewer || $0.status == .dstNewer
                    || $0.status == .differ || $0.status == .error
            }
        }
    }

    private var changedCount: Int {
        result.count(.srcNewer) + result.count(.dstNewer) + result.count(.differ)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("差分の確認").font(.headline)
            Text("比較基準：\(result.compare.label)　／　\(result.rows.count) ファイル")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                chip("新規", result.count(.new), .green)
                chip("コピー元が新しい", result.count(.srcNewer), .orange)
                chip("コピー先が新しい", result.count(.dstNewer), .red)
                chip("内容が異なる", result.count(.differ), .purple)
                chip("同一", result.count(.identical), .gray)
                if result.count(.error) > 0 {
                    chip("エラー", result.count(.error), .red)
                }
            }

            Picker("表示", selection: $filter.kind) {
                ForEach(PreviewFilter.Kind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            List(filtered) { row in
                HStack(spacing: 8) {
                    Image(systemName: icon(row.status)).foregroundColor(tint(row.status))
                    Text(row.path)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(label(row.status)).font(.caption).foregroundColor(.secondary)
                    Text(ByteCountFormatter.string(fromByteCount: row.size, countStyle: .file))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 70, alignment: .trailing)
                }
            }
            .frame(minHeight: 260)

            Text(summaryLine)
                .font(.callout)

            HStack {
                Spacer()
                Button("閉じる") { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button(result.operation == .move ? "この内容で移動開始" : "この内容でコピー開始") { onStart() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 720, height: 600)
    }

    private var summaryLine: String {
        let identicalNote = result.skipIdentical ? "スキップします" : "競合として扱います"
        return "新規 \(result.count(.new)) 件はそのまま\(result.operation.label)、同一 \(result.count(.identical)) 件は\(identicalNote)。差分あり \(changedCount) 件は「\(result.policyLabel)」で処理します。"
    }

    private func chip(_ title: String, _ count: Int, _ color: Color) -> some View {
        Text("\(title) \(count)")
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.22))
            .clipShape(Capsule())
    }

    private func label(_ s: PreviewStatus) -> String {
        switch s {
        case .new: return "新規"
        case .identical: return "同一"
        case .srcNewer: return "コピー元が新しい"
        case .dstNewer: return "コピー先が新しい"
        case .differ: return "内容が異なる"
        case .error: return "エラー"
        }
    }

    private func icon(_ s: PreviewStatus) -> String {
        switch s {
        case .new: return "plus.circle"
        case .identical: return "equal.circle"
        case .srcNewer: return "arrow.up.circle"
        case .dstNewer: return "arrow.down.circle"
        case .differ: return "exclamationmark.circle"
        case .error: return "xmark.octagon"
        }
    }

    private func tint(_ s: PreviewStatus) -> Color {
        switch s {
        case .new: return .green
        case .identical: return .secondary
        case .srcNewer: return .orange
        case .dstNewer: return .red
        case .differ: return .purple
        case .error: return .red
        }
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
                Text("比較基準「\(info.compareLabel)」では同一です")
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
