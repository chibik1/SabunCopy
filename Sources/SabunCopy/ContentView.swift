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

// MARK: - Status presentation（色だけで伝えない：アイコン＋言葉）

private extension PreviewStatus {
    var icon: String {
        switch self {
        case .new: return "plus.circle"
        case .identical: return "equal.circle"
        case .srcNewer: return "arrow.up.circle"
        case .dstNewer: return "arrow.down.circle"
        case .differ: return "exclamationmark.circle"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    var label: String {
        switch self {
        case .new: return "新規"
        case .identical: return "同一"
        case .srcNewer: return "コピー元が新しい"
        case .dstNewer: return "コピー先が新しい"
        case .differ: return "内容が異なる"
        case .error: return "エラー"
        }
    }

    var color: Color {
        switch self {
        case .new: return DS.statusNew
        case .identical: return DS.statusSame
        case .srcNewer: return DS.statusNewer
        case .dstNewer: return DS.statusDanger
        case .differ: return DS.statusDiffer
        case .error: return DS.statusDanger
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
        case .copied: return DS.statusNew
        case .overwritten: return DS.statusNewer
        case .renamed: return DS.accent
        case .skipped: return DS.statusSame
        case .error: return DS.statusDanger
        case .info: return DS.inkMuted
        }
    }
}

// MARK: - Main window

struct ContentView: View {
    @ObservedObject private var model = CopyModel.shared

    var body: some View {
        VStack(spacing: DS.space3) {
            HStack(alignment: .top, spacing: DS.space3) {
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
        .padding(DS.space4)
        .frame(minWidth: 780, minHeight: 760)
        .foregroundColor(DS.ink)
        .background(DS.window.ignoresSafeArea())
        .sheet(item: $model.pending) { req in
            ConflictSheet(info: req.info) { decision in
                model.resolve(decision)
            }
            .interactiveDismissDisabled()
        }
    }

    // MARK: Source / destination

    private var sourcePane: some View {
        DSPane(title: "コピー元（ファイル・フォルダ）") {
            DSDropZone(isTargeted: model.srcTargeted, isEmpty: model.sources.isEmpty, height: 150) {
                if model.sources.isEmpty {
                    Text("ここにドラッグ&ドロップ\n（Finderの右クリックからも追加できます）")
                        .font(DSFont.body)
                        .multilineTextAlignment(.center)
                        .foregroundColor(DS.inkMuted)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(model.sources, id: \.self) { url in
                                HStack(spacing: DS.space2) {
                                    Image(systemName: isExistingDirectory(url) ? "folder" : "doc")
                                        .foregroundColor(DS.inkMuted)
                                    Text(url.lastPathComponent)
                                        .font(DSFont.body)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, DS.space2)
                                .frame(height: DS.controlHeight)
                            }
                        }
                        .padding(DS.space1)
                    }
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                model.addSources(urls)
                return true
            } isTargeted: { model.srcTargeted = $0 }

            HStack(spacing: DS.space2) {
                Button("追加…") {
                    model.addSources(pickURLs(files: true, multiple: true,
                                              message: "コピーするファイル・フォルダを選択"))
                }
                .buttonStyle(DSButtonStyle(kind: .secondary))

                Button("クリア") { model.clearSources() }
                    .buttonStyle(DSButtonStyle(kind: .secondary))
                    .disabled(model.sources.isEmpty)
            }
        }
        .disabled(model.busy)
    }

    private var destinationPane: some View {
        DSPane(title: "コピー先（フォルダ）") {
            DSDropZone(isTargeted: model.dstTargeted, isEmpty: model.destination == nil, height: 150) {
                if let dest = model.destination {
                    VStack(spacing: DS.space1) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 22))
                            .foregroundColor(DS.accent)
                        Text(dest.lastPathComponent)
                            .font(DSFont.headline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(tildePath(dest))
                            .font(DSFont.caption)
                            .foregroundColor(DS.inkMuted)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    .padding(DS.space2)
                } else {
                    Text("ここにフォルダをドラッグ&ドロップ")
                        .font(DSFont.body)
                        .foregroundColor(DS.inkMuted)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                if let dir = urls.first(where: isExistingDirectory) {
                    model.setDestination(dir)
                    return true
                }
                return false
            } isTargeted: { model.dstTargeted = $0 }

            HStack(spacing: DS.space2) {
                Button("選択…") {
                    if let url = pickURLs(files: false, multiple: false,
                                          message: "コピー先のフォルダを選択").first {
                        model.setDestination(url)
                    }
                }
                .buttonStyle(DSButtonStyle(kind: .secondary))

                destinationMenu

                if let dest = model.destination {
                    let favorite = model.isFavorite(dest)
                    Button {
                        model.toggleFavorite(dest)
                    } label: {
                        Image(systemName: favorite ? "star.fill" : "star")
                            .font(.system(size: 13))
                            .foregroundColor(favorite ? DS.accent : DS.inkMuted)
                            .frame(width: DS.controlHeight, height: DS.controlHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(favorite ? "お気に入りから外す" : "お気に入りに追加")
                    .accessibilityLabel(favorite ? "お気に入りから外す" : "お気に入りに追加")
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
            DSMenuLabel(text: "最近・お気に入り")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: Options

    private func labeled<V: View>(_ title: String, @ViewBuilder _ content: () -> V) -> some View {
        HStack(spacing: DS.space2) {
            Text(title).font(DSFont.body)
            content()
        }
    }

    private var optionsPane: some View {
        DSPane(title: "設定") {
            VStack(alignment: .leading, spacing: DS.space2) {
                HStack(spacing: DS.space4) {
                    labeled("操作") {
                        DSSegmented(options: OperationMode.allCases,
                                    selection: $model.operation,
                                    label: { $0.label })
                    }
                    labeled("比較基準") {
                        DSPopUp(options: CompareMode.allCases,
                                selection: $model.compare,
                                width: 190,
                                label: { $0.label })
                    }
                    Toggle("同一ファイルは自動スキップ", isOn: $model.skipIdentical)
                        .toggleStyle(DSCheckboxStyle())
                }
                Text(model.compare.detail)
                    .font(DSFont.caption)
                    .foregroundColor(DS.inkMuted)

                HStack(spacing: DS.space4) {
                    labeled("競合時の動作") {
                        DSPopUp(options: PolicyChoice.allCases,
                                selection: $model.policy,
                                width: 190,
                                label: { $0.label })
                    }
                    Toggle("コピー後にSHA-256で照合", isOn: Binding(
                        get: { model.verify || model.operation == .move },
                        set: { model.verify = $0 }
                    ))
                    .toggleStyle(DSCheckboxStyle())
                    .disabled(model.operation == .move)
                }

                Toggle("すべての処理が終わったらウインドウを自動で閉じる", isOn: $model.autoCloseWhenDone)
                    .toggleStyle(DSCheckboxStyle())
                Text("エラーや中止のときは閉じません。ウインドウを閉じるとアプリも終了します。")
                    .font(DSFont.caption)
                    .foregroundColor(DS.inkMuted)

                if model.operation == .move {
                    HStack(spacing: DS.space1) {
                        Image(systemName: "arrow.right.circle")
                        Text("移動：コピーして内容を照合したあと、移動元をゴミ箱へ入れます（スキップしたファイルは移動元に残ります）。")
                    }
                    .font(DSFont.caption)
                    .foregroundColor(DS.statusNewer)
                }
            }
        }
        .disabled(model.busy)
    }

    // MARK: Actions / progress / log

    private var actionRow: some View {
        HStack(spacing: DS.space2) {
            if model.isAnalyzing {
                ProgressView().controlSize(.small)
                Text("差分を解析中… \(model.analyzeDone) / \(model.analyzeTotal)")
                    .font(DSFont.caption)
                    .foregroundColor(DS.inkMuted)
            }
            Spacer()
            if model.busy {
                Button("中止") { model.cancel() }
                    .buttonStyle(DSButtonStyle(kind: .danger))
            } else {
                Button("差分を確認") { model.analyze() }
                    .buttonStyle(DSButtonStyle(kind: .secondary))
                    .disabled(!model.canStart)
                Button(model.operation == .move ? "移動開始" : "コピー開始") { model.start() }
                    .buttonStyle(DSButtonStyle(kind: .primary, large: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canStart)
            }
        }
    }

    private var progressPane: some View {
        VStack(alignment: .leading, spacing: DS.space1) {
            ProgressView(value: model.progress.fraction)
                .progressViewStyle(.linear)
                .tint(DS.accent)
            HStack {
                Text(model.progress.current)
                    .font(DSFont.monoCaption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("\(model.progress.filesDone) / \(model.progress.filesTotal) ファイル")
                    .font(DSFont.caption)
            }
            .foregroundColor(DS.inkMuted)
            if let s = model.summaryText {
                Text(s)
                    .font(DSFont.callout)
            }
        }
    }

    private var logPane: some View {
        DSWell {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.logs.enumerated()), id: \.element.id) { index, entry in
                            HStack(alignment: .top, spacing: DS.space2) {
                                Image(systemName: entry.kind.icon)
                                    .font(DSFont.caption)
                                    .foregroundColor(entry.kind.color)
                                    .frame(width: 14)
                                Text(entry.text)
                                    .font(DSFont.monoCaption)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, DS.space2)
                            .padding(.vertical, 3)
                            .background(index % 2 == 1 ? DS.rowAlt : Color.clear)
                            .id(entry.id)
                        }
                    }
                }
                .onChange(of: model.logs.count) { _ in
                    if let id = model.logs.last?.id {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
        }
        .frame(minHeight: 160)
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
        DSSheet(width: 720, height: 600) {
            VStack(alignment: .leading, spacing: DS.space3) {
                Text("差分の確認").font(DSFont.title)
                Text("比較基準：\(result.compare.label)　／　\(result.rows.count) ファイル")
                    .font(DSFont.caption)
                    .foregroundColor(DS.inkMuted)

                HStack(spacing: DS.space2) {
                    chip(.new)
                    chip(.srcNewer)
                    chip(.dstNewer)
                    chip(.differ)
                    chip(.identical)
                    if result.count(.error) > 0 { chip(.error) }
                }

                DSSegmented(options: PreviewFilter.Kind.allCases,
                            selection: $filter.kind,
                            label: { $0.label })

                DSWell {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(filtered.enumerated()), id: \.element.id) { index, row in
                                HStack(spacing: DS.space2) {
                                    Image(systemName: row.status.icon)
                                        .foregroundColor(row.status.color)
                                        .frame(width: 16)
                                    Text(row.path)
                                        .font(DSFont.monoCaption)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: DS.space2)
                                    Text(row.status.label)
                                        .font(DSFont.caption)
                                        .foregroundColor(row.status.color)
                                    Text(ByteCountFormatter.string(fromByteCount: row.size, countStyle: .file))
                                        .font(DSFont.caption)
                                        .foregroundColor(DS.inkMuted)
                                        .frame(width: 72, alignment: .trailing)
                                }
                                .padding(.horizontal, DS.space2)
                                .frame(height: DS.controlHeight)
                                .background(index % 2 == 1 ? DS.rowAlt : Color.clear)
                            }
                        }
                    }
                }
                .frame(minHeight: 260)

                Text(summaryLine)
                    .font(DSFont.callout)

                HStack(spacing: DS.space2) {
                    Spacer()
                    Button("閉じる") { onClose() }
                        .buttonStyle(DSButtonStyle(kind: .secondary))
                        .keyboardShortcut(.cancelAction)
                    Button(result.operation == .move ? "この内容で移動開始" : "この内容でコピー開始") { onStart() }
                        .buttonStyle(DSButtonStyle(kind: .primary, large: true))
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private var summaryLine: String {
        let identicalNote = result.skipIdentical ? "スキップします" : "競合として扱います"
        return "新規 \(result.count(.new)) 件はそのまま\(result.operation.label)、同一 \(result.count(.identical)) 件は\(identicalNote)。差分あり \(changedCount) 件は「\(result.policyLabel)」で処理します。"
    }

    private func chip(_ status: PreviewStatus) -> some View {
        DSChip(icon: status.icon,
               text: "\(status.label) \(result.count(status))",
               color: status.color)
    }
}

// MARK: - Conflict sheet

struct ConflictSheet: View {
    let info: ConflictInfo
    let onDecide: (ConflictDecision?) -> Void
    @StateObject private var choice = ConflictChoice()

    var body: some View {
        DSSheet(width: 600) {
            VStack(alignment: .leading, spacing: DS.space3) {
                Text("同じ名前のファイルがあります").font(DSFont.title)
                Text(info.relativePath)
                    .font(DSFont.monoBody)
                    .lineLimit(2)
                    .truncationMode(.middle)

                HStack(alignment: .top, spacing: DS.space3) {
                    fileBox(title: "コピー元", snap: info.source, other: info.destination)
                    fileBox(title: "コピー先（既存）", snap: info.destination, other: info.source)
                }

                if info.identical {
                    HStack(spacing: DS.space1) {
                        Image(systemName: "equal.circle")
                        Text("比較基準「\(info.compareLabel)」では同一です")
                    }
                    .font(DSFont.caption)
                    .foregroundColor(DS.statusSame)
                }

                Toggle("以降の競合すべてに同じ処理を適用", isOn: $choice.applyToAll)
                    .toggleStyle(DSCheckboxStyle())

                HStack(spacing: DS.space2) {
                    Button("中止") { onDecide(nil) }
                        .buttonStyle(DSButtonStyle(kind: .secondary))
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("スキップ") { decide(.skip) }
                        .buttonStyle(DSButtonStyle(kind: .secondary))
                    Button("両方残す") { decide(.keepBoth) }
                        .buttonStyle(DSButtonStyle(kind: .secondary))
                    Button("上書き") { decide(.overwrite) }
                        .buttonStyle(DSButtonStyle(kind: .secondary))
                    Button("新しいほうだけ上書き") { decide(.overwriteIfNewer) }
                        .buttonStyle(DSButtonStyle(kind: .primary, large: true))
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func decide(_ action: ConflictAction) {
        onDecide(ConflictDecision(action: action, applyToAll: choice.applyToAll))
    }

    private func fileBox(title: String, snap: FileSnapshot, other: FileSnapshot) -> some View {
        VStack(alignment: .leading, spacing: DS.space1) {
            Text(title)
                .font(DSFont.caption)
                .foregroundColor(DS.inkMuted)
            Text(ByteCountFormatter.string(fromByteCount: snap.size, countStyle: .file))
                .font(DSFont.headline)
            Text(snap.modified.formatted(date: .abbreviated, time: .standard))
                .font(DSFont.body)
            if let badge = badge(snap, other) {
                DSChip(icon: badge.icon, text: badge.text, color: badge.color)
            }
        }
        .padding(DS.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.radiusMd).fill(DS.field))
    }

    private func badge(_ snap: FileSnapshot, _ other: FileSnapshot) -> (icon: String, text: String, color: Color)? {
        let diff = snap.modified.timeIntervalSince(other.modified)
        if diff > 2 { return ("arrow.up.circle", "新しい", DS.statusNewer) }
        if diff < -2 { return ("arrow.down.circle", "古い", DS.statusSame) }
        return nil
    }
}
