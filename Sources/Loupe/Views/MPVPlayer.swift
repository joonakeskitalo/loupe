import SwiftUI
import Combine
import OpenGL.GL
import CMPV

/// Free C-ABI render-update callback for libmpv. mpv calls it on its "vo"
/// thread when a new frame is ready. It must carry no actor-isolation metadata,
/// so it's a file-scope function that only sets the view's lock-free flag (a
/// `nonisolated` method). The main-thread render timer picks the flag up.
private func mpvRenderUpdate(_ ctx: UnsafeMutableRawPointer?) {
    guard let ctx else { return }
    let view = Unmanaged<MPVGLView>.fromOpaque(ctx).takeUnretainedValue()
    view.markFrameWanted()
}

/// Free C-ABI wakeup callback for libmpv. Declared at file scope (not a method,
/// not a closure capturing anything) so it carries no Swift actor-isolation
/// metadata — mpv invokes it on its internal "core" thread, where any Swift
/// executor-isolation check would trap. It only hops to the main queue, where
/// the controller safely drains events.
///
/// LIFETIME: the callback fires on mpv's core thread and enqueues a block that
/// runs *later* on the main queue. The reference held in the controller's
/// `callbackContext` is NOT enough to keep it alive across that hop: teardown()
/// clears the mpv callback and releases `callbackContext` on the main queue,
/// which can deallocate the controller *before* an already-enqueued block runs.
/// Resolving the pointer with `takeUnretainedValue()` then touched freed memory
/// and crashed in swift_retain (EXC_BAD_ACCESS).
///
/// So we take an ADDITIONAL +1 here on the core thread via `Unmanaged.retain()`
/// (a bare refcount bump — no actor isolation, safe off-main) and hand that
/// owned reference to the block, which consumes it with `takeRetainedValue()`.
/// Each in-flight block therefore owns its own strong reference and keeps the
/// controller alive until it finishes draining, independent of teardown.
private func mpvWakeup(_ ctx: UnsafeMutableRawPointer?) {
    guard let ctx else { return }
    // Bump the retain count on the core thread so the controller cannot be
    // deallocated between this enqueue and the block running on main.
    let retained = Unmanaged<MPVController>.fromOpaque(ctx).retain()
    DispatchQueue.main.async {
        // Consume the +1 taken above; the controller stays alive for the call.
        let controller = retained.takeRetainedValue()
        controller.drainEventsFromMain()
    }
}

/// A libmpv-backed playback controller for containers AVFoundation can't demux
/// (Matroska `.mkv`, WebM `.webm`). It mirrors `VideoController`'s surface via
/// `PlaybackController`, so the viewer's control bar and keyboard shortcuts
/// drive it identically.
///
/// Rendering uses mpv's OpenGL render API: this Homebrew build ships only the
/// `gpu`/`gpu-next`/`libmpv` video outputs (no Cocoa `wid` embedding VO), so we
/// own an `NSOpenGLView`, hand mpv a `get_proc_address` for GL symbols, and let
/// it draw into our view's framebuffer whenever it signals a new frame.
///
/// libmpv delivers events and render-update callbacks on arbitrary threads; we
/// hop every state mutation back to the main actor, where all published state
/// and the AppKit view live.
@MainActor
final class MPVController: ObservableObject, PlaybackController {
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0

    /// The mpv client handle. `nil` only after teardown.
    fileprivate private(set) var mpv: OpaquePointer?
    /// The OpenGL render context, created once the GL view has a context.
    fileprivate private(set) var renderContext: OpaquePointer?

    /// Set by the GL view so a render-update callback can ask it to redraw.
    fileprivate weak var glView: MPVGLView?

    /// Mirrors `VideoController`: a scrub owns `currentTime` so the periodic
    /// property updates don't fight the drag.
    private var isScrubbing = false
    private var wasPlayingBeforeScrub = false

    /// Retained self handed to the wakeup callback as its context; released in
    /// teardown so the controller lives as long as the callback is registered.
    private var callbackContext: Unmanaged<MPVController>?

    /// The file to play, remembered until `start()` is called.
    private let url: URL
    /// Guards against SwiftUI's throwaway `@StateObject` instances: mpv is only
    /// created once the view that actually appears calls `start()`.
    private var didStart = false
    /// Whether the initial file has been handed to mpv. Deferred until the
    /// render context exists, because the `libmpv` VO fails to initialize if
    /// playback starts before a render context is set.
    private var didLoadInitial = false

    init(url: URL) {
        self.url = url
        // Intentionally cheap: NO mpv creation here. SwiftUI may build and
        // immediately discard a @StateObject's wrappedValue; doing heavy work
        // (creating mpv, spawning its threads) in init caused duplicate mpv
        // instances and teardown races. Real setup happens in start().
    }

    /// Creates mpv and begins playback. Called from the view's onAppear, so it
    /// runs exactly once for the instance that is actually on screen.
    func start() {
        guard !didStart else { return }
        didStart = true
        setUpMPV()
        // If the GL view already prepared its context before start() ran, build
        // the render context now (createRenderContext no-ops until mpv exists).
        // The initial loadfile is deferred to loadInitialIfReady(), which runs
        // once the render context exists — the libmpv VO needs it present
        // before playback or it fails to initialize.
        if let glView { createRenderContext(view: glView) }
        loadInitialIfReady()
    }

    /// Loads the initial file once both mpv and the render context are ready.
    private func loadInitialIfReady() {
        guard didStart, !didLoadInitial, mpv != nil, renderContext != nil else { return }
        didLoadInitial = true
        load(url: url)
    }

    // MARK: - Setup

    private func setUpMPV() {
        guard let handle = mpv_create() else {
            NSLog("MPVController: mpv_create failed")
            return
        }
        mpv = handle

        // Keep decoding on the GPU where possible; the render API draws through
        // our GL context regardless.
        mpv_set_option_string(handle, "hwdec", "videotoolbox")
        // We own the window/surface; no on-screen OSD/controls from mpv itself.
        mpv_set_option_string(handle, "vo", "libmpv")
        // Loop nothing by default; the viewer handles navigation. Pause state is
        // driven explicitly below.
        mpv_set_option_string(handle, "idle", "yes")
        // Reasonable defaults for smooth seeking in our scrubber.
        mpv_set_option_string(handle, "keep-open", "yes")

        guard mpv_initialize(handle) >= 0 else {
            NSLog("MPVController: mpv_initialize failed")
            mpv_destroy(handle)
            mpv = nil
            return
        }

        // Observe the properties that back our published transport state.
        mpv_observe_property(handle, 0, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 0, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 0, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, 0, "eof-reached", MPV_FORMAT_FLAG)

        // Route mpv's wakeup callback to drain its event queue on the main
        // thread. It fires on mpv's "core" thread, so we must hop to main via
        // DispatchQueue — NOT `Task { @MainActor }`. Creating a Task from a
        // foreign thread makes the Swift 6 concurrency runtime run an executor
        // isolation check (`dispatch_assert_queue`) on that thread, which traps
        // with EXC_BREAKPOINT. `DispatchQueue.main.async` just enqueues and does
        // no such assertion.
        // Hand the callback a RETAINED reference to self as its context, kept
        // in `callbackContext` and released in teardown(). This guarantees the
        // controller outlives the registered callback.
        //
        // The C callback body must contain NO actor-isolated references. mpv
        // invokes it on its "core" thread; if the closure captured anything
        // @MainActor-isolated (even forming a `DispatchQueue.main.async` block
        // that calls a @MainActor method), the Swift 6 runtime runs an executor
        // isolation check on the core thread and traps. So the callback only
        // calls a `nonisolated static` trampoline, which does the main hop.
        let retained = Unmanaged.passRetained(self)
        callbackContext = retained
        // Use a true C function (@convention(c)) as the wakeup callback. A C
        // function pointer carries NO Swift actor-isolation metadata, so mpv
        // calling it on its "core" thread cannot trigger a Swift executor
        // isolation check (which was trapping with EXC_BREAKPOINT). The C
        // function only enqueues a hop to main via GCD.
        mpv_set_wakeup_callback(handle, mpvWakeup, retained.toOpaque())
    }

    /// Records the GL view so start() can build the render context even if the
    /// view prepared its GL context before mpv was created.
    fileprivate func registerGLView(_ view: MPVGLView) {
        glView = view
    }

    /// Called by the GL view once it has a current `NSOpenGLContext`, to create
    /// the mpv render context bound to that GL context.
    fileprivate func createRenderContext(view: MPVGLView) {
        guard let mpv, renderContext == nil else { return }
        glView = view

        let apiType = strdup(MPV_RENDER_API_TYPE_OPENGL)
        defer { free(apiType) }

        // get_proc_address resolves GL symbols for mpv out of the OpenGL
        // framework (see MPVGLView.glProcAddress). Resolving them via the main
        // program image (dlopen(nil)) does NOT reliably find core GL entry
        // points — mpv then calls through null pointers and traps, which was
        // the SIGTRAP on first play.
        var glInit = mpv_opengl_init_params(
            get_proc_address: { _, name in
                guard let name else { return nil }
                return MPVGLView.glProcAddress(String(cString: name))
            },
            get_proc_address_ctx: nil
        )

        // NOTE: we deliberately do NOT set MPV_RENDER_PARAM_ADVANCED_CONTROL.
        // Advanced control makes promises about which thread renders and arms
        // extra internal assertions (and can deadlock) in exchange for features
        // we don't use (NEXT_FRAME_INFO / BLOCK_FOR_TARGET_TIME). The default
        // (unset) "render on update callback" mode is correct for us.
        var ctx: OpaquePointer?
        let rc = withUnsafeMutablePointer(to: &glInit) { glInitPtr -> CInt in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: apiType),
                mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: glInitPtr),
                mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
            ]
            return params.withUnsafeMutableBufferPointer { buf in
                mpv_render_context_create(&ctx, mpv, buf.baseAddress)
            }
        }
        guard rc >= 0, let ctx else {
            NSLog("MPVController: mpv_render_context_create failed (\(rc))")
            return
        }
        renderContext = ctx

        // When mpv has a new frame it calls this on an ARBITRARY thread. We do
        // the absolute minimum here: flip an atomic flag. The view's main-thread
        // timer notices and renders. Crucially we do NOT dispatch to the main
        // actor or touch AppKit here — doing so previously ran SwiftUI layout on
        // mpv's "core" thread and tripped dispatch_assert_queue (SIGTRAP).
        let viewPtr = Unmanaged.passUnretained(view).toOpaque()
        // Same rule as the wakeup callback: use a free C function with NO
        // actor-isolated references. mpv fires this on its "vo" thread; a
        // closure capturing the @MainActor-isolated MPVGLView would trigger a
        // Swift executor-isolation check there and trap.
        mpv_render_context_set_update_callback(ctx, mpvRenderUpdate, viewPtr)

        // Render context is live now; if start() already ran, kick off playback.
        loadInitialIfReady()
    }

    /// Draws the current mpv frame into the given framebuffer. Called by the GL
    /// view on the main thread with its backing FBO bound.
    fileprivate func render(fbo: Int32, width: Int32, height: Int32) {
        guard let renderContext else { return }

        // internal_format MUST be a real format (GL_RGBA8), not 0 — leaving it
        // 0 made mpv's render target handling fail with
        // INVALID_FRAMEBUFFER_OPERATION and produce all-black frames.
        var fboStruct = mpv_opengl_fbo(fbo: fbo, w: width, h: height,
                                       internal_format: GLint(GL_RGBA8))
        // mpv's GL coordinate origin is bottom-left; flip to match our view.
        var flipY: CInt = 1

        withUnsafeMutablePointer(to: &fboStruct) { fboPtr in
            withUnsafeMutablePointer(to: &flipY) { flipPtr in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: fboPtr),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: flipPtr),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                ]
                params.withUnsafeMutableBufferPointer { buf in
                    _ = mpv_render_context_render(renderContext, buf.baseAddress)
                }
            }
        }
    }

    /// Reports to mpv that the just-rendered frame has been presented to the
    /// screen, letting it pace subsequent frames. Called after the GL buffer
    /// swap.
    fileprivate func reportSwap() {
        guard let renderContext else { return }
        mpv_render_context_report_swap(renderContext)
    }

    // MARK: - Event handling

    /// Invoked on the main queue by the free C wakeup callback. We are on the
    /// main thread here; assert main-actor isolation and drain.
    nonisolated func drainEventsFromMain() {
        MainActor.assumeIsolated { self.drainEvents() }
    }

    /// Drains all pending mpv events, updating published state. Runs on the main
    /// actor (dispatched from the wakeup callback).
    private func drainEvents() {
        guard let mpv else { return }
        while true {
            guard let eventPtr = mpv_wait_event(mpv, 0) else { break }
            let event = eventPtr.pointee
            if event.event_id == MPV_EVENT_NONE { break }

            switch event.event_id {
            case MPV_EVENT_PROPERTY_CHANGE:
                handlePropertyChange(event)
            case MPV_EVENT_SHUTDOWN:
                return
            default:
                break
            }
        }
    }

    private func handlePropertyChange(_ event: mpv_event) {
        guard let data = event.data else { return }
        let prop = data.assumingMemoryBound(to: mpv_event_property.self).pointee
        let name = String(cString: prop.name)

        switch name {
        case "time-pos":
            guard !isScrubbing, prop.format == MPV_FORMAT_DOUBLE,
                  let v = prop.data?.assumingMemoryBound(to: Double.self).pointee else { return }
            if v.isFinite { currentTime = v }
        case "duration":
            guard prop.format == MPV_FORMAT_DOUBLE,
                  let v = prop.data?.assumingMemoryBound(to: Double.self).pointee else { return }
            if v.isFinite { duration = v }
        case "pause":
            guard prop.format == MPV_FORMAT_FLAG,
                  let v = prop.data?.assumingMemoryBound(to: CInt.self).pointee else { return }
            isPlaying = (v == 0)
        case "eof-reached":
            guard prop.format == MPV_FORMAT_FLAG,
                  let v = prop.data?.assumingMemoryBound(to: CInt.self).pointee else { return }
            // On end-of-file, snap the thumb back to the start and show paused,
            // matching the AVFoundation backend's end behaviour.
            if v != 0 {
                isPlaying = false
                currentTime = 0
            }
        default:
            break
        }
    }

    // MARK: - PlaybackController

    func load(url: URL) {
        currentTime = 0
        duration = 0
        command("loadfile", url.path)
        play()
    }

    /// Runs an mpv command as a NULL-terminated argv. Each argument is copied
    /// into a C string, assembled into the argv array mpv expects, and freed
    /// after the call.
    private func command(_ args: String...) {
        guard let mpv else { return }
        // strdup each arg; argv must be NULL-terminated.
        var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        argv.append(nil)
        defer { for p in argv where p != nil { free(p) } }
        argv.withUnsafeMutableBufferPointer { buf in
            // mpv_command wants `const char **`; our mutable pointers bridge fine.
            buf.baseAddress?.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buf.count) { reb in
                _ = mpv_command(mpv, reb)
            }
        }
    }

    func play() {
        setPause(false)
        isPlaying = true
    }

    func pause() {
        setPause(true)
        isPlaying = false
    }

    func togglePlay() {
        if isPlaying { pause() } else { play() }
    }

    private func setPause(_ paused: Bool) {
        guard let mpv else { return }
        var flag: CInt = paused ? 1 : 0
        mpv_set_property(mpv, "pause", MPV_FORMAT_FLAG, &flag)
    }

    func seek(toFraction fraction: Double) {
        guard duration.isFinite, duration > 0 else { return }
        let clamped = min(max(fraction, 0), 1)
        seekAbsolute(duration * clamped)
    }

    func skip(by seconds: Double) {
        seekAbsolute(currentTime + seconds)
    }

    /// Absolute seek used by the percentage/skip hotkeys and the scrubber.
    private func seekAbsolute(_ seconds: Double) {
        guard let mpv else { return }
        let target: Double
        if duration.isFinite, duration > 0 {
            target = min(max(seconds, 0), duration)
        } else {
            target = max(seconds, 0)
        }
        currentTime = target
        // mpv parses the time argument from a string; absolute seek.
        command("seek", String(format: "%.3f", target), "absolute")
    }

    func stepFrame(by count: Int) {
        guard count != 0 else { return }
        pause()
        let cmd = count > 0 ? "frame-step" : "frame-back-step"
        // mpv steps one frame per command; issue it |count| times.
        for _ in 0..<abs(count) {
            command(cmd)
        }
    }

    func beginScrubbing() {
        isScrubbing = true
        wasPlayingBeforeScrub = isPlaying
        if wasPlayingBeforeScrub { setPause(true) }
    }

    func scrub(to seconds: Double) {
        currentTime = seconds
        seekAbsolute(seconds)
    }

    func endScrubbing() {
        isScrubbing = false
        if wasPlayingBeforeScrub { play() }
    }

    func teardown() {
        if let renderContext {
            // Clear the update callback first so a late render-update can't
            // reference the view/context while we're tearing it down.
            mpv_render_context_set_update_callback(renderContext, nil, nil)
            mpv_render_context_free(renderContext)
            self.renderContext = nil
        }
        if let mpv {
            // Clearing the wakeup callback and destroying the handle stops
            // mpv's core thread, so no NEW mpvWakeup invocation can begin after
            // this returns. Any block already enqueued on the main queue holds
            // its own +1 (taken in mpvWakeup) and will outlive the release
            // below, so dropping callbackContext here can't dangle it.
            mpv_set_wakeup_callback(mpv, nil, nil)
            mpv_destroy(mpv)
            self.mpv = nil
        }
        // Drop the registration reference the callback context held. In-flight
        // main-queue blocks keep their own reference, so this is safe even if
        // one is still pending.
        callbackContext?.release()
        callbackContext = nil
    }

    // Cleanup happens in teardown(), which the owning view calls from
    // onDisappear on the main actor. We deliberately don't free in deinit:
    // under Swift 6 a nonisolated deinit can't touch the main-actor-isolated
    // mpv handles, and teardown() already covers the view's lifecycle.
}

import AppKit

/// The OpenGL surface mpv draws into.
///
/// CRITICAL threading model: mpv's render-update callback fires on mpv's own
/// internal threads. It must NOT touch AppKit/SwiftUI, and it must not drive
/// `needsDisplay`/`display()` — doing so caused AppKit layout to run on mpv's
/// "core" thread and trip `dispatch_assert_queue(main)` (an EXC_BREAKPOINT
/// SIGTRAP). Instead the callback only flips an atomic flag. A main-thread
/// repeating timer polls that flag and renders synchronously on the main
/// thread, so every GL and AppKit interaction stays on the main thread.
final class MPVGLView: NSOpenGLView {
    /// Weak so the controller and view don't retain each other; the owning
    /// SwiftUI view keeps both alive for the player's lifetime.
    weak var controller: MPVController?

    /// Space/K over the surface — toggle play/pause.
    var onToggle: (() -> Void)?
    /// J — go to the previous item.
    var onPrevious: (() -> Void)?
    /// L — go to the next item.
    var onNext: (() -> Void)?
    /// ←/→ — navigate between items (forward == Right); `shift` marks a
    /// Shift+arrow (extend) press. Handled by the monitor rather than SwiftUI's
    /// `.onKeyPress`: this GL view takes first responder once a video plays, at
    /// which point SwiftUI focus leaves the viewer and `.onKeyPress` goes
    /// silent, but this window-level monitor still receives the keys.
    var onArrow: ((_ forward: Bool, _ shift: Bool) -> Void)?
    /// Whether this surface owns the transport keys. When false (inline
    /// previews) no monitor is installed, so the browser's own hotkeys keep
    /// working while a `.webm`/`.mkv` is merely showing. Only the fullscreen
    /// viewer sets this true.
    var capturesKeyboard: Bool = false {
        didSet {
            guard capturesKeyboard != oldValue else { return }
            refreshKeyMonitor()
        }
    }

    /// Window-scoped key-down monitor, mirroring `KeyablePlayerView`. Without
    /// it, this `NSOpenGLView` (once it's the window's first responder) swallows
    /// unhandled key events — including the viewer's ←/→ navigation arrows,
    /// which then never reach SwiftUI's `.onKeyPress`. The monitor runs our own
    /// transport keys (Space/K/J/L) and passes EVERYTHING ELSE through
    /// untouched, so arrow-key navigation keeps working on `.webm` / `.mkv`.
    private var keyMonitor: Any?

    /// Set (from any thread) by the render-update callback; read + cleared on
    /// the main thread by the render timer. `atomic` via a lock-free flag.
    private let frameWanted = ManagedAtomicFlag()

    /// Main-thread timer that polls `frameWanted` and renders. Decouples mpv's
    /// frame scheduling from AppKit's display cycle.
    private var renderTimer: Timer?

    init(controller: MPVController) {
        self.controller = controller

        let attrs: [NSOpenGLPixelFormatAttribute] = [
            UInt32(NSOpenGLPFAOpenGLProfile), UInt32(NSOpenGLProfileVersion3_2Core),
            UInt32(NSOpenGLPFAAccelerated),
            UInt32(NSOpenGLPFADoubleBuffer),
            0
        ]
        let format = NSOpenGLPixelFormat(attributes: attrs)
        super.init(frame: .zero, pixelFormat: format)!
        wantsBestResolutionOpenGLSurface = true
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    /// Forward any key this view would otherwise consume (default `NSView`
    /// `keyDown` beeps on unhandled keys) up the responder chain, so the
    /// viewer's SwiftUI key handling — including ←/→ item navigation — still
    /// receives them when the GL surface holds first-responder. The transport
    /// keys (Space/K/J/L) are handled by the local monitor before they get
    /// here; everything else bubbles.
    override func keyDown(with event: NSEvent) {
        nextResponder?.keyDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshKeyMonitor()
    }

    /// Install the transport-key monitor only when in a window AND this surface
    /// owns the keyboard; otherwise tear it down.
    private func refreshKeyMonitor() {
        if window != nil && capturesKeyboard {
            installKeyMonitor()
        } else {
            removeKeyMonitor()
        }
    }

    /// Installs the window-scoped key monitor (idempotent). Handles the
    /// transport keys and lets every other key — crucially the ←/→ navigation
    /// arrows — fall through to the viewer's SwiftUI key handling.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Only act while this view is in the key window, so a background
            // player doesn't eat another window's keys.
            guard let window = self.window, window.isKeyWindow else { return event }

            // Yield entirely while the tag-input overlay is focused, so J/L/K/
            // Space type into the tag field instead of driving the video.
            if MainActor.assumeIsolated({ TagInputState.isActive }) { return event }

            // Leave modified combos (⌘/⌃/⌥) to their own shortcuts.
            let modified = !event.modifierFlags
                .intersection([.command, .control, .option])
                .isEmpty
            if modified { return event }

            // ←/→ item navigation, handled here so it survives this GL view
            // holding first responder. Shift extends the viewer's selection.
            if let onArrow = self.onArrow {
                switch event.keyCode {
                case 123:   // Left arrow
                    onArrow(false, event.modifierFlags.contains(.shift))
                    return nil
                case 124:   // Right arrow
                    onArrow(true, event.modifierFlags.contains(.shift))
                    return nil
                default:
                    break
                }
            }

            switch event.charactersIgnoringModifiers?.lowercased() {
            case "k", " ":
                self.onToggle?()
                return nil          // swallow
            case "j":
                self.onPrevious?()
                return nil
            case "l":
                self.onNext?()
                return nil
            default:
                return event        // pass through (other keys)
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    override func prepareOpenGL() {
        super.prepareOpenGL()
        openGLContext?.makeCurrentContext()
        // Register this view with the controller and build the render context.
        // If mpv hasn't been created yet (start() not called), the controller
        // records the view and builds the context later from start().
        controller?.registerGLView(self)
        controller?.createRenderContext(view: self)

        // Start the main-thread render pump at ~60fps. Common-mode so it keeps
        // firing during live resize / menu tracking.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.renderIfNeeded()
        }
        RunLoop.main.add(timer, forMode: .common)
        renderTimer = timer
    }

    /// Called from mpv's render-update callback on an ARBITRARY thread. Only
    /// touches the atomic flag — never AppKit, never the GL context.
    nonisolated func markFrameWanted() {
        frameWanted.set()
    }

    /// Main-thread render pump. Renders every tick (not only when mpv signals a
    /// new frame): the libmpv render-update callback is edge-triggered and
    /// stalled our pipeline after the first frame. Unconditional rendering at
    /// 60Hz is cheap when there's nothing new and guarantees frames reach the
    /// screen. We still clear the flag so it doesn't accumulate meaning.
    private func renderIfNeeded() {
        _ = frameWanted.testAndClear()
        renderNow()
    }

    private func renderNow() {
        guard let context = openGLContext, let controller else { return }
        context.makeCurrentContext()

        let scale = window?.backingScaleFactor ?? 1
        let pxWidth = Int32(bounds.width * scale)
        let pxHeight = Int32(bounds.height * scale)

        // Explicitly bind the view's default framebuffer (0) before handing it
        // to mpv. Without this bind mpv rendered into an incomplete target and
        // produced all-black frames (INVALID_FRAMEBUFFER_OPERATION).
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)

        controller.render(fbo: 0, width: pxWidth, height: pxHeight)
        context.flushBuffer()
        controller.reportSwap()
    }

    override func reshape() {
        super.reshape()
        // Redraw at the new size on the main thread.
        renderNow()
    }

    func stopRendering() {
        renderTimer?.invalidate()
        renderTimer = nil
        removeKeyMonitor()
    }

    /// The OpenGL.framework bundle, loaded once. GL entry points must be
    /// resolved from here — not from the main program image — or mpv gets null
    /// function pointers and traps.
    private static let openGLFramework: CFBundle? = {
        let id = "com.apple.opengl" as CFString
        return CFBundleGetBundleWithIdentifier(id)
    }()

    /// Resolves an OpenGL function pointer by name for mpv's render context,
    /// looking the symbol up in OpenGL.framework.
    static func glProcAddress(_ name: String) -> UnsafeMutableRawPointer? {
        guard let framework = openGLFramework else { return nil }
        let symbol = name as CFString
        return CFBundleGetFunctionPointerForName(framework, symbol)
    }
}

/// A tiny lock-free boolean flag safe to set from any thread and test-and-clear
/// from another. Backed by an `OSAllocatedUnfairLock`-free atomic int so the
/// mpv callback never blocks.
final class ManagedAtomicFlag: @unchecked Sendable {
    private var value: Int32 = 0

    func set() {
        OSAtomicCompareAndSwap32(0, 1, &value)
    }

    /// Returns true if the flag was set, clearing it. Main-thread only reader.
    func testAndClear() -> Bool {
        return OSAtomicCompareAndSwap32(1, 0, &value)
    }
}

/// SwiftUI wrapper placing the mpv GL surface in the view tree. Analogous to
/// `PlayerSurface` for AVFoundation, but there's no AVKit here: the control bar
/// in `VideoPlayerView` is the only chrome, drawn below the surface.
struct MPVSurface: NSViewRepresentable {
    let controller: MPVController
    var onPrevious: (() -> Void)? = nil
    var onNext: (() -> Void)? = nil
    var onArrow: ((_ forward: Bool, _ shift: Bool) -> Void)? = nil
    var capturesKeyboard: Bool = false

    func makeNSView(context: Context) -> MPVGLView {
        let view = MPVGLView(controller: controller)
        wire(view)
        return view
    }

    func updateNSView(_ nsView: MPVGLView, context: Context) {
        nsView.controller = controller
        wire(nsView)
    }

    /// Hooks the surface's transport keys up to the controller / navigation
    /// callbacks. Space/K toggle playback; J/L step items; ←/→ navigate items.
    /// The ←/→ arrows are handled by the view's monitor (not SwiftUI's
    /// `.onKeyPress`) so they keep working once the GL surface takes first
    /// responder while a video plays. Every other key still passes through.
    private func wire(_ view: MPVGLView) {
        view.onToggle = { [weak controller] in controller?.togglePlay() }
        view.onPrevious = onPrevious
        view.onNext = onNext
        view.onArrow = onArrow
        view.capturesKeyboard = capturesKeyboard
    }

    static func dismantleNSView(_ nsView: MPVGLView, coordinator: ()) {
        nsView.stopRendering()
    }
}
