import PhotosUI
import SuperOTPKit
import SwiftUI

enum HomeSheet: Identifiable {
    case settings
    case groups
    case addManual(groupUid: String?)
    case edit(Int)
    case qr(OtpAccount)
    case icon(OtpAccount)
    case move([Int])
    case group(String, pick: Bool)

    var id: String {
        switch self {
        case .settings: return "settings"
        case .groups: return "groups"
        case let .addManual(uid): return "add-\(uid ?? "")"
        case let .edit(id): return "edit-\(id)"
        case let .qr(account): return "qr-\(account.id)"
        case let .icon(account): return "icon-\(account.id)"
        case let .move(ids): return "move-" + ids.map { String($0) }.joined(separator: ",")
        case let .group(uid, pick): return "group-\(uid)-\(pick)"
        }
    }
}

private struct CopiedMark: Equatable {
    let id: Int
    let token = UUID()
}

struct HomeView: View {
    @EnvironmentObject private var vault: VaultStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var toasts: ToastCenter
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var lock: AppLock
    @StateObject private var importFlow = ImportFlow()

    @State private var query = ""
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<Int>()
    /// Account id -> TOTP time step at which its code was revealed (any value for HOTP).
    @State private var revealed: [Int: Int] = [:]
    @State private var copied: CopiedMark?
    @State private var sheet: HomeSheet?
    @State private var scanning = false
    @State private var scannedText: String?
    @State private var pickingPhoto = false
    @State private var photoItem: PhotosPickerItem?
    @State private var pendingDelete: [Int]?
    @State private var pendingLink: OtpAccount?

    private var editing: Bool { editMode.isEditing }

    var body: some View {
        NavigationStack {
            Group {
                if vault.accounts.isEmpty {
                    emptyVault
                } else {
                    accountList
                }
            }
            .navigationTitle(editing ? Text("\(selection.count) Selected") : Text("Authenticator"))
            .navigationBarTitleDisplayMode(editing ? .inline : .large)
            .toolbar { toolbarContent }
        }
        .sheet(item: $sheet) { sheet in sheetContent(sheet) }
        .fullScreenCover(isPresented: $scanning, onDismiss: {
            if let text = scannedText {
                scannedText = nil
                importFlow.openText(text, vault: vault, toasts: toasts)
            }
        }) {
            ScannerView { text in
                scannedText = text
                scanning = false
            }
        }
        .photosPicker(isPresented: $pickingPhoto, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            Task {
                if let text = await QRImageReader.decode(item) {
                    importFlow.openText(text, vault: vault, toasts: toasts)
                } else {
                    toasts.show(String(localized: "No QR code found in this picture"), style: .failure)
                }
            }
        }
        .confirmationDialog(
            deleteTitle,
            isPresented: Binding(isPresent: $pendingDelete),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { ids in
            Button("Delete", role: .destructive) {
                vault.delete(ids: ids)
                selection.subtract(ids)
                if editing && vault.accounts.isEmpty { endEditing() }
                Haptics.warning()
            }
        } message: { _ in
            Text("Make sure you can still sign in to these services another way. This can't be undone.")
        }
        .alert("Copy otpauth Link?", isPresented: Binding(isPresent: $pendingLink), presenting: pendingLink) { account in
            Button("Copy") {
                Clipboard.copy(otpauthUri(account), expiresAfter: settings.clipboardTimeout)
                toasts.show(String(localized: "Link copied"), style: .success)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The link contains the secret key. Anyone who sees it can generate your codes.")
        }
        .importFlow(importFlow)
        .onAppear(perform: consumePendingImport)
        .onChange(of: router.pendingImportText) { _, _ in consumePendingImport() }
        .onChange(of: lock.isLocked) { _, _ in consumePendingImport() }
    }

    // MARK: Lists

    private var tabs: [GroupTab] { groupTabs(vault.categories, vault.accounts) }

    /// A search looks through every group; otherwise only the selected tab is listed.
    private var currentTab: GroupTab? { query.isEmpty ? resolveTab(tabs, settings.lastTab) : nil }

    private var visibleAccounts: [OtpAccount] {
        filterAccounts(accountsInTab(sortAccounts(vault.accounts, settings.sort), currentTab, vault.categories), query)
    }

    private var accountList: some View {
        let tabs = self.tabs
        let tab = currentTab
        let visible = visibleAccounts
        let pinned = visible.filter(\.pinned)
        let others = visible.filter { !$0.pinned }
        let canReorder = settings.sort == .manual && query.isEmpty
        return List(selection: $selection) {
            if !pinned.isEmpty {
                Section {
                    rows(pinned, visible: visible, canReorder: canReorder)
                } header: {
                    Text("Pinned")
                } footer: {
                    if others.isEmpty { footer }
                }
            }
            if !others.isEmpty {
                Section {
                    rows(others, visible: visible, canReorder: canReorder)
                } header: {
                    if !pinned.isEmpty { Text("Accounts") }
                } footer: {
                    footer
                }
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.editMode, $editMode)
        .overlay {
            if visible.isEmpty { emptyResult(tab) }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !tabs.isEmpty && query.isEmpty && !editing {
                GroupChipBar(
                    tabs: tabs,
                    selectedKey: tab?.key,
                    onSelect: { key in
                        selection.removeAll()
                        settings.lastTab = key
                    },
                    onManage: { sheet = .groups }
                )
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Search \(vault.accounts.count) accounts"))
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
    }

    @ViewBuilder
    private var footer: some View {
        if !editing {
            Text(settings.tapToCopy ? "Tap a code to copy it. Touch and hold for more actions." : "Tap a code to show it. Touch and hold for more actions.")
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
        } else if settings.sort != .manual {
            Text("Choose Manual Order in the sort menu to rearrange accounts.")
        }
    }

    @ViewBuilder
    private func rows(_ list: [OtpAccount], visible: [OtpAccount], canReorder: Bool) -> some View {
        let mover: ((IndexSet, Int) -> Void)? = canReorder ? { from, to in move(list, from: from, to: to, visible: visible) } : nil
        ForEach(list) { account in
            AccountRow(
                account: account,
                display: settings.display,
                revealedMark: revealed[account.id],
                hideCodes: settings.hideCodes,
                tapToCopy: settings.tapToCopy,
                copied: copied?.id == account.id,
                editing: editing,
                onTap: { tap(account) },
                onNext: { nextCode(account) }
            )
            .contextMenu {
                if !editing { menu(for: account) }
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button { togglePin(account) } label: {
                    Label(account.pinned ? "Unpin" : "Pin", systemImage: account.pinned ? "pin.slash.fill" : "pin.fill")
                }
                .tint(.orange)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button { pendingDelete = [account.id] } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.red)
                Button { sheet = .edit(account.id) } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .tint(.gray)
            }
        }
        .onMove(perform: mover)
    }

    @ViewBuilder
    private func menu(for account: OtpAccount) -> some View {
        if !settings.tapToCopy {
            Button { copyCode(account) } label: { Label("Copy Code", systemImage: "doc.on.doc") }
        }
        Button { sheet = .edit(account.id) } label: { Label("Edit", systemImage: "pencil") }
        Button { togglePin(account) } label: {
            Label(account.pinned ? "Unpin" : "Pin", systemImage: account.pinned ? "pin.slash" : "pin")
        }
        Button { sheet = .move([account.id]) } label: { Label("Move to Group", systemImage: "folder") }
        Button { sheet = .icon(account) } label: { Label("Change Icon", systemImage: "photo") }
        Divider()
        Button { sheet = .qr(account) } label: { Label("Show QR Code", systemImage: "qrcode") }
        Button { pendingLink = account } label: { Label("Copy otpauth Link", systemImage: "link") }
        Button { startSelecting(account.id) } label: { Label("Select", systemImage: "checkmark.circle") }
        Divider()
        Button(role: .destructive) { pendingDelete = [account.id] } label: { Label("Delete", systemImage: "trash") }
    }

    // MARK: Empty states

    private var emptyVault: some View {
        ContentUnavailableView {
            Label("No Accounts Yet", systemImage: "lock.shield")
        } description: {
            Text("Scan the QR code a service shows when you turn on two-factor authentication, or add the setup key by hand.")
        } actions: {
            Button { scanning = true } label: {
                Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                    .frame(minWidth: 200)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Menu("More Ways to Add") { addMenuItems }
        }
    }

    @ViewBuilder
    private func emptyResult(_ tab: GroupTab?) -> some View {
        if !query.isEmpty {
            ContentUnavailableView.search(text: query)
        } else if let group = tab?.group {
            ContentUnavailableView {
                Label("No Accounts in “\(group.title)”", systemImage: "folder")
            } description: {
                Text("Add existing accounts to this group in one go.")
            } actions: {
                Button("Add Accounts") { sheet = .group(group.uid, pick: true) }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            ContentUnavailableView("No Accounts", systemImage: "tray")
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if editing {
            ToolbarItem(placement: .topBarLeading) {
                let ids = Set(visibleAccounts.map(\.id))
                let all = !ids.isEmpty && ids.isSubset(of: selection)
                Button(all ? "Deselect All" : "Select All") {
                    if all { selection.subtract(ids) } else { selection.formUnion(ids) }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { endEditing() }
                    .fontWeight(.semibold)
            }
            ToolbarItemGroup(placement: .bottomBar) {
                let selected = vault.accounts.filter { selection.contains($0.id) }
                let allPinned = !selected.isEmpty && selected.allSatisfy(\.pinned)
                Button(allPinned ? "Unpin" : "Pin") {
                    vault.setPinned(ids: Array(selection), !allPinned)
                    endEditing()
                }
                .disabled(selection.isEmpty)
                Spacer()
                Button("Move") { sheet = .move(Array(selection)) }
                    .disabled(selection.isEmpty)
                Spacer()
                Button("Delete", role: .destructive) { pendingDelete = Array(selection) }
                    .disabled(selection.isEmpty)
            }
        } else {
            ToolbarItem(placement: .topBarLeading) {
                Button { sheet = .settings } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel(Text("Settings"))
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !vault.accounts.isEmpty {
                    Menu {
                        Picker(selection: $settings.sort) {
                            ForEach(SortMode.allCases, id: \.self) { mode in
                                Text(mode.label).tag(mode)
                            }
                        } label: {
                            Label("Sort By", systemImage: "arrow.up.arrow.down")
                        }
                        .pickerStyle(.menu)
                        Button { startSelecting(nil) } label: { Label("Select", systemImage: "checkmark.circle") }
                        if vault.accounts.count > 1 {
                            Button {
                                settings.sort = .manual
                                startSelecting(nil)
                            } label: {
                                Label("Rearrange", systemImage: "line.3.horizontal")
                            }
                        }
                        Divider()
                        Button { sheet = .groups } label: { Label("Manage Groups", systemImage: "folder") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel(Text("More"))
                }
                Menu {
                    addMenuItems
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(Text("Add Account"))
            }
        }
    }

    @ViewBuilder
    private var addMenuItems: some View {
        Button { scanning = true } label: { Label("Scan QR Code", systemImage: "qrcode.viewfinder") }
        Button { pickingPhoto = true } label: { Label("Choose from Photos", systemImage: "photo.on.rectangle") }
        Button { pasteFromClipboard() } label: { Label("Paste from Clipboard", systemImage: "doc.on.clipboard") }
        Button { sheet = .addManual(groupUid: currentTab?.group?.uid) } label: {
            Label("Enter Manually", systemImage: "keyboard")
        }
    }

    // MARK: Sheets

    @ViewBuilder
    private func sheetContent(_ sheet: HomeSheet) -> some View {
        switch sheet {
        case .settings:
            SettingsView()
        case .groups:
            NavigationStack {
                GroupsView().doneButton()
            }
        case let .addManual(groupUid):
            EditAccountView(accountId: nil, defaultGroupUid: groupUid)
        case let .edit(id):
            EditAccountView(accountId: id, defaultGroupUid: nil)
        case let .qr(account):
            QRCodeSheet(account: account)
        case let .icon(account):
            IconPickerView(account: account)
        case let .move(ids):
            MoveToGroupSheet(ids: ids) { createdGroupUid in
                if editing { endEditing() }
                if let createdGroupUid { settings.lastTab = createdGroupUid }
            }
        case let .group(uid, pick):
            NavigationStack {
                GroupDetailView(groupUid: uid, startPicking: pick).doneButton()
            }
        }
    }

    private var deleteTitle: Text {
        let count = pendingDelete?.count ?? 0
        return count == 1 ? Text("Delete this account?") : Text("Delete \(count) accounts?")
    }

    // MARK: Actions

    private func tap(_ account: OtpAccount) {
        let now = Date()
        let hidden = settings.hideCodes && !isRevealed(account, now)
        if !settings.tapToCopy {
            if settings.hideCodes {
                if hidden { reveal(account, now) } else { revealed[account.id] = nil }
                Haptics.tap()
            }
            return
        }
        if hidden { reveal(account, now) }
        copyCode(account, now: now)
    }

    private func isRevealed(_ account: OtpAccount, _ now: Date) -> Bool {
        guard let mark = revealed[account.id] else { return false }
        return account.type != .totp || mark == timeStep(account, at: now)
    }

    private func reveal(_ account: OtpAccount, _ now: Date) {
        revealed[account.id] = account.type == .totp ? timeStep(account, at: now) : Int.min
    }

    private func copyCode(_ account: OtpAccount, now: Date = Date()) {
        guard let code = currentCode(account, at: now) else { return }
        Clipboard.copy(code, expiresAfter: settings.clipboardTimeout)
        Haptics.success()
        let mark = CopiedMark(id: account.id)
        copied = mark
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if copied == mark { copied = nil }
        }
    }

    private func nextCode(_ account: OtpAccount) {
        vault.nextHotp(id: account.id)
        reveal(account, Date())
        Haptics.tap()
    }

    private func togglePin(_ account: OtpAccount) {
        vault.setPinned(ids: [account.id], !account.pinned)
        Haptics.tap()
    }

    /// Applies a move inside one section to the full manual order.
    private func move(_ section: [OtpAccount], from: IndexSet, to: Int, visible: [OtpAccount]) {
        var ids = section.map(\.id)
        ids.move(fromOffsets: from, toOffset: to)
        let sectionIds = Set(ids)
        var reordered: [Int] = []
        var inserted = false
        for account in visible {
            if sectionIds.contains(account.id) {
                if !inserted {
                    reordered += ids
                    inserted = true
                }
            } else {
                reordered.append(account.id)
            }
        }
        let all = sortAccounts(vault.accounts, .manual).map(\.id)
        vault.reorder(ids: mergeSubsetOrder(all, reordered))
    }

    private func startSelecting(_ id: Int?) {
        query = ""
        if let id { selection = [id] } else { selection = [] }
        withAnimation { editMode = .active }
    }

    private func endEditing() {
        selection.removeAll()
        withAnimation { editMode = .inactive }
    }

    private func pasteFromClipboard() {
        guard let text = Clipboard.readText(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            toasts.show(String(localized: "The clipboard is empty"), style: .failure)
            return
        }
        importFlow.openText(text, vault: vault, toasts: toasts)
    }

    private func consumePendingImport() {
        guard let text = router.pendingImportText, !lock.isLocked, vault.state == .ready else { return }
        router.pendingImportText = nil
        if sheet != nil || scanning || importFlow.prepared != nil {
            sheet = nil
            scanning = false
            importFlow.prepared = nil
            Task {
                try? await Task.sleep(for: .milliseconds(700))
                importFlow.openText(text, vault: vault, toasts: toasts)
            }
        } else {
            importFlow.openText(text, vault: vault, toasts: toasts)
        }
    }
}

/// Group tabs under the search bar: groups in order, "Other" last, then group management.
struct GroupChipBar: View {
    let tabs: [GroupTab]
    let selectedKey: String?
    let onSelect: (String) -> Void
    let onManage: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(tabs, id: \.key) { tab in
                            Chip(
                                title: tab.group?.title ?? String(localized: "Other"),
                                selected: tab.key == selectedKey
                            ) {
                                Haptics.tap()
                                onSelect(tab.key)
                            }
                            .id(tab.key)
                        }
                    }
                    .padding(.leading, 16)
                    .padding(.trailing, 8)
                    .padding(.vertical, 8)
                }
                .onAppear {
                    if let selectedKey { proxy.scrollTo(selectedKey, anchor: .center) }
                }
                .onChange(of: selectedKey) { _, key in
                    guard let key else { return }
                    withAnimation { proxy.scrollTo(key, anchor: .center) }
                }
            }
            Button(action: onManage) {
                Image(systemName: "slider.horizontal.3")
                    .font(.body.weight(.medium))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(Text("Manage Groups"))
            .padding(.trailing, 6)
        }
        .background(Color(.systemGroupedBackground))
    }
}

extension Binding where Value == Bool {
    /// True while `source` holds a value; setting false clears it.
    init<T>(isPresent source: Binding<T?>) {
        self.init(get: { source.wrappedValue != nil }, set: { if !$0 { source.wrappedValue = nil } })
    }
}

extension View {
    /// Adds a Done button that dismisses the enclosing sheet.
    func doneButton() -> some View {
        modifier(DoneButtonModifier())
    }
}

private struct DoneButtonModifier: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}
