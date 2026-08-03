import AppKit
import Foundation

/// Settings that adjust the system Dock itself.
///
/// These write to `com.apple.dock` and restart the Dock to take effect, which is the
/// only way to change these behaviours — they are not exposed to any API. That makes
/// them different in kind from every other preference here: the change persists in the
/// user's own Dock settings and outlives HyperDock, so each one is applied only on an
/// explicit change and is reverted when turned back off.
@MainActor
enum DockTweaks {
    private static let domain = "com.apple.dock"
    private static let snapshotKey = "dockAutohideOriginalValues.v1"
    private static let migrationKey = "dockAutohideOwnershipMigration.v2"
    private static let autohideKeys = ["autohide-delay", "autohide-time-modifier"]

    /// Migrates values owned by builds that did not save a snapshot. Their old restore
    /// contract deleted both keys, so existing installations enact that once before the
    /// exact-value snapshot scheme begins. New installs retain explicit user values.
    static func migrateLegacyOwnershipIfNeeded(existingInstallation: Bool) {
        guard let defaults else { return }
        let changed = migrateLegacyOwnershipIfNeeded(existingInstallation: existingInstallation,
                                                     externalDefaults: defaults,
                                                     snapshotStore: .standard)
        if changed, !Preferences.shared.speedUpDockAutohide { restartDock() }
    }

    @discardableResult
    static func migrateLegacyOwnershipIfNeeded(existingInstallation: Bool,
                                                externalDefaults: UserDefaults,
                                                snapshotStore: UserDefaults) -> Bool {
        guard !snapshotStore.bool(forKey: migrationKey) else { return false }
        var changed = false
        if existingInstallation {
            for key in autohideKeys where externalDefaults.object(forKey: key) != nil {
                externalDefaults.removeObject(forKey: key)
                changed = true
            }
            snapshotStore.removeObject(forKey: snapshotKey)
        }
        snapshotStore.set(true, forKey: migrationKey)
        return changed
    }

    /// Applies whatever the preferences currently say. Safe to call repeatedly: it only
    /// touches the Dock when a value actually differs from what is already set.
    static func apply() {
        // Clears the key an earlier build wrote here. The Dock never honoured it, and
        // leaving a stray entry behind in someone else's preference domain is not ours
        // to do.
        var changed = defaults?.object(forKey: "show-hidden-labels") != nil
        if changed { delete("show-hidden-labels") }
        changed = setAutohideDelay(Preferences.shared.speedUpDockAutohide) || changed
        if changed { restartDock() }
    }

    /// Removes the delay before an auto-hidden Dock reveals, and shortens the animation.
    ///
    /// Reverting restores the values captured before HyperDock took ownership, including
    /// preserving the distinction between a missing key and an explicit numeric value.
    @discardableResult
    private static func setAutohideDelay(_ speedUp: Bool) -> Bool {
        if speedUp {
            captureAutohideValuesIfNeeded()
            let delayChanged = readDouble("autohide-delay") != 0
            let animationChanged = readDouble("autohide-time-modifier") != 0.25
            if delayChanged { write("autohide-delay", value: 0.0) }
            if animationChanged { write("autohide-time-modifier", value: 0.25) }
            return delayChanged || animationChanged
        } else {
            return restoreAutohideValues()
        }
    }

    /// Restores any Dock values HyperDock currently owns.
    static func restore() {
        if restoreAutohideValues() { restartDock() }
    }

    /// Records only values HyperDock is about to replace. Missing keys stay missing in
    /// the encoded dictionary, which lets restoration distinguish them from zero.
    private static func captureAutohideValuesIfNeeded() {
        guard let defaults else { return }
        captureAutohideValuesIfNeeded(from: defaults, snapshotStore: .standard)
    }

    static func captureAutohideValuesIfNeeded(from defaults: UserDefaults,
                                              snapshotStore: UserDefaults) {
        guard snapshotStore.data(forKey: snapshotKey) == nil else { return }
        var original: [String: Double] = [:]
        for key in autohideKeys {
            if let value = defaults.object(forKey: key) as? Double { original[key] = value }
        }
        if let data = try? JSONEncoder().encode(original) {
            snapshotStore.set(data, forKey: snapshotKey)
        }
    }

    @discardableResult
    private static func restoreAutohideValues() -> Bool {
        guard let defaults else { return false }
        return restoreAutohideValues(in: defaults, snapshotStore: .standard)
    }

    @discardableResult
    static func restoreAutohideValues(in defaults: UserDefaults,
                                      snapshotStore: UserDefaults) -> Bool {
        guard let data = snapshotStore.data(forKey: snapshotKey),
              let original = try? JSONDecoder().decode([String: Double].self, from: data)
        else { return false }

        var changed = false
        for key in autohideKeys {
            if let value = original[key] {
                if (defaults.object(forKey: key) as? Double) != value {
                    defaults.set(value, forKey: key)
                    changed = true
                }
            } else if defaults.object(forKey: key) != nil {
                defaults.removeObject(forKey: key)
                changed = true
            }
        }
        snapshotStore.removeObject(forKey: snapshotKey)
        return changed
    }

    // MARK: - Defaults plumbing

    private static var defaults: UserDefaults? { UserDefaults(suiteName: domain) }

    private static func readDouble(_ key: String) -> Double? {
        defaults?.object(forKey: key) as? Double
    }

    private static func write(_ key: String, value: Any) {
        defaults?.set(value, forKey: key)
    }

    private static func delete(_ key: String) {
        defaults?.removeObject(forKey: key)
    }

    /// The Dock only reads these at launch, so it has to be restarted.
    ///
    /// `killall` rather than a graceful quit because the Dock has no quit path; launchd
    /// brings it straight back. The visible cost is a brief flicker, which is why this
    /// only runs when something actually changed.
    private static func restartDock() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Dock"]
        try? process.run()
    }
}
