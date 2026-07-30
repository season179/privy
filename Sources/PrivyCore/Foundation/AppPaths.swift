import Foundation

// Canonical filesystem locations for Privy. W1 owns this; the W5 composition root
// constructs a `StorageLayout` here and ensures the directories exist before the store
// or any writer touches them. See docs/m1/plan.md ("Store").

/// Application-support paths for Privy. A caseless enum namespace: no instances.
public enum AppPaths {
    /// `~/Library/Application Support/Privy`.
    public static var defaultRoot: URL {
        // `applicationSupportDirectory` resolves to ~/Library/Application Support.
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("Privy", isDirectory: true)
    }

    /// The production layout rooted at `~/Library/Application Support/Privy` with
    /// `privy.sqlite` and `Audio/` beneath it.
    public static func productionLayout() -> StorageLayout {
        layout(rootedAt: defaultRoot)
    }

    /// Builds a `StorageLayout` rooted at `root`: `<root>/privy.sqlite` and
    /// `<root>/Audio/`. Used by tests with a temporary root.
    public static func layout(rootedAt root: URL) -> StorageLayout {
        StorageLayout(
            rootDirectory: root,
            databaseURL: root.appendingPathComponent("privy.sqlite", isDirectory: false),
            audioDirectory: root.appendingPathComponent("Audio", isDirectory: true)
        )
    }

    /// Creates the root and audio directories if absent. Idempotent and safe to call
    /// repeatedly (startup runs it before migrating and before opening any writer).
    @discardableResult
    public static func ensureDirectoriesExist(_ layout: StorageLayout) throws -> StorageLayout {
        let fm = FileManager.default
        try fm.createDirectory(at: layout.rootDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: layout.audioDirectory, withIntermediateDirectories: true)
        return layout
    }
}
