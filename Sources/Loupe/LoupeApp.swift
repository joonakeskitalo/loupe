import SwiftUI
import AppKit

/// Publishes the key window's `BrowserModel` so menu commands (which live at
/// the `Scene` level, outside any window) can act on whichever window is
/// frontmost. Set by `ContentView` via `.focusedValue`.
struct ActiveBrowserModelKey: FocusedValueKey {
    typealias Value = BrowserModel
}

/// Whether the menu bar may own the ⌘⌫ "Move to Trash" shortcut right now.
/// False while the search field is focused (⌘⌫ should edit text) or the viewer
/// is open (the viewer carries its own ⌘⌫ handler) — keeping exactly one owner
/// of the shortcut live at a time.
struct TrashShortcutEligibleKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var activeBrowserModel: BrowserModel? {
        get { self[ActiveBrowserModelKey.self] }
        set { self[ActiveBrowserModelKey.self] = newValue }
    }

    var trashShortcutEligible: Bool? {
        get { self[TrashShortcutEligibleKey.self] }
        set { self[TrashShortcutEligibleKey.self] = newValue }
    }
}

@main
struct LoupeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // Each window owns its own BrowserModel (created in ContentView), so
        // windows browse independently. The window value is a batch of folder/
        // file URLs to open on launch (empty = an empty window).
        WindowGroup(for: [URL].self) { $urls in
            ContentView(initialURLs: urls ?? [])
                .frame(minWidth: 900, minHeight: 600)
                .onAppear {
                    // How the bridge opens a brand-new window when no empty
                    // window is available to reuse.
                    OpenURLBridge.shared.open = { batch in
                        openWindow(value: batch)
                    }
                }
        }
        .windowStyle(.titleBar)
        // Open every new window at the same standard size rather than inheriting
        // the previous window's frame. `.restorationBehavior(.disabled)` below
        // stops the system from persisting/restoring the frame, so this default
        // is what every launch gets. Kept just above the 900×600 window minimum
        // so it's compact but not cramped.
        .defaultSize(width: 1000, height: 680)
        // Don't restore windows on launch — neither the number of windows nor
        // each window's size/position. This is the SwiftUI-level control
        // (macOS 15+) that actually governs `WindowGroup` persistence; the
        // AppDelegate `applicationShouldRestoreApplicationState` callback is not
        // reliably consulted for SwiftUI scenes, which is why the frame kept
        // coming back. With this, each launch starts with a single window at
        // `defaultSize`.
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Window") {
                    openWindow(value: [URL]())
                }
                .keyboardShortcut("n", modifiers: .command)

                // ⌘T opens another window; because every Loupe window prefers
                // tabbing (see WindowTabbingConfigurator), the new one joins the
                // frontmost window as a tab. Routed through the window's tab
                // action so it lands in the active window's tab group.
                Button("New Tab") {
                    WindowTabs.newTab(openWindow: { openWindow(value: [URL]()) })
                }
                .keyboardShortcut("t", modifiers: .command)

                Button("Open Folder in New Window…") {
                    let urls = chooseFolders()
                    if !urls.isEmpty { openWindow(value: urls) }
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            // Tab navigation. ⌃Tab / ⌃⇧Tab cycle through the frontmost window's
            // tabs via AppKit's standard tab-selection actions.
            CommandGroup(after: .windowArrangement) {
                Button("Show Next Tab") { WindowTabs.selectNext() }
                    .keyboardShortcut(.tab, modifiers: .control)
                Button("Show Previous Tab") { WindowTabs.selectPrevious() }
                    .keyboardShortcut(.tab, modifiers: [.control, .shift])
            }

            // The full set of File / Item / View menu commands, all acting on
            // the frontmost window's model via @FocusedValue. See LoupeCommands.
            LoupeCommands()
        }
    }

    private func chooseFolders() -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        return panel.runModal() == .OK ? panel.urls : []
    }
}

/// Drives native macOS window-tab actions on the frontmost (key) window.
///
/// AppKit exposes tabbing through responder-chain actions on `NSWindow`
/// (`newWindowForTab:`, `selectNextTab:`, `selectPreviousTab:`). SwiftUI's
/// `WindowGroup` doesn't surface these, so these helpers invoke them directly
/// on the key window — the same calls the system's own Window-menu items use.
@MainActor
enum WindowTabs {
    /// Opens a new tab in the frontmost window. Prefers AppKit's
    /// `newWindowForTab:` (which adds a tab to the key window's group); if no
    /// window can service it (e.g. none is open yet), falls back to opening a
    /// fresh window via SwiftUI, which — because Loupe windows prefer tabbing —
    /// still joins any existing window as a tab.
    static func newTab(openWindow: () -> Void) {
        if let window = NSApp.keyWindow,
           window.responds(to: #selector(NSWindow.newWindowForTab(_:))) {
            window.newWindowForTab(nil)
            // Keep the new tab grouped with the window it was spawned from even
            // if the system would otherwise float it (belt-and-suspenders when
            // the global "prefer tabs" setting is off).
            if let newWindow = NSApp.keyWindow, newWindow != window,
               window.tabGroup?.windows.contains(newWindow) == false {
                window.addTabbedWindow(newWindow, ordered: .above)
                newWindow.makeKeyAndOrderFront(nil)
            }
            return
        }
        openWindow()
    }

    /// Selects the next tab in the frontmost window's tab group (⌃Tab).
    static func selectNext() {
        NSApp.keyWindow?.selectNextTab(nil)
    }

    /// Selects the previous tab in the frontmost window's tab group (⌃⇧Tab).
    static func selectPrevious() {
        NSApp.keyWindow?.selectPreviousTab(nil)
    }
}

extension KeyEquivalent {
    /// The Mac keyboard "delete" key (⌫), which sends backspace (U+0008).
    ///
    /// SwiftUI's built-in `.delete` maps to forward-delete (U+007F, the key
    /// labeled "delete" on full keyboards / fn+⌫ on laptops), so a shortcut
    /// bound to `.delete` never fires for a plain ⌘⌫ press. Use this instead.
    static let deleteBackspace = KeyEquivalent("\u{8}")
}

/// Handles files/folders dropped on the Dock icon (or opened via the system),
/// routing each open request to a fresh window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        let standardized = urls.map { $0.standardizedFileURL }
        guard !standardized.isEmpty else { return }
        Task { @MainActor in OpenURLBridge.shared.deliver(standardized) }
    }

    /// Register defaults before any window is created so window restoration is
    /// off from the first launch. `NSQuitAlwaysKeepsWindows = false` is the
    /// AppKit-level switch that stops the system reopening a quit app's windows;
    /// it backs up the SwiftUI `.restorationBehavior(.disabled)` on the scene
    /// (and covers the "Close windows when quitting an app" system setting,
    /// which otherwise re-enables restoration).
    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
        // Allow Loupe's windows to merge into native macOS tabs. Without this
        // the window group's windows always open as separate windows and the
        // Window ▸ "Show Tab Bar" / tab shortcuts are unavailable. Each window
        // then opts into preferring tabs via `WindowTabbingConfigurator`.
        NSWindow.allowsAutomaticWindowTabbing = true
    }

    /// Never auto-create a blank untitled window on launch/activation.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }
}

/// Routes dropped/opened URL batches to a window, avoiding duplicate windows.
///
/// When a batch arrives it is loaded into an existing EMPTY window if one is
/// available (which is the case right after launch, where SwiftUI itself has
/// already created a window), otherwise a brand-new window is opened. This
/// prevents the "SwiftUI made a window AND we opened one" duplicate.
@MainActor
final class OpenURLBridge {
    static let shared = OpenURLBridge()

    /// How to open a brand-new window (set by the App via `openWindow`).
    var open: (([URL]) -> Void)?

    /// Loaders for currently-empty windows, newest last.
    private var emptyWindowLoaders: [(id: UUID, load: ([URL]) -> Void)] = []

    /// A batch that arrived before any window/loader existed.
    private var pending: [URL]?

    /// Register an empty window's loader. Returns the id to unregister with.
    func registerEmptyWindow(_ load: @escaping ([URL]) -> Void) -> UUID {
        let id = UUID()
        emptyWindowLoaders.append((id, load))
        // Flush anything that arrived before any window existed.
        if let batch = pending {
            pending = nil
            consumeEmptyWindow()?(batch)
        }
        return id
    }

    func unregisterEmptyWindow(_ id: UUID) {
        emptyWindowLoaders.removeAll { $0.id == id }
    }

    private func consumeEmptyWindow() -> (([URL]) -> Void)? {
        guard !emptyWindowLoaders.isEmpty else { return nil }
        return emptyWindowLoaders.removeLast().load
    }

    /// Deliver a batch: reuse an empty window if present, else open a new one,
    /// else buffer until a window appears.
    func deliver(_ urls: [URL]) {
        if let load = consumeEmptyWindow() {
            load(urls)
        } else if let open {
            open(urls)
        } else {
            pending = urls
        }
    }
}
