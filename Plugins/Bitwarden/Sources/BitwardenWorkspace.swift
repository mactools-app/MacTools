import MacToolsPluginKit
import SwiftUI

struct BitwardenWorkspace: View {
    @ObservedObject var vault: BitwardenVault
    let bundle: Bundle

    @State private var server = ""
    @State private var email = ""
    @State private var password = ""
    @State private var method = "0"
    @State private var code = ""
    @State private var query = ""
    @State private var filter: Filter = .all
    @State private var selectedID: String?
    @State private var editor: BitwardenDraft?
    @State private var removing: Removal?
    @State private var folderEditor: FolderEditor?
    @State private var generator = false
    @State private var signOut = false
    @State private var revealed: Set<String> = []
    @State private var length = 20
    @State private var digits = true
    @State private var symbols = true

    private enum Filter: Hashable {
        case all, favorites, trash, kind(BitwardenItemKind), folder(String), collection(String)
    }

    private struct FolderEditor: Identifiable {
        let id = UUID()
        var folder: BitwardenGroup?
        var name: String
    }

    private struct Removal {
        let item: BitwardenItem
        let permanent: Bool

        var titleKey: String { permanent ? "vault.deletePermanently" : "vault.moveToTrash" }
    }

    private var selection: BitwardenItem? { results.first { $0.id == selectedID } }

    private var results: [BitwardenItem] {
        (filter == .trash ? vault.trash : vault.items).filter { item in
            switch filter {
            case .favorites where item.favorite != true: return false
            case let .kind(kind) where item.kind != kind: return false
            case let .folder(id) where item.folderId != id: return false
            case let .collection(id) where item.collectionIds?.contains(id) != true: return false
            default: break
            }
            return item.matches(query.trimmingCharacters(in: .whitespacesAndNewlines))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = vault.error, editor == nil, folderEditor == nil, !generator {
                Label { Text(error, tableName: "Vault", bundle: bundle) } icon: { Image(systemName: "exclamationmark.circle") }
                    .foregroundStyle(.secondary).padding(8)
            }
            if vault.status == .unlocked { browser } else { authentication }
        }
        .frame(minHeight: 400, maxHeight: .infinity)
        .onChange(of: vault.status) { _, status in
            password = ""
            code = ""
            if status != .unlocked {
                selectedID = nil
                query = ""
                filter = .all
                editor = nil
                removing = nil
                folderEditor = nil
                generator = false
                revealed = []
            }
        }
        .onChange(of: selectedID) { _, _ in revealed = [] }
        .onChange(of: filter) { _, _ in selectedID = nil }
        .sheet(item: $editor) { draft in
            BitwardenEditor(vault: vault, bundle: bundle, draft: draft) { editor = nil }
        }
        .sheet(item: $folderEditor) { editing in folderSheet(editing) }
        .sheet(isPresented: $generator, onDismiss: { vault.generatedPassword = "" }) { generatorSheet }
        .confirmationDialog(text("vault.signOut"), isPresented: $signOut) {
            Button(role: .destructive) { Task { await vault.signOut() } } label: { text("vault.signOut") }
        }
        .confirmationDialog(text(removing?.titleKey ?? "vault.moveToTrash"), isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        ), presenting: removing) { removal in
            Button(role: .destructive) {
                Task {
                    await vault.changeTrash(removal.item, action: removal.permanent ? .deletePermanently : .move)
                    if vault.error == nil { selectedID = nil }
                }
            } label: { text(removal.titleKey) }
        } message: { removal in Text(verbatim: removal.item.name) }
    }

    private var authentication: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
                Label {
                    text("vault.\(vault.status.rawValue)")
                        .font(PluginSettingsTheme.Typography.sectionTitle)
                } icon: { Image(systemName: "lock.shield") }
                switch vault.status {
                case .checking:
                    ProgressView().controlSize(.small)
                case .unavailable, .failed:
                    if vault.status == .unavailable {
                        text("vault.installCLI")
                        Text(verbatim: "brew install bitwarden-cli").font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    button("vault.retry") { Task { await vault.refreshStatus() } }
                case .locked, .unauthenticated:
                    if vault.status == .unauthenticated {
                        TextField(label("vault.server"), text: $server).textContentType(.URL)
                        TextField(label("vault.email"), text: $email).textContentType(.emailAddress)
                    } else if let email = vault.account?.userEmail {
                        Text(verbatim: email).foregroundStyle(.secondary)
                    }
                    SecureField(label("vault.masterPassword"), text: $password)
                        .onSubmit(submit)
                    if vault.status == .unauthenticated {
                        Picker(selection: $method) {
                            text("vault.authenticator").tag("0")
                            text("vault.emailCode").tag("1")
                            text("vault.yubiKey").tag("3")
                        } label: { text("vault.twoStep") }
                        SecureField(label("vault.verificationCode"), text: $code)
                        if method == "1" { text("vault.emailHelp").foregroundStyle(.secondary) }
                    }
                    HStack {
                        button(vault.status == .locked ? "vault.unlock" : "vault.signIn", action: submit)
                            .keyboardShortcut(.defaultAction)
                            .disabled(!canAuthenticate)
                        if vault.status == .locked {
                            button("vault.signOut") { signOut = true }.disabled(vault.busy)
                        }
                        if vault.busy { ProgressView().controlSize(.small) }
                    }
                case .unlocked: EmptyView()
                }
            }
            .textFieldStyle(.roundedBorder)
            .padding(PluginSettingsTheme.Spacing.section)
            .frame(maxWidth: 460, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var canAuthenticate: Bool {
        !vault.busy && !password.isEmpty && (vault.status == .locked || email.contains("@"))
    }

    private func submit() {
        guard canAuthenticate else { return }
        let enteredPassword = password
        let enteredCode = code
        password = ""
        code = ""
        Task {
            await vault.authenticate(email: email.trimmingCharacters(in: .whitespaces), password: enteredPassword,
                                     server: server.trimmingCharacters(in: .whitespaces), method: method, code: enteredCode)
        }
    }

    private var browser: some View {
        VStack(spacing: 0) {
            HStack {
                TextField(label("vault.search"), text: $query).textFieldStyle(.roundedBorder)
                    .onChange(of: query) { _, _ in vault.touch() }
                Spacer()
                if vault.busy { ProgressView().controlSize(.small) }
                button("vault.new") { editor = BitwardenDraft() }.disabled(vault.busy)
                button("vault.lock") { vault.lock() }
                Menu {
                    button("vault.sync") { Task { await vault.refresh(sync: true) } }.disabled(vault.busy)
                    button("vault.generator") { generator = true }.disabled(vault.busy)
                    button("vault.newFolder") { folderEditor = FolderEditor(name: "") }.disabled(vault.busy)
                    if case let .folder(id) = filter, let folder = vault.folders.first(where: { $0.id == id }) {
                        button("vault.renameFolder") { folderEditor = FolderEditor(folder: folder, name: folder.name) }
                            .disabled(vault.busy)
                    }
                    Divider()
                    button("vault.signOut") { signOut = true }.disabled(vault.busy)
                } label: { Image(systemName: "ellipsis.circle").accessibilityLabel(text("vault.more")) }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(10)
            Divider()
            HSplitView {
                sidebar.frame(minWidth: 135, idealWidth: 150, maxWidth: 220)
                List(results, selection: $selectedID) { item in
                    Label { Text(verbatim: item.name) } icon: { Image(systemName: item.kind?.icon ?? "doc") }
                        .tag(item.id)
                }
                .listStyle(.inset)
                .overlay { if results.isEmpty && !vault.busy { text("vault.noItems").foregroundStyle(.secondary) } }
                .frame(minWidth: 150, idealWidth: 210)
                details.frame(minWidth: 205, idealWidth: 350, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: selectedID) {
            guard let selection, filter != .trash else { return }
            await vault.read(selection)
        }
    }

    private var sidebar: some View {
        List(selection: Binding<Filter?>(get: { filter }, set: { if let value = $0 { filter = value; vault.touch() } })) {
            sidebarLabel("vault.all", "tray.full", .all)
            sidebarLabel("vault.favorites", "star", .favorites)
            sidebarLabel("vault.trash", "trash", .trash)
            Section { ForEach(BitwardenItemKind.allCases) { kind in
                Label { text(kind.titleKey) } icon: { Image(systemName: kind.icon) }
                    .tag(Filter.kind(kind))
            } } header: { text("vault.categories") }
            if !vault.folders.isEmpty {
                Section { ForEach(vault.folders) { folder in
                    Label { Text(verbatim: folder.name) } icon: { Image(systemName: "folder") }.tag(Filter.folder(folder.id))
                } } header: { text("vault.folders") }
            }
            if !vault.collections.isEmpty {
                Section { ForEach(vault.collections) { collection in
                    Label { Text(verbatim: collection.name) } icon: { Image(systemName: "square.stack") }
                        .tag(Filter.collection(collection.id))
                } } header: { text("vault.collections") }
            }
        }.listStyle(.sidebar)
    }

    private func sidebarLabel(_ key: String, _ icon: String, _ value: Filter) -> some View {
        Label { text(key) } icon: { Image(systemName: icon) }.tag(value)
    }

    private var details: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
                if let item = selection {
                    Text(verbatim: item.name).font(PluginSettingsTheme.Typography.sectionTitle)
                    if filter == .trash {
                        if item.organizationId == nil {
                            HStack {
                                button("vault.restore") { Task { await vault.changeTrash(item, action: .restore) } }
                                Button(role: .destructive) { removing = Removal(item: item, permanent: true) } label: {
                                    text("vault.deletePermanently")
                                }
                            }.disabled(vault.busy)
                        } else {
                            text("vault.organizationReadOnly").foregroundStyle(.secondary)
                        }
                    } else if (item.reprompt ?? 0) != 0 || item.kind == nil {
                        text("vault.protectedItem").foregroundStyle(.secondary)
                    } else if let detail = vault.detail, detail.itemID == item.id {
                        HStack {
                            if item.organizationId == nil {
                                button("vault.edit") { editor = detail }.disabled(vault.busy)
                                button("vault.moveToTrash") { removing = Removal(item: item, permanent: false) }.disabled(vault.busy)
                            } else {
                                text("vault.organizationReadOnly").foregroundStyle(.secondary)
                            }
                        }
                        ForEach(detail.kind.fields, id: \.self) { field in
                            if let value = detail.fields[field], !value.isEmpty {
                                valueRow("field.\(field)", value: value, concealed: BitwardenItemKind.secretFields.contains(field))
                            }
                        }
                        if detail.kind == .login, detail.fields["totp"]?.isEmpty == false {
                            button("vault.copyCode") { Task { await vault.copyVerificationCode(for: item) } }
                                .disabled(vault.busy)
                        }
                        if !detail.urls.isEmpty { valueRow("field.urls", value: detail.urls, concealed: false) }
                        if !detail.notes.isEmpty { valueRow("field.notes", value: detail.notes, concealed: false) }
                        ForEach(detail.customFields.filter(\.isEditable)) { field in
                            valueRow("custom.\(field.id)", value: field.value, concealed: field.kind == .hidden,
                                     title: Text(verbatim: field.name))
                        }
                    } else if vault.busy {
                        ProgressView().controlSize(.small)
                    } else {
                        button("vault.retry") { Task { await vault.read(item) } }
                    }
                } else {
                    text("vault.selectItem").foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(PluginSettingsTheme.Spacing.section)
        }
    }

    private func valueRow(_ key: String, value: String, concealed: Bool, title: Text? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            (title ?? text(key)).font(PluginSettingsTheme.Typography.emphasizedRowTitle)
            Text(verbatim: concealed && !revealed.contains(key) ? "••••••••" : value)
            HStack {
                button("vault.copy") { vault.copy(value) }
                if concealed {
                    button(revealed.contains(key) ? "vault.hide" : "vault.reveal") {
                        vault.touch()
                        if revealed.contains(key) { revealed.remove(key) } else { revealed.insert(key) }
                    }
                }
            }
        }
    }

    private func folderSheet(_ editing: FolderEditor) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            text(editing.folder == nil ? "vault.newFolder" : "vault.renameFolder").font(.headline)
            TextField(label("field.name"), text: Binding(
                get: { folderEditor?.name ?? "" }, set: { folderEditor?.name = $0; vault.touch() }
            )).textFieldStyle(.roundedBorder)
            if let error = vault.error { Text(error, tableName: "Vault", bundle: bundle).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                button("vault.cancel") { folderEditor = nil }.keyboardShortcut(.cancelAction)
                button("vault.save") {
                    guard let name = folderEditor?.name.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return }
                    Task {
                        await vault.saveFolder(name, group: editing.folder)
                        if vault.error == nil { folderEditor = nil }
                    }
                }.keyboardShortcut(.defaultAction)
                    .disabled(vault.busy || folderEditor?.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false)
            }
        }.padding(20).frame(width: 360)
    }

    private var generatorSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            text("vault.generator").font(.headline)
            Stepper(value: $length, in: 8...128) {
                HStack { text("vault.length"); Text(length, format: .number).monospacedDigit() }
            }
            Toggle(isOn: $digits) { text("vault.digits") }
            Toggle(isOn: $symbols) { text("vault.symbols") }
            if !vault.generatedPassword.isEmpty {
                Text(verbatim: vault.generatedPassword).font(.system(.body, design: .monospaced))
            }
            if let error = vault.error { Text(error, tableName: "Vault", bundle: bundle).foregroundStyle(.secondary) }
            HStack {
                button("vault.done") { generator = false }.keyboardShortcut(.cancelAction)
                Spacer()
                button("vault.copy") { vault.copy(vault.generatedPassword) }.disabled(vault.generatedPassword.isEmpty)
                button("vault.generate") { Task { await vault.generate(length: length, digits: digits, symbols: symbols) } }
                    .disabled(vault.busy).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 400)
    }

    private func text(_ key: String) -> Text { Text(LocalizedStringKey(key), tableName: "Vault", bundle: bundle) }

    private func label(_ key: String) -> String { bundle.localizedString(forKey: key, value: nil, table: "Vault") }

    private func button(_ key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { text(key) }
    }
}

private struct BitwardenEditor: View {
    @ObservedObject var vault: BitwardenVault
    let bundle: Bundle
    @State var draft: BitwardenDraft
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            text(draft.itemID == nil ? "vault.new" : "vault.edit").font(.headline)
            Form {
                if draft.itemID == nil {
                    Picker(selection: $draft.kind) {
                        ForEach(BitwardenItemKind.allCases) { text($0.titleKey).tag($0) }
                    } label: { text("field.type") }
                }
                TextField(label("field.name"), text: $draft.name)
                Picker(selection: $draft.folder) {
                    text("field.noFolder").tag("")
                    ForEach(vault.folders) { Text(verbatim: $0.name).tag($0.id) }
                    if !draft.folder.isEmpty, !vault.folders.contains(where: { $0.id == draft.folder }) {
                        text("field.unknownFolder").tag(draft.folder)
                    }
                } label: { text("field.folder") }
                ForEach(draft.kind.fields, id: \.self) { field in
                    let binding = Binding<String>(get: { draft.fields[field] ?? "" }, set: { draft.fields[field] = $0; vault.touch() })
                    if field == "publicKey" {
                        TextField(label("field.\(field)"), text: binding, axis: .vertical).lineLimit(2...5)
                    } else if BitwardenItemKind.secretFields.contains(field) {
                        SecureField(label("field.\(field)"), text: binding)
                    } else {
                        TextField(label("field.\(field)"), text: binding)
                    }
                }
                if draft.kind == .login {
                    TextField(label("field.urls"), text: $draft.urls, axis: .vertical).lineLimit(2...5)
                }
                TextField(label("field.notes"), text: $draft.notes, axis: .vertical).lineLimit(2...6)
                Toggle(isOn: $draft.favorite) { text("vault.favorites") }
                Section {
                    ForEach($draft.customFields) { $field in
                        if field.isEditable {
                            TextField(label("field.name"), text: $field.name)
                            Picker(selection: $field.kind) {
                                text("field.customText").tag(BitwardenDraft.CustomField.Kind.text)
                                text("field.customHidden").tag(BitwardenDraft.CustomField.Kind.hidden)
                                text("field.customBoolean").tag(BitwardenDraft.CustomField.Kind.boolean)
                            } label: { text("field.type") }
                            switch field.kind {
                            case .text: TextField(label("field.value"), text: $field.value)
                            case .hidden: SecureField(label("field.value"), text: $field.value)
                            case .boolean:
                                Toggle(isOn: Binding(get: { field.value == "true" }, set: { field.value = $0 ? "true" : "false" })) {
                                    text("field.value")
                                }
                            case .linked: EmptyView()
                            }
                            Button(role: .destructive) {
                                let id = field.id
                                draft.customFields.removeAll { $0.id == id }
                                vault.touch()
                            } label: { text("field.removeCustom") }
                        }
                    }
                    Button {
                        draft.customFields.append(.init())
                        vault.touch()
                    } label: { text("field.addCustom") }
                } header: { text("field.customFields") }
            }.formStyle(.grouped)
            if let error = vault.error { Text(error, tableName: "Vault", bundle: bundle).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button(action: close) { text("vault.cancel") }.keyboardShortcut(.cancelAction)
                Button {
                    Task { if await vault.save(draft) { close() } }
                } label: { text("vault.save") }
                    .keyboardShortcut(.defaultAction)
                    .disabled(vault.busy || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 500, height: 530)
        .onChange(of: draft.name) { _, _ in vault.touch() }
        .onChange(of: draft.notes) { _, _ in vault.touch() }
        .onChange(of: draft.urls) { _, _ in vault.touch() }
    }

    private func text(_ key: String) -> Text { Text(LocalizedStringKey(key), tableName: "Vault", bundle: bundle) }

    private func label(_ key: String) -> String { bundle.localizedString(forKey: key, value: nil, table: "Vault") }
}
