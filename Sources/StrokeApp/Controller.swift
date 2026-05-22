// Wires MouseSource → Recognition → Matcher → Dispatch, plus the
// runtime IPC channel used by `stroke --reload` / `stroke --quit`.
//
// The Controller owns no AppKit / UI state — it's a single-purpose
// coordinator. Lives in StrokeApp (the executable) rather than Core
// because the adapter selection (real vs synthetic) and the IPC
// surface are both app-startup concerns.

import AppKit
import Foundation
import StrokeCore
import StrokeAdapterMacOS

// `@unchecked Sendable`: the only mutable state (`config`) is read
// and written exclusively on the main thread — the stroke handler
// runs on the event-tap callback (main run loop) and `reload()` is
// invoked from the main-queue DNC observer. No cross-thread access,
// so no lock is needed.
public final class Controller: @unchecked Sendable {

    private let source: MouseSource
    /// Mutated by `reload()` on the main thread. The stroke handler
    /// reads `self.config` per-event (not captured locals) so a
    /// reload takes effect on the very next stroke without
    /// reinstalling the event tap.
    private var config: StrokeConfig
    /// Last recognised gesture, for `stroke --status`.
    private var lastGesture: String?

    public init(source: MouseSource, config: StrokeConfig) {
        self.source = source
        self.config = config
    }

    public func start() {
        Log.line("controller: start — \(config.rules.count) rule(s), "
                 + "minStrokePx=\(config.minStrokePx), "
                 + "trigger=\(config.trigger.button.rawValue)")
        source.start { [weak self] event in
            self?.handle(event)
        }
        installCLIControl()
        writeStatus()
    }

    public func stop() { source.stop() }

    // MARK: - Stroke handling

    private func handle(_ event: StrokeEvent) {
        let cfg = config
        let target = event.target
        if Matcher.isExcluded(bundleID: target.bundleID, by: cfg.excludeApps) {
            Log.debug("controller: excluded app \(target.bundleID)")
            return
        }
        let dirs = Recognition.recognize(samples: event.samples,
                                          minStrokePx: cfg.minStrokePx)
        guard !dirs.isEmpty else {
            Log.debug("controller: stroke too short — ignored")
            return
        }
        let pattern = dirs.patternString
        Log.line("controller: recognised \(pattern) on \(target.bundleID)")
        let rule = Matcher.match(pattern: pattern, bundleID: target.bundleID,
                                 rules: cfg.rules)
        lastGesture = "\(pattern) on \(target.bundleID)"
            + (rule.map { " → \"\($0.name)\"" } ?? " (no rule)")
        writeStatus()
        guard let rule else {
            Log.debug("controller: no rule matched \(pattern) / \(target.bundleID)")
            return
        }
        Log.line("controller: → rule \"\(rule.name)\"")
        Dispatch.execute(rule.action, on: target)
    }

    // MARK: - Reload

    /// Re-read `~/.config/stroke/config.toml` and swap the in-memory
    /// rules + excludes. Trigger and `minStrokePx` are not swapped
    /// live — those are baked into the running event tap; logging
    /// flags them so the user knows a full restart is needed.
    public func reload() {
        let new = StrokeConfig.load()
        let oldRules = config.rules.count, newRules = new.rules.count
        if new.trigger != config.trigger
            || new.minStrokePx != config.minStrokePx {
            Log.line("controller: reload — trigger / minStrokePx "
                     + "changed in config; full restart required to "
                     + "apply (event tap won't pick them up live)")
        }
        config = new
        Log.line("controller: reload — \(oldRules) → \(newRules) rule(s)")
        writeStatus()
    }

    // MARK: - Status file (for `stroke --status`)

    private func writeStatus() {
        let s = """
        pid=\(ProcessInfo.processInfo.processIdentifier)
        rules=\(config.rules.count)
        trigger=\(config.trigger.button.rawValue)
        min-stroke-px=\(config.minStrokePx)
        max-stroke-ms=\(config.maxStrokeMs)
        overlay=\(config.overlayEnabled ? "on" : "off")
        last=\(lastGesture ?? "(none yet)")
        """
        try? s.write(toFile: statusPath, atomically: true, encoding: .utf8)
    }

    // MARK: - CLI ↔ daemon IPC

    private func installCLIControl() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(
            forName: .init(controlNotificationName),
            object: nil, queue: .main
        ) { [weak self] note in
            let cmd = (note.object as? String) ?? ""
            // queue:.main delivers on the main thread but Swift 6
            // doesn't infer @MainActor on the closure — `NSApp` is
            // main-isolated, so wrap explicitly. Same workaround
            // facet uses in `installCLIControl`.
            MainActor.assumeIsolated {
                Log.line("ipc: cmd=\(cmd)")
                switch cmd {
                case "quit":   NSApp.terminate(nil)
                case "reload": self?.reload()
                default:
                    Log.line("ipc: unknown command \"\(cmd)\" — ignored")
                }
            }
        }
    }
}
