import Foundation

// Canonical filesystem locations for Privy. W1 owns this; the W5 composition root
// resolves the production layout here and ensures the directories exist before the store
// or any writer touches them. See docs/m1/plan.md ("Store").

/// Application-support paths for Privy. A caseless enum namespace: no instances.
public enum AppPaths {
    /// Resolves `~/Library/Application Support/Privy`, throwing if Application Support
    /// cannot be located.
    ///
    /// Startup must fail visibly rather than silently fall back to a purgeable temporary
    /// directory: recording into `$TMPDIR/Privy` would make audio appear durable while
    /// macOS is free to remove it. Tests that need a throwaway root use the explicit
    /// `layout(rootedAt:)` path instead.
    public static func resolveDefaultRoot() throws -> URL {
        guard let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first else {
            throw NSError(
                domain: "Privy.AppPaths",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not resolve the Application Support directory"]
            )
        }
        return support.appendingPathComponent("Privy", isDirectory: true)
    }

    /// The production layout rooted at `~/Library/Application Support/Privy` with
    /// `privy.sqlite` and `Audio/` beneath it. Throws if the root cannot be resolved.
    public static func productionLayout() throws -> StorageLayout {
        layout(rootedAt: try resolveDefaultRoot())
    }

    /// Builds a `StorageLayout` rooted at `root`: `<root>/privy.sqlite` and `<root>/Audio/`.
    /// Intended for tests with a temporary root.
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
