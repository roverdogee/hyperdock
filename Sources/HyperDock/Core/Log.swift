import OSLog

/// Diagnostic logging.
///
/// Routed through `os.Logger` rather than `print` so it can be read from a running,
/// `open`-launched app — which is the only way to observe real permission behaviour,
/// since a binary started from a shell inherits the terminal's TCC grants instead of
/// its own.
///
/// Read it with:
///     log stream --predicate 'subsystem == "com.hyperdock.HyperDock"' --level debug
/// `nonisolated` so it can be called from the AX queue, the window-index actor and the
/// thumbnail actor — under `-default-isolation=MainActor` these would otherwise be
/// main-actor properties and unreachable from any of them.
nonisolated enum Log {
    private static let subsystem = "com.hyperdock.HyperDock"

    static let dock = Logger(subsystem: subsystem, category: "dock")
    static let windows = Logger(subsystem: subsystem, category: "windows")
    static let thumbnails = Logger(subsystem: subsystem, category: "thumbnails")
    static let permissions = Logger(subsystem: subsystem, category: "permissions")
}
