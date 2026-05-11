// QuickTab picker — SwiftUI implementation.
//
// Reads {"tabs":[...], "anchor":{x,y,w,h}} on stdin, renders a borderless
// floating panel anchored to the focused iTerm2 window's top-right, and on
// selection prints {"window_id","tab_id"} to stdout. Empty stdout = cancel.
//
// Pidfile: /tmp/quicktab-picker-swift.pid for parent toggle-close via SIGTERM.

import AppKit
import SwiftUI
import Combine

// MARK: - Protocol types

struct TabInfo: Decodable, Identifiable, Hashable {
    let windowId: String
    let tabId: String
    let title: String
    let tabIndex: Int
    let isActiveTab: Bool
    let isActiveWindow: Bool
    let lastActivityAt: Double?  // epoch seconds; nil if tty unreadable

    var id: String { "\(windowId)|\(tabId)" }

    /// Short relative-time string for the right-edge activity indicator.
    /// Bucketed: `< 30s` -> nil (hide), then "Nm", "Nh", "Nd", "Nw".
    var activityLabel: String? {
        guard let last = lastActivityAt else { return nil }
        let elapsed = Date().timeIntervalSince1970 - last
        if elapsed < 30 { return nil }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m" }
        if elapsed < 86_400 { return "\(Int(elapsed / 3600))h" }
        if elapsed < 7 * 86_400 { return "\(Int(elapsed / 86_400))d" }
        return "\(Int(elapsed / (7 * 86_400)))w"
    }

    enum CodingKeys: String, CodingKey {
        case windowId = "window_id"
        case tabId = "tab_id"
        case title
        case tabIndex = "tab_index"
        case isActiveTab = "is_active_tab"
        case isActiveWindow = "is_active_window"
        case lastActivityAt = "last_activity_at"
    }
}

struct AnchorRect: Decodable {
    let x: Double
    let y: Double
    let w: Double
    let h: Double
}

struct InputPayload: Decodable {
    let tabs: [TabInfo]
    let anchor: AnchorRect?
}

// MARK: - Lifecycle helpers

let pidfilePath = "/tmp/quicktab-picker.pid"
let debugLogPath = "/tmp/quicktab-debug-swift.log"

/// Verbose logs are gated by QUICKTAB_DEBUG=1 in the env. Without it the picker
/// runs silent — errors print to stderr regardless (where iTerm2's parent
/// captures and forwards them to its Console).
let debugMode = ProcessInfo.processInfo.environment["QUICKTAB_DEBUG"] == "1"

func dlog(_ msg: String, _ isError: Bool = false) {
    if !isError && !debugMode { return }
    let line = "[picker pid=\(getpid())] \(msg)\n"
    FileHandle.standardError.write(Data(line.utf8))
    if debugMode {
        if let fh = try? FileHandle(forWritingTo: URL(fileURLWithPath: debugLogPath)) {
            fh.seekToEndOfFile()
            fh.write(Data(line.utf8))
            try? fh.close()
        } else {
            try? line.write(toFile: debugLogPath, atomically: false, encoding: .utf8)
        }
    }
}

/// Always-on logging for genuine errors. Bypasses the debug gate.
func elog(_ msg: String) { dlog(msg, true) }

func writePidfile() {
    try? "\(getpid())".write(toFile: pidfilePath, atomically: true, encoding: .utf8)
}

func cleanupPidfile() {
    if let s = try? String(contentsOfFile: pidfilePath, encoding: .utf8),
       Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) == Int(getpid()) {
        try? FileManager.default.removeItem(atPath: pidfilePath)
    }
}

// MARK: - Fuzzy match

func fuzzyScore(needle: String, hay: String) -> Double {
    if needle.isEmpty { return 0 }
    let n = Array(needle.lowercased())
    let h = Array(hay.lowercased())
    var i = 0
    var lastMatch = -2
    var score: Double = 0
    let boundary: Set<Character> = [" ", "-", "_", "/", "."]
    for (j, c) in h.enumerated() {
        if i >= n.count { break }
        if c == n[i] {
            if j == lastMatch + 1 { score += 5 } else { score += 1 }
            if j == 0 { score += 8 }
            else if boundary.contains(h[j - 1]) { score += 4 }
            lastMatch = j
            i += 1
        }
    }
    if i != n.count { return -1 }
    score -= Double(h.count) * 0.05
    return score
}

// MARK: - View model

enum Row: Identifiable, Hashable {
    case header(windowIndex: Int, isActiveWindow: Bool)
    case tab(TabInfo)

    var id: String {
        switch self {
        case .header(let idx, _): return "h-\(idx)"
        case .tab(let t): return t.id
        }
    }

    var isSelectable: Bool {
        if case .tab = self { return true }
        return false
    }
}

final class PickerModel: ObservableObject {
    private(set) var tabs: [TabInfo]
    private(set) var windowOrder: [String]
    private(set) var byWindow: [String: [TabInfo]]
    private(set) var multiWindow: Bool

    @Published var query: String = ""
    @Published var rows: [Row] = []
    @Published var selectedID: String?

    init(tabs: [TabInfo]) {
        self.tabs = tabs
        var order: [String] = []
        var byWin: [String: [TabInfo]] = [:]
        for t in tabs {
            if byWin[t.windowId] == nil {
                order.append(t.windowId)
                byWin[t.windowId] = []
            }
            byWin[t.windowId]?.append(t)
        }
        self.windowOrder = order
        self.byWindow = byWin
        self.multiWindow = order.count > 1
        rebuild()
        if let active = tabs.first(where: { $0.isActiveTab }) {
            self.selectedID = active.id
        } else {
            self.selectedID = rows.first(where: { $0.isSelectable })?.id
        }
    }

    /// Remove a tab from the local model after user requested its close.
    /// Selection advances to the next available tab if the removed one was
    /// highlighted, so the user can press ⌘⌫ repeatedly to clean up a streak.
    func removeTab(_ t: TabInfo) {
        let removingSelected = (selectedID == t.id)
        // Capture current row index so we can land selection on what was
        // visually below the removed row.
        let removedRowIdx = rows.firstIndex { $0.id == t.id }

        tabs.removeAll { $0.id == t.id }
        for key in byWindow.keys {
            byWindow[key]?.removeAll { $0.id == t.id }
        }
        // Drop now-empty windows from the order so we don't render an empty
        // header.
        for key in byWindow.keys where (byWindow[key]?.isEmpty ?? true) {
            byWindow.removeValue(forKey: key)
        }
        windowOrder.removeAll { byWindow[$0] == nil }
        multiWindow = windowOrder.count > 1

        rebuild()

        if removingSelected {
            if let idx = removedRowIdx {
                // Try the row at the same position; fall back to nearest selectable.
                if idx < rows.count, rows[idx].isSelectable {
                    selectedID = rows[idx].id
                } else if let nextIdx = rows[min(idx, rows.count - 1)...].firstIndex(where: { $0.isSelectable }) {
                    selectedID = rows[nextIdx].id
                } else {
                    selectedID = rows.first(where: { $0.isSelectable })?.id
                }
            }
        }
    }

    func rebuild() {
        var out: [Row] = []
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            for (idx, winId) in windowOrder.enumerated() {
                let wtabs = byWindow[winId] ?? []
                if multiWindow {
                    let active = wtabs.contains { $0.isActiveWindow }
                    out.append(.header(windowIndex: idx, isActiveWindow: active))
                }
                for t in wtabs {
                    out.append(.tab(t))
                }
            }
        } else {
            var scored: [(Double, Int, TabInfo)] = []
            for (idx, winId) in windowOrder.enumerated() {
                for t in (byWindow[winId] ?? []) {
                    let s = fuzzyScore(needle: q, hay: t.title)
                    if s >= 0 { scored.append((s, idx, t)) }
                }
            }
            scored.sort { lhs, rhs in
                if lhs.0 != rhs.0 { return lhs.0 > rhs.0 }
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                return lhs.2.tabIndex < rhs.2.tabIndex
            }
            for entry in scored { out.append(.tab(entry.2)) }
        }
        rows = out
        if let sid = selectedID, !rows.contains(where: { $0.id == sid && $0.isSelectable }) {
            selectedID = rows.first(where: { $0.isSelectable })?.id
        } else if selectedID == nil {
            selectedID = rows.first(where: { $0.isSelectable })?.id
        }
    }

    func move(_ delta: Int) {
        let selectables = rows.enumerated().filter { $0.element.isSelectable }.map { $0.offset }
        guard !selectables.isEmpty else { return }
        let curRowIdx = rows.firstIndex(where: { $0.id == selectedID })
        let curPos = curRowIdx.flatMap { selectables.firstIndex(of: $0) } ?? (delta > 0 ? -1 : selectables.count)
        var next = curPos + delta
        if next < 0 { next = 0 }
        if next >= selectables.count { next = selectables.count - 1 }
        let rowIdx = selectables[next]
        selectedID = rows[rowIdx].id
    }

    func selectedTab() -> TabInfo? {
        guard let sid = selectedID else { return nil }
        if let idx = rows.firstIndex(where: { $0.id == sid }),
           case .tab(let t) = rows[idx] {
            return t
        }
        return nil
    }
}

// MARK: - SwiftUI views

struct RowView: View {
    let row: Row
    let isKeySelected: Bool
    let multiWindow: Bool
    let onClose: (TabInfo) -> Void
    @State private var isHovered = false

    var body: some View {
        switch row {
        case .header(let idx, let isActive):
            HStack(spacing: 6) {
                Image(systemName: isActive ? "macwindow.badge.plus" : "macwindow")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("Window \(idx + 1)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .padding(.top, idx == 0 ? 0 : 6)
        case .tab(let t):
            HStack(spacing: 8) {
                ZStack {
                    if t.isActiveTab {
                        Circle()
                            .fill(.green)
                            .frame(width: 7, height: 7)
                    } else {
                        Circle()
                            .strokeBorder(.tertiary, lineWidth: 1)
                            .frame(width: 7, height: 7)
                    }
                }
                .frame(width: 10)

                Text(tabIndexLabel(t.tabIndex))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)

                Text(t.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isKeySelected ? Color.white : Color.primary)
                Spacer(minLength: 4)
                // Right cluster: X close button (visible on hover only) +
                // relative-time activity label (always when not nil). X is
                // to the LEFT of the time so they don't overlap.
                HStack(spacing: 6) {
                    if isHovered {
                        Button {
                            onClose(t)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(isKeySelected ? Color.white.opacity(0.85) : Color.secondary)
                                .symbolRenderingMode(.hierarchical)
                        }
                        .buttonStyle(.plain)
                        .help("Close tab (⌘⌫)")
                    }
                    if let label = t.activityLabel {
                        Text(label)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(isKeySelected ? Color.white.opacity(0.7) : Color.secondary.opacity(0.7))
                            .monospacedDigit()
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(rowBackground)
            )
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
        }
    }

    private func tabIndexLabel(_ i: Int) -> String {
        i <= 9 ? "⌘\(i)" : "\(i)"
    }

    private var rowBackground: Color {
        if isKeySelected { return Color.accentColor.opacity(0.85) }
        if isHovered { return Color.primary.opacity(0.08) }
        return Color.clear
    }
}

struct PickerView: View {
    @ObservedObject var model: PickerModel
    let onCommit: (TabInfo) -> Void
    let onCancel: () -> Void
    let onClose: (TabInfo) -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 13))
                TextField("Search tabs", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($searchFocused)
                    .onSubmit { commit() }
                    .onChange(of: model.query) { old, new in
                        dlog("query changed: \(old.debugDescription) -> \(new.debugDescription)")
                        model.rebuild()
                    }
                    .onChange(of: searchFocused) { _, focused in
                        dlog("searchFocused changed -> \(focused)")
                    }
                if !model.query.isEmpty {
                    Button {
                        model.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().opacity(0.4)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.rows) { row in
                            RowView(
                                row: row,
                                isKeySelected: row.id == model.selectedID && row.isSelectable,
                                multiWindow: model.multiWindow,
                                onClose: { t in onClose(t) }
                            )
                            .id(row.id)
                            .onTapGesture {
                                if case .tab(let t) = row {
                                    model.selectedID = t.id
                                    onCommit(t)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .onChange(of: model.selectedID) { _, newID in
                    if let id = newID {
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
                .onAppear {
                    if let id = model.selectedID {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }

            Divider().opacity(0.4)

            HStack(spacing: 14) {
                hint("↑↓", "navigate")
                hint("⏎", "open")
                hint("⌘⌫", "close")
                hint("esc", "cancel")
                Spacer()
                Text("\(visibleTabCount()) tab\(visibleTabCount() == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(width: 460, height: 360)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.35), radius: 22, x: 0, y: 8)
        // .defaultFocus fires on SwiftUI Window scene appearance. Our SwiftUI
        // view is hosted inside an AppKit NSPanel, so that event never comes
        // and .defaultFocus alone is unreliable. We listen for the AppKit-level
        // NSWindow.didBecomeKeyNotification instead — fires deterministically
        // whenever our NSPanel becomes the key window. Setting @FocusState
        // from this handler reliably claims focus on the TextField.
        .defaultFocus($searchFocused, true)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            dlog("SwiftUI saw didBecomeKey -> setting searchFocused=true")
            searchFocused = true
        }
        // Esc/arrows/Return are handled at the Controller level via an NSEvent
        // local monitor (see Controller.run()). That runs BEFORE the responder
        // chain, which means we get arrow keys before the TextField consumes
        // them for cursor movement (which beeps on empty text).
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, design: .monospaced))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.primary.opacity(0.08))
                )
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func commit() {
        if let t = model.selectedTab() { onCommit(t) }
    }

    private func visibleTabCount() -> Int {
        model.rows.reduce(0) { $0 + ($1.isSelectable ? 1 : 0) }
    }
}

// MARK: - NSPanel host

final class PickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // NSPanel defaults hidesOnDeactivate to YES (unlike NSWindow). When the
    // panel transiently loses key status during startup (window-server
    // settling, NSApp.activate races, etc.), the auto-hide closes our only
    // window — which triggers `applicationShouldTerminateAfterLastWindowClosed`
    // and silently kills the app with no `cancel()` call and no log.
    // We control dismiss explicitly via the didResignActive observer, so
    // disable the auto-hide.
    override var hidesOnDeactivate: Bool {
        get { false }
        set { /* ignore — we manage dismiss ourselves */ }
    }
}

// (KeyHandlingHostingView removed — key handling now lives in PickerView via
//  SwiftUI's .onKeyPress modifiers, and focus via .defaultFocus($searchFocused, true).
//  The previous AppKit-level keyDown + acceptsFirstResponder=true trapped focus
//  on the host view and prevented the TextField from claiming first-responder
//  status, so typing didn't reach it until the user clicked the field directly.)

/// Promote this CLI-launched process to genuinely frontmost via osascript.
/// Without this, NSApp.isActive often stays false even after activate() calls,
/// because the process lacks a .app bundle context — macOS LaunchServices
/// considers it a helper, not a real app. The Tk version of the picker has
/// always used the same trick. Requires Automation permission for System
/// Events (granted on first use via system prompt).
func forceForegroundViaOsascript() {
    let pid = ProcessInfo.processInfo.processIdentifier
    let script = "tell application \"System Events\" to set frontmost of (first process whose unix id is \(pid)) to true"
    let task = Process()
    task.launchPath = "/usr/bin/osascript"
    task.arguments = ["-e", script]
    task.standardOutput = Pipe()
    task.standardError = Pipe()
    do { try task.run() } catch { elog("osascript launch failed: \(error)") }
}

// MARK: - App controller

final class Controller: NSObject, NSWindowDelegate {
    private let model: PickerModel
    private let anchor: AnchorRect?
    private var panel: PickerPanel?
    private var didActivate = false
    private var armedAt: Date?
    private var committed = false
    private var globalMouseMonitor: Any?
    private var localKeyMonitor: Any?
    private var selection: TabInfo?

    init(model: PickerModel, anchor: AnchorRect?) {
        self.model = model
        self.anchor = anchor
    }

    func run() {
        let app = NSApplication.shared
        // .regular: real frontmost app while visible. Required for reliable
        // key/active status — `.accessory` (menu-bar-extra style) caused
        // racy activation: window would become key but app would bounce
        // out of frontmost, firing didResignActive and dismissing the popup.
        app.setActivationPolicy(.regular)

        let view = PickerView(
            model: model,
            onCommit: { [weak self] t in self?.commit(t) },
            onCancel: { [weak self] in self?.cancel() },
            onClose: { [weak self] t in self?.closeTab(t) }
        )

        // Plain NSHostingView — no custom keyDown / acceptsFirstResponder.
        // Key handling (Esc/arrows/Return) happens inside PickerView via
        // SwiftUI .onKeyPress, and focus via .defaultFocus on the @FocusState.
        let host = NSHostingView(rootView: view)

        let width: CGFloat = 460
        let height: CGFloat = 360
        let frame = computeFrame(width: width, height: height)

        let p = PickerPanel(
            contentRect: frame,
            // Plain .borderless. PickerPanel overrides canBecomeKey/canBecomeMain
            // so we can still receive keystrokes despite no titlebar. Adding
            // .titled introduced fullSizeContentView racy behavior on Tahoe.
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.isMovableByWindowBackground = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.contentView = host
        p.delegate = self
        self.panel = p

        // Activation. CLI-compiled Swift binaries (no .app bundle) often fail
        // to truly become "active" via NSApp APIs alone — debug logs showed
        // NSApplication.shared.isActive == false even after activate() calls.
        // The Tk version works around this with osascript controlling System
        // Events, which physically promotes the process to frontmost.
        // We do the same here as a belt-and-suspenders alongside the native API.
        if #available(macOS 14.0, *) {
            NSRunningApplication.current.activate(options: .activateAllWindows)
        } else {
            app.activate(ignoringOtherApps: true)
        }
        forceForegroundViaOsascript()
        p.makeKeyAndOrderFront(nil)

        // Re-assert activation + key status after each potential settling
        // tick. Without these retries, macOS may transiently demote us
        // during window-server settling, leaving the popup visible but
        // unable to receive key events until the user clicks.
        for delayMs in [30, 100, 250] {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { [weak self] in
                guard let self, let panel = self.panel, !self.committed else { return }
                if !NSApplication.shared.isActive {
                    dlog("re-activate at \(delayMs)ms: not active, forcing")
                    if #available(macOS 14.0, *) {
                        NSRunningApplication.current.activate(options: .activateAllWindows)
                    } else {
                        app.activate(ignoringOtherApps: true)
                    }
                    forceForegroundViaOsascript()
                }
                if !panel.isKeyWindow {
                    dlog("re-key at \(delayMs)ms: not key, forcing")
                    panel.makeKey()
                }
                // No manual makeFirstResponder here — SwiftUI's .defaultFocus
                // owns first-responder routing now, and AppKit-level overrides
                // would compete with it and break TextField input.
            }
        }

        // Dismiss-on-resign is armed by windowDidBecomeKey() below, not by a
        // fixed timer. macOS makeKey() races with NSApp.activate(), and a
        // fixed grace can either fire before key actually arrives (premature
        // dismiss on subsequent resign) or arm prematurely. Tying arm to the
        // actual NSWindow.didBecomeKey notification is race-free.

        // QUICKTAB_AUTOCOMMIT=1 commits the pre-selected tab once available
        // (test-only). Retries until model.selectedTab() returns non-nil.
        if ProcessInfo.processInfo.environment["QUICKTAB_AUTOCOMMIT"] == "1" {
            func tryCommit(_ attempt: Int) {
                if let t = self.model.selectedTab() {
                    dlog("autocommit attempt=\(attempt): \(t.id)")
                    self.commit(t)
                    return
                }
                if attempt > 20 { dlog("autocommit gave up"); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) {
                    tryCommit(attempt + 1)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300)) {
                tryCommit(0)
            }
        }

        // QUICKTAB_NO_DISMISS=1 disables auto-dismiss-on-focus-loss (test only).
        let noDismiss = ProcessInfo.processInfo.environment["QUICKTAB_NO_DISMISS"] == "1"
        if !noDismiss {
            // Global mouse monitor: fires for clicks anywhere on screen.
            // This is more reliable than `didResignActive` (which races with
            // window-server focus shuffles during startup, causing the popup
            // to dismiss immediately and randomly). Spotlight uses this same
            // pattern. We only fire when a click lands OUTSIDE our panel —
            // clicks inside route normally via the local event chain.
            globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] _ in
                guard let self else { return }
                if self.committed { return }
                // Only honor clicks after we've fully activated — early
                // synthetic click events during startup shouldn't dismiss.
                if !self.didActivate { return }
                let mouse = NSEvent.mouseLocation
                if let panel = self.panel, panel.frame.contains(mouse) {
                    return  // click inside the popup; ignore
                }
                dlog("global mouseDown outside -> dismiss")
                DispatchQueue.main.async { [weak self] in self?.cancel() }
            }
        }

        // Local key monitor: runs BEFORE the responder chain. We catch
        // Esc / arrows / Return here so the TextField doesn't intercept them
        // (single-line TextField beeps on up/down arrows; we want to navigate
        // the list instead).
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Cmd+Backspace: close the highlighted tab, picker stays open.
            // Chosen because (a) natural "delete this thing" semantics on macOS,
            // (b) no collision with iTerm2 bindings or our own shortcuts.
            if event.modifierFlags.contains(.command) && event.keyCode == 51 {
                dlog("local keyDown: Cmd+Backspace -> closeHighlightedTab")
                self.closeHighlightedTab()
                return nil
            }
            switch event.keyCode {
            case 53:   // Esc
                dlog("local keyDown: Esc -> cancel")
                self.cancel()
                return nil
            case 125:  // Down arrow
                dlog("local keyDown: Down -> move(1)")
                self.model.move(1)
                return nil
            case 126:  // Up arrow
                dlog("local keyDown: Up -> move(-1)")
                self.model.move(-1)
                return nil
            case 36, 76:  // Return / Numpad Enter
                dlog("local keyDown: Return -> commit")
                if let t = self.model.selectedTab() {
                    self.commit(t)
                }
                return nil
            default:
                return event  // let normal text input through
            }
        }
    }

    private func computeFrame(width: CGFloat, height: CGFloat) -> NSRect {
        // The "anchor" coords are AppKit (origin at primary screen bottom-left,
        // y increases upward). NSWindow expects the SAME coord space, so no
        // y flip is needed — only the conversion from "iTerm2 window top" to
        // a position just below its tab bar.
        let tabBarOffset: CGFloat = 76
        let margin: CGFloat = 12

        guard let mainScreen = NSScreen.screens.first else {
            return NSRect(x: 100, y: 100, width: width, height: height)
        }
        let screenFrame = mainScreen.frame

        if let a = anchor {
            // x: top-right corner of iTerm2 window
            let x = CGFloat(a.x + a.w) - width - margin
            // y: position window so its TOP edge is `tabBarOffset` below the
            // iTerm2 window's top edge. iTerm2 window top in AppKit coords:
            let iTermTopY = CGFloat(a.y + a.h)
            let y = iTermTopY - tabBarOffset - height
            // Clamp into primary screen.
            let clampedX = max(8, min(x, screenFrame.maxX - width - 8))
            let clampedY = max(8, min(y, screenFrame.maxY - height - 8))
            return NSRect(x: clampedX, y: clampedY, width: width, height: height)
        }
        // Fallback: top-right of main screen.
        return NSRect(
            x: screenFrame.maxX - width - 40,
            y: screenFrame.maxY - height - 80,
            width: width, height: height
        )
    }

    func commit(_ t: TabInfo) {
        if committed { return }
        committed = true
        selection = t
        finish()
    }

    func cancel() {
        if committed { return }
        committed = true
        selection = nil
        finish()
    }

    /// Emit a single newline-delimited JSON event to stdout.
    /// Used for both intermediate "close" events (picker stays open) and the
    /// final "select" event (just before exit). Parent reads stdout line-by-line.
    func writeEvent(_ event: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: event) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        try? FileHandle.standardOutput.synchronize()
        if let s = String(data: data, encoding: .utf8) {
            dlog("wrote stdout: \(s)")
        }
    }

    /// User asked to close the tab at the highlighted row (or a specific row).
    /// Streams a close event to the parent (which closes via iTerm2 API), and
    /// removes the row from our local model. Picker stays open; selection
    /// advances to the next available tab.
    func closeHighlightedTab() {
        guard let t = model.selectedTab() else { return }
        closeTab(t)
    }

    func closeTab(_ t: TabInfo) {
        dlog("closeTab: \(t.id) (\(t.title))")
        writeEvent([
            "event": "close",
            "window_id": t.windowId,
            "tab_id": t.tabId,
        ])
        model.removeTab(t)
    }

    private func finish() {
        dlog("finish: selection=\(selection?.id ?? "nil")")
        if let m = globalMouseMonitor {
            NSEvent.removeMonitor(m)
            globalMouseMonitor = nil
        }
        if let m = localKeyMonitor {
            NSEvent.removeMonitor(m)
            localKeyMonitor = nil
        }
        panel?.orderOut(nil)
        if let t = selection {
            writeEvent([
                "event": "select",
                "window_id": t.windowId,
                "tab_id": t.tabId,
            ])
        }
        cleanupPidfile()
        NSApp.terminate(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if !didActivate {
            didActivate = true
            armedAt = Date()
            dlog("windowDidBecomeKey")
        }
        // SwiftUI's .defaultFocus($searchFocused, true) drives the text field
        // focus when the window becomes key. No manual makeFirstResponder
        // here — AppKit-level responder writes compete with SwiftUI focus
        // and prevent TextField from receiving typed characters.
    }

    func windowDidResignKey(_ notification: Notification) {
        // Intentionally NO dismiss here. windowDidResignKey fires whenever the
        // panel loses key status — including transient focus dropouts during
        // window settling that don't correspond to the user actually clicking
        // away. The app-level didResignActiveNotification (set up in show())
        // is the one we trust: it fires only when the WHOLE app loses
        // frontmost status, which is what "user clicked another app" means.
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Veto unsolicited closes. Our finish() calls panel.orderOut(nil) and
        // then NSApp.terminate(nil) — terminate triggers shutdown which sends
        // close to all windows, AT WHICH POINT committed is true and we allow.
        // Anything else hitting this path is an unsolicited close attempt —
        // system Cmd+W, performClose from accessibility, stray AppKit event
        // during transitions. Returning false keeps the panel up; the user
        // dismisses via Esc / outside-click / second Cmd+Opt+E.
        if committed {
            dlog("windowShouldClose: allowed (in finish() path)")
            return true
        }
        dlog("windowShouldClose: VETOED (no commit in flight — unsolicited close)")
        return false
    }

    func windowWillClose(_ notification: Notification) {
        dlog("windowWillClose (committed=\(committed))")
    }
}

// MARK: - Entry

func main() -> Int32 {
    writePidfile()
    atexit { cleanupPidfile() }

    signal(SIGTERM) { _ in
        cleanupPidfile()
        _exit(0)
    }
    signal(SIGINT) { _ in
        cleanupPidfile()
        _exit(0)
    }
    signal(SIGHUP, SIG_IGN)
    signal(SIGPIPE, SIG_IGN)

    let raw = FileHandle.standardInput.readDataToEndOfFile()
    dlog("stdin \(raw.count) bytes")
    guard let payload = try? JSONDecoder().decode(InputPayload.self, from: raw) else {
        elog("failed to decode payload")
        return 1
    }
    dlog("tabs=\(payload.tabs.count) anchor=\(String(describing: payload.anchor))")

    let model = PickerModel(tabs: payload.tabs)
    let controller = Controller(model: model, anchor: payload.anchor)
    // Keep controller alive via static reference.
    AppHolder.shared.controller = controller

    let app = NSApplication.shared
    let delegate = AppDelegate(controller: controller)
    AppHolder.shared.delegate = delegate
    app.delegate = delegate
    installMainMenu()  // Cmd+A / Cmd+C / Cmd+V / Cmd+X / etc. via responder chain
    controller.run()
    app.run()
    return 0
}

/// macOS routes the standard text-editing shortcuts (Cmd+A select-all,
/// Cmd+C copy, Cmd+V paste, Cmd+X cut, Cmd+Z undo) through the responder
/// chain — but ONLY if the app has a main menu with items bound to the
/// corresponding selectors. Without an Edit menu the shortcuts silently
/// no-op even inside an NSTextField. We hide the menu from view (no menu
/// bar entries for this floating-utility process); we just need the
/// command-key bindings registered.
func installMainMenu() {
    let mainMenu = NSMenu()

    // First item conventionally hosts the "App" submenu — Quit lives here.
    let appItem = NSMenuItem()
    mainMenu.addItem(appItem)
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "Quit QuickTab",
                    action: #selector(NSApplication.terminate(_:)),
                    keyEquivalent: "q")
    appItem.submenu = appMenu

    // Edit submenu — items target the responder chain via NSText's selectors.
    let editItem = NSMenuItem()
    editItem.title = "Edit"
    mainMenu.addItem(editItem)
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Undo",
                     action: Selector(("undo:")),
                     keyEquivalent: "z")
    editMenu.addItem(withTitle: "Redo",
                     action: Selector(("redo:")),
                     keyEquivalent: "Z")
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: "Cut",
                     action: #selector(NSText.cut(_:)),
                     keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy",
                     action: #selector(NSText.copy(_:)),
                     keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste",
                     action: #selector(NSText.paste(_:)),
                     keyEquivalent: "v")
    editMenu.addItem(withTitle: "Select All",
                     action: #selector(NSText.selectAll(_:)),
                     keyEquivalent: "a")
    editItem.submenu = editMenu

    NSApplication.shared.mainMenu = mainMenu
}

final class AppHolder {
    static let shared = AppHolder()
    var controller: Controller?
    var delegate: NSApplicationDelegate?
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller: Controller
    init(controller: Controller) { self.controller = controller }

    // Return false so that if our panel is closed by anything OTHER than
    // our explicit cancel()/commit() path (system-level Cmd+W, performClose,
    // window-server quirks), the app stays alive and we can log + ignore.
    // Our finish() explicitly calls NSApp.terminate(nil) when we genuinely
    // want to exit. Without this, any external panel close auto-terminates
    // the process with no log — invisible "occasional auto-close" bug.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        dlog("applicationWillTerminate")
    }
}

exit(main())
