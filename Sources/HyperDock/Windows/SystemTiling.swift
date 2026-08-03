import AppKit
import Foundation

/// macOS's own drag-to-edge window tiling.
///
/// This exists because two snapping systems on one gesture is worse than either alone.
/// macOS 26 tiles a plain title-bar drag by itself, and HyperDock's edge snapping runs on
/// the modifier drag — so with both on, the same flick can land a window differently
/// depending on which one reacted first, which is exactly the "sometimes it works" feeling
/// that makes a snapping feature untrustworthy.
///
/// Like `DockTweaks`, this writes into a preference domain that is not ours and outlives
/// the app, so it is only touched on an explicit change and is put back when HyperDock's
/// own snapping is turned off. Nothing is written unless the value actually differs.
@MainActor
enum SystemTiling {
    private static let domain = "com.apple.WindowManager"
    private static let snapshotKey = "systemTilingOriginalValues.v1"
    private static let migrationKey = "systemTilingOwnershipMigration.v2"
    /// True only after `WindowManager` has installed its event tap successfully.
    private static var managerAvailable = false

    /// The two keys that govern the edge-drag gesture: one for the left and right edges,
    /// one for dragging to the top to fill the screen. Both belong to the same gesture,
    /// so they are turned off and restored together.
    private static let keys = ["EnableTilingByEdgeDrag", "EnableTopTilingByEdgeDrag"]

    /// Matches the system tiling to HyperDock's own setting: while HyperDock snaps on a
    /// drag, macOS should not.
    static func apply() {
        let shouldDisable = shouldDisable(
            hyperDockDisabled: Preferences.shared.disabled,
            snapEnabled: Preferences.shared.snapOnDragToEdge,
            managerAvailable: managerAvailable
        )
        if shouldDisable {
            disable()
        } else {
            restore()
        }
    }

    /// Updates ownership from the actual event-tap result, not merely from TCC state.
    static func setManagerAvailable(_ available: Bool) {
        managerAvailable = available
        apply()
    }

    /// HyperDock owns the edge-drag gesture only while both the app and its snap feature
    /// are enabled. This pure policy is kept separate from the external defaults write.
    static func shouldDisable(hyperDockDisabled: Bool,
                              snapEnabled: Bool,
                              managerAvailable: Bool) -> Bool {
        !hyperDockDisabled && snapEnabled && managerAvailable
    }

    /// One-time upgrade from builds that overwrote these keys without recording their
    /// originals. Their documented restore behaviour was to remove the keys, so an
    /// existing installation must first enact that legacy restore before v2 captures a
    /// trustworthy snapshot. A new installation preserves every explicit system value.
    static func migrateLegacyOwnershipIfNeeded(existingInstallation: Bool) {
        guard let defaults = UserDefaults(suiteName: domain) else { return }
        migrateLegacyOwnershipIfNeeded(existingInstallation: existingInstallation,
                                       externalDefaults: defaults,
                                       snapshotStore: .standard)
    }

    static func migrateLegacyOwnershipIfNeeded(existingInstallation: Bool,
                                                externalDefaults: UserDefaults,
                                                snapshotStore: UserDefaults) {
        guard !snapshotStore.bool(forKey: migrationKey) else { return }
        if existingInstallation {
            for key in keys { externalDefaults.removeObject(forKey: key) }
            snapshotStore.removeObject(forKey: snapshotKey)
        }
        snapshotStore.set(true, forKey: migrationKey)
    }

    /// Restores the values captured before HyperDock took ownership. Called when
    /// HyperDock is switched off or exits, so the user's own choice is preserved.
    static func restore() {
        guard let defaults = UserDefaults(suiteName: domain) else { return }
        restoreOriginalValues(in: defaults, snapshotStore: .standard)
    }

    static func restoreOriginalValues(in defaults: UserDefaults,
                                      snapshotStore: UserDefaults) {
        guard let data = snapshotStore.data(forKey: snapshotKey),
              let original = try? JSONDecoder().decode([String: Bool].self, from: data)
        else { return }

        for key in keys {
            if let value = original[key] {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        snapshotStore.removeObject(forKey: snapshotKey)
    }

    private static func disable() {
        guard let defaults = UserDefaults(suiteName: domain) else { return }

        // Capture only once. The snapshot survives a crash and is consumed when the
        // feature is disabled or the app exits, restoring the user's value rather than
        // assuming Apple's default was their choice.
        captureOriginalValuesIfNeeded(from: defaults, snapshotStore: .standard)

        for key in keys {
            let current = defaults.object(forKey: key) as? Bool
            guard current != false else { continue }
            defaults.set(false, forKey: key)
        }
    }

    static func captureOriginalValuesIfNeeded(from defaults: UserDefaults,
                                              snapshotStore: UserDefaults) {
        guard snapshotStore.data(forKey: snapshotKey) == nil else { return }
        var original: [String: Bool] = [:]
        for key in keys {
            if let value = defaults.object(forKey: key) as? Bool {
                original[key] = value
            }
        }
        if let data = try? JSONEncoder().encode(original) {
            snapshotStore.set(data, forKey: snapshotKey)
        }
    }
}
