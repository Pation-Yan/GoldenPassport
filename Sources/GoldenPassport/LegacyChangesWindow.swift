import AppKit
import GoldenPassportCore
import SwiftUI

/// Offers to import accounts that 0.1.x added or changed after the migration, e.g. after
/// rollback.sh, and lists the ones it deleted (I6). Closing the window means "later".
final class LegacyChangesWindowController: HostedWindowController {
    private let changes: () -> LegacyChanges?
    private let onImport: (Set<String>) -> Void
    private let onAcknowledge: () -> Void

    init(changes: @escaping () -> LegacyChanges?, onImport: @escaping (Set<String>) -> Void,
         onAcknowledge: @escaping () -> Void) {
        self.changes = changes
        self.onImport = onImport
        self.onAcknowledge = onAcknowledge
    }

    override var title: String { String(localized: "旧版本的改动") }

    override func makeContent(close: @escaping () -> Void) -> AnyView {
        guard let changes = changes() else { return AnyView(EmptyView()) }
        return AnyView(LegacyChangesView(changes: changes, onImport: { [onImport] names in
            close()
            onImport(names)
        }, onAcknowledge: { [onAcknowledge] in
            close()
            onAcknowledge()
        }, onLater: close))
    }
}

struct LegacyChangesView: View {
    let changes: LegacyChanges
    let onImport: (Set<String>) -> Void
    let onAcknowledge: () -> Void
    let onLater: () -> Void

    @State private var selected: Set<String>
    @State private var confirmingIgnore = false

    init(changes: LegacyChanges, onImport: @escaping (Set<String>) -> Void,
         onAcknowledge: @escaping () -> Void, onLater: @escaping () -> Void) {
        self.changes = changes
        self.onImport = onImport
        self.onAcknowledge = onAcknowledge
        self.onLater = onLater
        _selected = State(initialValue: Set(changes.imports.map(\.name)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("回退期间，旧版本改动过账号").font(.headline)
            if !changes.imports.isEmpty {
                Text("你回退到 GoldenPassport 0.1.x 期间，它的数据文件 gp.secrets 有以下改动。新版本不会自动同步这些改动，请选择要导入的账号。")
                    .fixedSize(horizontal: false, vertical: true)
                importList
                if changes.imports.contains(where: { $0.importName != $0.name }) {
                    Text("导入后，请确认原来的账号和带「(0.1.x)」的账号哪个能生成正确的验证码，再删掉另一个。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !changes.removed.isEmpty {
                Text("以下账号在 0.1.x 里被删除了，但新版本里仍然保留。如果不再需要，可以在「管理」窗口里删除：\(changes.removed.joined(separator: String(localized: "、")))")
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if !changes.imports.isEmpty {
                    Button("忽略这些改动") { confirmingIgnore = true }
                }
                Spacer()
                Button("稍后", action: onLater).keyboardShortcut(.cancelAction)
                if changes.imports.isEmpty {
                    Button("知道了", action: onAcknowledge).keyboardShortcut(.defaultAction)
                } else {
                    Button("导入所选") { onImport(selected) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(selected.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .confirmationDialog("忽略这些改动？", isPresented: $confirmingIgnore) {
            Button("忽略", role: .destructive, action: onAcknowledge)
        } message: {
            Text("以后不会再提示这些改动。它们仍保存在 gp.secrets 里，但运行 cleanup.sh 清理之后就无法再导入了。")
        }
    }

    /// Account names only: the window never shows a URL or a secret.
    @ViewBuilder private var importList: some View {
        let rows = VStack(alignment: .leading, spacing: 8) {
            ForEach(changes.imports, id: \.name) { change in
                Toggle(isOn: Binding(get: { selected.contains(change.name) }, set: { isOn in
                    if isOn { selected.insert(change.name) } else { selected.remove(change.name) }
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(change.name)
                        Group {
                            if change.kind == .added {
                                Text("0.1.x 里新增")
                            } else {
                                Text("0.1.x 里改过 URL")
                            }
                            if change.importName != change.name {
                                Text("将导入为「\(change.importName)」，不会覆盖同名的现有账号")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if changes.imports.count > 6 {
            ScrollView { rows }.frame(height: 300)
        } else {
            rows
        }
    }
}
