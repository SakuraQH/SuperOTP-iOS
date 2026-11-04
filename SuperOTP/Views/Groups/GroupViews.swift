import SuperOTPKit
import SwiftUI

private let maxGroupName = 24

private struct GroupRoute: Hashable {
    let uid: String
}

/// Group management: create, rename, delete and reorder groups; open one to manage members.
struct GroupsView: View {
    @EnvironmentObject private var vault: VaultStore
    @State private var creating = false
    @State private var pickFor: OtpCategory?
    @State private var deleting: OtpCategory?

    private var groups: [OtpCategory] { sortGroups(vault.categories) }

    var body: some View {
        let groups = self.groups
        let groupUids = Set(groups.map(\.uid))
        let ungrouped = vault.accounts.filter { isUngrouped($0, groupUids) }.count
        List {
            if !groups.isEmpty {
                Section {
                    ForEach(groups) { group in
                        NavigationLink(value: GroupRoute(uid: group.uid)) {
                            HStack(spacing: 12) {
                                SettingsIcon(symbol: "folder.fill", color: .orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(group.title).lineLimit(1)
                                    Text("\(vault.accounts.filter { $0.categoryUids.contains(group.uid) }.count) accounts")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button { deleting = group } label: { Label("Delete", systemImage: "trash") }
                                .tint(.red)
                        }
                    }
                    .onMove { from, to in
                        var ids = groups.map(\.id)
                        ids.move(fromOffsets: from, toOffset: to)
                        vault.reorderGroups(ids: ids)
                    }
                } header: {
                    Text("Shown as tabs on the home screen in this order")
                } footer: {
                    if ungrouped > 0 {
                        Text("\(ungrouped) accounts have no group and appear under “Other”.")
                    } else {
                        Text("Every account is in a group.")
                    }
                }
            }
        }
        .overlay {
            if groups.isEmpty {
                ContentUnavailableView {
                    Label("No Groups Yet", systemImage: "folder")
                } description: {
                    Text("Groups appear as tabs on the home screen. New groups come first; accounts without a group are listed under “Other”, which hides itself once every account has a group.")
                } actions: {
                    Button("New Group") { creating = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle("Groups")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { creating = true } label: { Image(systemName: "folder.badge.plus") }
                    .accessibilityLabel(Text("New Group"))
            }
            if groups.count > 1 {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
            }
        }
        .navigationDestination(for: GroupRoute.self) { route in
            GroupDetailView(groupUid: route.uid, startPicking: false)
        }
        .sheet(isPresented: $creating) {
            GroupNameSheet(editing: nil) { title in
                let group = vault.addGroup(title: title)
                guard !vault.accounts.isEmpty else { return }
                // Offer to fill the new group once the name sheet has gone.
                Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    pickFor = group
                }
            }
        }
        .sheet(item: $pickFor) { group in
            AccountPickerSheet(group: group)
        }
        .confirmationDialog(
            Text("Delete “\(deleting?.title ?? "")”?"),
            isPresented: Binding(isPresent: $deleting),
            titleVisibility: .visible,
            presenting: deleting
        ) { group in
            Button("Delete Group", role: .destructive) { vault.deleteGroup(id: group.id) }
        } message: { _ in
            Text("The accounts in it are kept and move to “Other”.")
        }
    }
}

/// One group's members: remove with a swipe, add in bulk, rename or delete the group.
struct GroupDetailView: View {
    let groupUid: String
    let startPicking: Bool

    @EnvironmentObject private var vault: VaultStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var picking = false
    @State private var renaming = false
    @State private var deleting = false
    @State private var didStart = false

    private var group: OtpCategory? { vault.categories.first { $0.uid == groupUid } }

    var body: some View {
        Group {
            if let group {
                content(group)
            } else {
                ContentUnavailableView("Group Deleted", systemImage: "folder.badge.minus")
            }
        }
        .onChange(of: group == nil) { _, gone in
            if gone { dismiss() }
        }
    }

    private func content(_ group: OtpCategory) -> some View {
        let sorted = sortAccounts(vault.accounts, settings.sort)
        let members = sorted.filter { $0.categoryUids.contains(groupUid) }
        let hasCandidates = sorted.contains { !$0.categoryUids.contains(groupUid) }
        return List {
            if !members.isEmpty {
                Section {
                    ForEach(members) { account in
                        AccountSummaryRow(account: account, display: settings.display)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button {
                                    vault.removeFromGroup(ids: [account.id], groupUid: groupUid)
                                } label: {
                                    Label("Remove", systemImage: "folder.badge.minus")
                                }
                                .tint(.orange)
                            }
                    }
                } footer: {
                    Text("Swipe left on an account to take it out of this group.")
                }
            }
        }
        .overlay {
            if members.isEmpty {
                ContentUnavailableView {
                    Label("No Accounts in “\(group.title)”", systemImage: "folder")
                } description: {
                    Text(hasCandidates ? "Add existing accounts to this group in one go." : "Add an account first, then put it in this group.")
                } actions: {
                    if hasCandidates {
                        Button("Add Accounts") { picking = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !members.isEmpty && hasCandidates {
                Button {
                    picking = true
                } label: {
                    Label("Add Accounts", systemImage: "plus")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 14))
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.bar)
            }
        }
        .navigationTitle(group.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if hasCandidates {
                        Button { picking = true } label: { Label("Add Accounts", systemImage: "plus") }
                    }
                    Button { renaming = true } label: { Label("Rename", systemImage: "pencil") }
                    Button(role: .destructive) { deleting = true } label: { Label("Delete Group", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel(Text("More"))
            }
        }
        .onAppear {
            if startPicking && !didStart && hasCandidates { picking = true }
            didStart = true
        }
        .sheet(isPresented: $picking) {
            AccountPickerSheet(group: group)
        }
        .sheet(isPresented: $renaming) {
            GroupNameSheet(editing: group) { title in vault.renameGroup(id: group.id, title: title) }
        }
        .confirmationDialog(Text("Delete “\(group.title)”?"), isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete Group", role: .destructive) { vault.deleteGroup(id: group.id) }
        } message: {
            Text("The accounts in it are kept and move to “Other”.")
        }
    }
}

/// Compact account row for group screens.
struct AccountSummaryRow: View {
    let account: OtpAccount
    let display: DisplayMode
    var detail: String?

    var body: some View {
        let labels = displayLabels(account, display)
        HStack(spacing: 12) {
            AccountIcon(account: account, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(labels.title.isEmpty ? "—" : labels.title)
                    .lineLimit(1)
                if let subtitle = detail ?? labels.subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

/// Bulk-add picker: ungrouped accounts first; each row shows the group it would leave.
struct AccountPickerSheet: View {
    let group: OtpCategory

    @EnvironmentObject private var vault: VaultStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var toasts: ToastCenter
    @Environment(\.dismiss) private var dismiss
    @State private var chosen = Set<Int>()
    @State private var query = ""

    var body: some View {
        let groupUids = Set(vault.categories.map(\.uid))
        let outside = sortAccounts(vault.accounts, settings.sort).filter { !$0.categoryUids.contains(group.uid) }
        let candidates = outside.filter { isUngrouped($0, groupUids) } + outside.filter { !isUngrouped($0, groupUids) }
        let shown = filterAccounts(candidates, query)
        let movesOthers = candidates.contains { chosen.contains($0.id) && !isUngrouped($0, groupUids) }
        NavigationStack {
            List(selection: $chosen) {
                Section {
                    ForEach(shown) { account in
                        let labels = displayLabels(account, .both)
                        AccountSummaryRow(
                            account: account,
                            display: settings.display,
                            detail: (labels.subtitle.map { $0 + " · " } ?? "") + (groupOf(account, vault.categories)?.title ?? String(localized: "No Group"))
                        )
                    }
                } footer: {
                    if movesOthers {
                        Text("Accounts that are already in another group will move here.")
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .overlay {
                if shown.isEmpty {
                    if query.isEmpty {
                        ContentUnavailableView("All Accounts Are in This Group", systemImage: "checkmark.circle")
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
            .navigationTitle(Text("Add to “\(group.title)”"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        vault.moveToGroup(ids: Array(chosen), groupUid: group.uid)
                        Haptics.success()
                        toasts.show(String(localized: "Moved to “\(group.title)”"), style: .success)
                        dismiss()
                    } label: {
                        if chosen.isEmpty { Text("Add") } else { Text("Add (\(chosen.count))") }
                    }
                    .fontWeight(.semibold)
                    .disabled(chosen.isEmpty)
                }
                ToolbarItem(placement: .bottomBar) {
                    let ids = Set(shown.map(\.id))
                    let all = !ids.isEmpty && ids.isSubset(of: chosen)
                    Button(all ? "Deselect All" : "Select All") {
                        if all { chosen.subtract(ids) } else { chosen.formUnion(ids) }
                    }
                    .disabled(ids.isEmpty)
                }
            }
        }
    }
}

/// Create (`editing == nil`) or rename a group; blocks blank and duplicate names.
struct GroupNameSheet: View {
    let editing: OtpCategory?
    let onSave: (String) -> Void

    @EnvironmentObject private var vault: VaultStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @FocusState private var focused: Bool

    private var valid: String? {
        validGroupName(title, vault.categories, editingId: editing?.id, reserved: [String(localized: "Other"), "Other", "其他"])
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Group Name", text: $title)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit(save)
                        .onChange(of: title) { _, value in
                            if value.count > maxGroupName { title = String(value.prefix(maxGroupName)) }
                        }
                } footer: {
                    if !title.isBlank && valid == nil {
                        Text("A group with this name already exists.").foregroundStyle(.red)
                    } else {
                        Text("For example Work, Personal or Games.")
                    }
                }
            }
            .navigationTitle(editing == nil ? Text("New Group") : Text("Rename Group"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .fontWeight(.semibold)
                        .disabled(valid == nil)
                }
            }
            .onAppear {
                title = editing?.title ?? ""
                focused = true
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        guard let name = valid else { return }
        onSave(name)
        dismiss()
    }
}

/// Moves accounts to a group (or out of all groups); can create a new group on the way.
struct MoveToGroupSheet: View {
    let ids: [Int]
    /// Called after moving; carries the uid of a group created here so the home tab can follow.
    let onDone: (String?) -> Void

    @EnvironmentObject private var vault: VaultStore
    @EnvironmentObject private var toasts: ToastCenter
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false

    var body: some View {
        let moving = vault.accounts.filter { ids.contains($0.id) }
        let current = Set(moving.map { groupOf($0, vault.categories)?.uid ?? otherTabKey })
        let shared = current.count == 1 ? current.first : nil
        NavigationStack {
            List {
                Section {
                    ForEach(sortGroups(vault.categories)) { group in
                        row(title: group.title, symbol: "folder.fill", color: .orange, checked: shared == group.uid) {
                            move(to: group.uid, name: group.title, created: false)
                        }
                    }
                    row(title: String(localized: "No Group"), symbol: "folder.badge.minus", color: .gray, checked: shared == otherTabKey) {
                        move(to: nil, name: String(localized: "Other"), created: false)
                    }
                } footer: {
                    Text("An account belongs to one group at a time.")
                }
                Section {
                    Button {
                        creating = true
                    } label: {
                        Label("New Group…", systemImage: "folder.badge.plus")
                    }
                }
            }
            .navigationTitle(ids.count == 1 ? Text("Move to Group") : Text("Move \(ids.count) Accounts"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $creating) {
                GroupNameSheet(editing: nil) { title in
                    let group = vault.addGroup(title: title)
                    // Let the name sheet finish dismissing before closing this one.
                    Task {
                        try? await Task.sleep(for: .milliseconds(350))
                        move(to: group.uid, name: group.title, created: true)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(title: String, symbol: String, color: Color, checked: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                SettingsIcon(symbol: symbol, color: color)
                Text(title).foregroundStyle(.primary).lineLimit(1)
                Spacer()
                if checked {
                    Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
                }
            }
        }
    }

    private func move(to groupUid: String?, name: String, created: Bool) {
        vault.moveToGroup(ids: ids, groupUid: groupUid)
        Haptics.success()
        toasts.show(String(localized: "Moved to “\(name)”"), style: .success)
        onDone(created ? groupUid : nil)
        dismiss()
    }
}
