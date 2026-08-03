import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Bindings from a modifier-click on a Dock icon to an action.
///
/// Rebuilt from a two-pane list-and-table editor, which was the wrong shape for the data.
/// A `Table` forces the two halves of one binding apart: the action sat in an editable
/// cell while the trigger was read-only text, so changing a trigger meant selecting a row
/// and then hunting through a strip of loose controls beneath the table. It also left
/// empty placeholder rows striping the bottom of the pane whenever a scope had few
/// bindings.
///
/// What the user actually has is a short list of rules per target. So each rule is one
/// self-contained row that reads as a sentence — *do this, when I do that* — and every
/// part of it is editable in place.
struct DockItemsPane: View {
    @State private var store = DockShortcutStore.shared
    @State private var isChoosingApp = false

    var body: some View {
        Form {
            ForEach($store.scopes) { $scope in
                Section {
                    if scope.shortcuts.isEmpty {
                        emptyRow(for: $scope)
                    } else {
                        ForEach($scope.shortcuts) { $shortcut in
                            ShortcutRow(shortcut: $shortcut,
                                        isShadowed: Self.isShadowed($shortcut.wrappedValue,
                                                                    in: scope.shortcuts)) {
                                scope.shortcuts.removeAll { $0.id == shortcut.id }
                            }
                        }
                    }
                    addRow(for: $scope)
                } header: {
                    header(for: scope)
                } footer: {
                    if scope.isAnyItem {
                        Text("Applies to every Dock icon unless an app below overrides it.")
                    }
                }
            }

            Section {
                Button {
                    isChoosingApp = true
                } label: {
                    Label("Add an app…", systemImage: "plus")
                }
            } footer: {
                Text("Give one app its own bindings when it should behave differently from the rest.")
            }
        }
        .fileImporter(isPresented: $isChoosingApp,
                      allowedContentTypes: [.application]) { result in
            if case .success(let url) = result { addScope(for: url) }
        }
    }

    // MARK: Section header

    private func header(for scope: DockShortcutScope) -> some View {
        HStack(spacing: 7) {
            icon(for: scope)
                .frame(width: 16, height: 16)
            if scope.isAnyItem {
                Text("Any Dock Item")
            } else {
                Text(scope.displayName)
            }
            Spacer()
            if !scope.isAnyItem {
                Button {
                    store.scopes.removeAll { $0.id == scope.id }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(Text("Remove this app"))
                .accessibilityLabel(Text("Remove this app"))
            }
        }
    }

    @ViewBuilder
    private func icon(for scope: DockShortcutScope) -> some View {
        if scope.isAnyItem {
            Image(systemName: "square.grid.3x2.fill")
                .foregroundStyle(.secondary)
        } else if let bundleID = scope.bundleIdentifier,
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
        } else {
            Image(systemName: "questionmark.app.dashed")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Rows

    private func emptyRow(for scope: Binding<DockShortcutScope>) -> some View {
        Text("No bindings yet.")
            .foregroundStyle(.secondary)
    }

    private func addRow(for scope: Binding<DockShortcutScope>) -> some View {
        Button {
            let taken = Set(scope.wrappedValue.shortcuts.map { Trigger($0) })
            scope.wrappedValue.shortcuts.append(
                DockShortcut(action: .showAllWindows,
                             modifiers: Self.freeTrigger(avoiding: taken).modifiers,
                             button: Self.freeTrigger(avoiding: taken).button))
        } label: {
            Label("Add a binding", systemImage: "plus.circle")
        }
        .buttonStyle(.borderless)
    }

    /// A trigger nothing in this scope is using yet.
    ///
    /// Only one binding per trigger can ever run — the lookup takes the first match — so
    /// handing every new row the same default made clicking "add" produce a row that
    /// silently did nothing. Offering a free combination instead means the common case is
    /// a binding that works the moment it appears.
    private static func freeTrigger(avoiding taken: Set<Trigger>) -> Trigger {
        let candidates: [Trigger] = [
            Trigger(modifiers: [.option], button: .left),
            Trigger(modifiers: [.shift], button: .left),
            Trigger(modifiers: [.control], button: .left),
            Trigger(modifiers: [], button: .middle),
            Trigger(modifiers: [.command], button: .left),
            Trigger(modifiers: [.control, .option], button: .left),
            Trigger(modifiers: [.option], button: .middle),
            Trigger(modifiers: [.shift], button: .middle),
            Trigger(modifiers: [.control, .option, .command], button: .left),
        ]
        return candidates.first { !taken.contains($0) }
            ?? Trigger(modifiers: [.option], button: .left)
    }

    /// Whether an earlier binding in the same scope already claims this trigger.
    private static func isShadowed(_ shortcut: DockShortcut,
                                   in shortcuts: [DockShortcut]) -> Bool {
        guard let index = shortcuts.firstIndex(where: { $0.id == shortcut.id }) else { return false }
        let trigger = Trigger(shortcut)
        return shortcuts.prefix(index).contains { Trigger($0) == trigger }
    }

    // MARK: Mutation

    private func addScope(for url: URL) {
        guard let bundle = Bundle(url: url),
              let identifier = bundle.bundleIdentifier,
              !store.scopes.contains(where: { $0.bundleIdentifier == identifier })
        else { return }

        let name = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
        store.scopes.append(DockShortcutScope(bundleIdentifier: identifier,
                                              displayName: name,
                                              shortcuts: []))
    }
}

/// One binding, editable in place.
///
/// Laid out as a sentence rather than a pair of table cells: the action comes first
/// because it is what the user is looking for, then the trigger that invokes it. Both are
/// live controls, so there is no select-then-edit-elsewhere step.
private struct ShortcutRow: View {
    @Binding var shortcut: DockShortcut
    /// True when an earlier binding claims the same trigger, so this one never runs.
    let isShadowed: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Picker("", selection: $shortcut.action) {
                ForEach(DockAction.allCases) { action in
                    Text(action.title).tag(action)
                }
            }
            .labelsHidden()
            .fixedSize()

            Text("when")
                .foregroundStyle(.secondary)

            ModifierPicker(combo: $shortcut.modifiers)

            Picker("", selection: $shortcut.button) {
                ForEach(DockMouseButton.allCases) { button in
                    Text(button.title).tag(button)
                }
            }
            .labelsHidden()
            .fixedSize()

            if isShadowed {
                // A dead row is otherwise indistinguishable from a working one: it looks
                // configured, and clicking its trigger runs the binding above instead.
                Label {
                    Text("Never runs — the binding above uses the same trigger")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.callout)
                .foregroundStyle(.orange)
                .labelStyle(.titleAndIcon)
            }

            Spacer(minLength: 0)

            Button(action: onDelete) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(Text("Remove this binding"))
            .accessibilityLabel(Text("Remove this binding"))
        }
    }
}

/// The part of a binding that decides whether two of them collide.
///
/// Only the trigger matters: `DockShortcutStore.action(forBundle:modifiers:button:)`
/// returns the first shortcut whose modifiers and button match, so a second binding on
/// the same trigger can never run whatever action it names.
struct Trigger: Hashable {
    let modifiers: ModifierCombo
    let button: DockMouseButton

    init(modifiers: ModifierCombo, button: DockMouseButton) {
        self.modifiers = modifiers
        self.button = button
    }

    init(_ shortcut: DockShortcut) {
        self.init(modifiers: shortcut.modifiers, button: shortcut.button)
    }
}
