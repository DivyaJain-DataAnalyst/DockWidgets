import Cocoa
import SwiftUI
import Combine

class OverlayWindow: NSWindow {
    private let dockPositionManager = DockPositionManager.shared
    private var dockSubscription: AnyCancellable?
    private var widgetManager: WidgetManager?
    private enum FSState { case normal, fullscreen }
    private var fsState: FSState = .normal
    private var spaceChangeObserver: Any?
    private var appActivationObserver: Any?
    private var samplingTimer: DispatchSourceTimer?
    // legacy counters (still usable for diagnostics)
    private var enterConsistency = 0
    private var exitConsistency = 0
    private let sampleInterval: TimeInterval = 0.2 // Reduced for faster detection
    private var resampleBurstWork: DispatchWorkItem?
    private var debugFS = true
    // Exit tracking (fast mode)
    private var firstExitCandidateAt: Date?
    private let requiredExitStable: TimeInterval = 0.5 // Increased for more stable exit detection
    private var lastMenuBarVisibleAt: Date?
    // Optimistic early show
    private let optimisticEarlyShow = false // Disabled to prevent premature showing
    private var optimisticShownAt: Date?
    // Space transition ignore & stable enter
    private var lastSpaceChangeAt: Date?
    private let spaceTransitionIgnore: TimeInterval = 0.5 // Increased
    private var firstFullscreenCandidateAt: Date?
    private let minEnterStable: TimeInterval = 0.2 // Kept fast for entry
    
    // Helper
    private func isInSpaceTransitionIgnore() -> Bool {
        if let t = lastSpaceChangeAt { return Date().timeIntervalSince(t) < spaceTransitionIgnore }
        return false
    }
    
    // MARK: Init
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: [.borderless], backing: backingStoreType, defer: flag)
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        acceptsMouseMovedEvents = true
        setupWindow()
        setupDockObserver()
        setupFullscreenObservers()
        startSamplingTimer()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.processSnapshot(reason: "initial") }
    }
    
    deinit {
        if let spaceChangeObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceChangeObserver) }
        if let appActivationObserver { NSWorkspace.shared.notificationCenter.removeObserver(appActivationObserver) }
        samplingTimer?.cancel()
    }
    
    func setWidgetManager(_ manager: WidgetManager) { widgetManager = manager; updateContentView() }
    
    // MARK: Observers
    private func setupFullscreenObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        spaceChangeObserver = nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.lastSpaceChangeAt = Date()
            self?.triggerResampleBurst(reason: "spaceChange")
        }
        appActivationObserver = nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.triggerResampleBurst(reason: "appActivate")
        }
    }
    
    private func startSamplingTimer() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + sampleInterval, repeating: sampleInterval)
        t.setEventHandler { [weak self] in self?.processSnapshot(reason: "periodic") }
        t.resume()
        samplingTimer = t
    }
    
    private func triggerResampleBurst(reason: String) {
        resampleBurstWork?.cancel()
        var remaining = 3 // fewer samples for speed
        var work: DispatchWorkItem!
        work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.processSnapshot(reason: reason + "-burst")
            remaining -= 1
            if remaining > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work) }
        }
        resampleBurstWork = work
        DispatchQueue.main.async(execute: work)
    }
    
    // MARK: Sampling & State Machine
    private func processSnapshot(reason: String) {
        let snapshot = fullscreenSnapshotDetails()
        if debugFS {
            print("[FS] reason=\(reason) isFS=\(snapshot.isFullscreen) menuBarVisible=\(snapshot.menuBarVisible) enterStable=\(String(format: "%.2f", firstFullscreenCandidateAt.map{Date().timeIntervalSince($0)} ?? 0)) exitStable=\(String(format: "%.2f", firstExitCandidateAt.map{Date().timeIntervalSince($0)} ?? 0)) state=\(fsState) opt=\(optimisticShownAt != nil) alpha=\(alphaValue) visible=\(isVisible)")
        }
        
        switch fsState {
        case .normal:
            // More aggressive fullscreen detection - check for both fullscreen apps and hidden menu bar
            if (snapshot.isFullscreen || !snapshot.menuBarVisible) && !isInSpaceTransitionIgnore() {
                if firstFullscreenCandidateAt == nil {
                    firstFullscreenCandidateAt = Date()
                    if debugFS { print("[FS] Starting fullscreen candidate timer") }
                }
                if Date().timeIntervalSince(firstFullscreenCandidateAt!) >= minEnterStable {
                    if debugFS { print("[FS] Transitioning to fullscreen after stable period") }
                    transitionToFullscreen()
                }
            } else {
                if firstFullscreenCandidateAt != nil && debugFS { print("[FS] Canceling fullscreen candidate") }
                firstFullscreenCandidateAt = nil
            }
            firstExitCandidateAt = nil
            optimisticShownAt = nil
            
        case .fullscreen:
            // VERY conservative exit detection - require BOTH conditions AND ignore space transitions
            if !snapshot.isFullscreen && snapshot.menuBarVisible && !isInSpaceTransitionIgnore() {
                if firstExitCandidateAt == nil {
                    firstExitCandidateAt = Date()
                    if debugFS { print("[FS] Starting exit candidate timer (conservative)") }
                }
                // Only exit after a much longer stable period
                if Date().timeIntervalSince(firstExitCandidateAt!) >= requiredExitStable {
                    if debugFS { print("[FS] Transitioning to normal after LONG stable period") }
                    transitionToNormal()
                }
            } else {
                // Cancel exit immediately if ANY fullscreen condition is detected
                if firstExitCandidateAt != nil && debugFS { print("[FS] Canceling exit candidate - fullscreen still detected") }
                firstExitCandidateAt = nil
                
                // AGGRESSIVELY re-hide if any fullscreen indicators are present
                if (snapshot.isFullscreen || !snapshot.menuBarVisible || isInSpaceTransitionIgnore()) && (alphaValue > 0 || isVisible) {
                    if debugFS { print("[FS] AGGRESSIVE re-hiding - fullscreen indicators present") }
                    hideForFullscreen()
                }
            }
            firstFullscreenCandidateAt = nil
        }
    }
    
    private func transitionToFullscreen() {
        guard fsState != .fullscreen else { return }
        if debugFS { print("[FS] *** ENTERING FULLSCREEN STATE ***") }
        fsState = .fullscreen
        enterConsistency = 0
        optimisticShownAt = nil
        hideForFullscreen()
    }
    
    private func transitionToNormal() {
        guard fsState == .fullscreen else { return }
        if debugFS { print("[FS] *** EXITING FULLSCREEN STATE ***") }
        fsState = .normal
        enterConsistency = 0
        firstExitCandidateAt = nil
        optimisticShownAt = nil
        if alphaValue < 1 { showAfterFullscreen() }
    }
    
    // MARK: Snapshot model (improved detection)
    private struct FSSnapshot { let isFullscreen: Bool; let menuBarVisible: Bool }
    private func fullscreenSnapshotDetails() -> FSSnapshot {
        let screen = self.screen ?? NSScreen.main
        guard let screen else { return FSSnapshot(isFullscreen: false, menuBarVisible: false) }
        
        let frame = screen.frame
        let visible = screen.visibleFrame
        let menuBarDelta = frame.maxY - visible.maxY
        let menuBarVisible = menuBarDelta > 20 // Slightly more lenient
        
        if menuBarVisible { lastMenuBarVisibleAt = Date() }
        
        // More comprehensive fullscreen detection
        let isFullscreen = detectFullscreenWindows(screen: screen)
        
        if debugFS && (isFullscreen || !menuBarVisible) {
            print("[FS] detect isFullscreen=\(isFullscreen) menuBarVisible=\(menuBarVisible) menuBarDelta=\(menuBarDelta)")
        }
        
        return FSSnapshot(isFullscreen: isFullscreen, menuBarVisible: menuBarVisible)
    }
    
    private func detectFullscreenWindows(screen: NSScreen) -> Bool {
        // Build display info
        struct DisplayPx { let width: CGFloat; let height: CGFloat }
        var displays: [DisplayPx] = []
        
        for s in NSScreen.screens {
            var w: CGFloat
            var h: CGFloat
            if let num = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                let id = CGDirectDisplayID(truncating: num)
                let b = CGDisplayBounds(id)
                w = b.width; h = b.height
            } else {
                let sc = s.backingScaleFactor
                w = s.frame.width * sc; h = s.frame.height * sc
            }
            displays.append(DisplayPx(width: w, height: h))
        }
        
        if displays.isEmpty {
            let sc = screen.backingScaleFactor
            displays = [DisplayPx(width: screen.frame.width * sc, height: screen.frame.height * sc)]
        }
        
        // Tighter tolerances for more accurate detection
        let baseScale = screen.backingScaleFactor
        let tolExact: CGFloat = max(2, 2 * baseScale)
        let tolNear: CGFloat = max(5, 5 * baseScale)
        
        // Get window list
        let options: CGWindowListOption = [.excludeDesktopElements, .optionOnScreenOnly]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        
        let selfPID = ProcessInfo.processInfo.processIdentifier
        var exactCoverAny = false
        var nearCoverAny = false
        var splitCountByDisplay: [Int] = Array(repeating: 0, count: displays.count)
        
        for info in list {
            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let w = bounds["Width"], let h = bounds["Height"],
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let onscreen = info[kCGWindowIsOnscreen as String] as? Bool else { continue }
            
            if pid == selfPID { continue }
            if !onscreen { continue }
            if layer > 1 { continue }
            
            // Skip very small windows
            if w < 100 || h < 100 { continue }
            
            for (i, d) in displays.enumerated() {
                let exact = abs(w - d.width) <= tolExact && abs(h - d.height) <= tolExact
                if exact { exactCoverAny = true }
                
                let area = w * h
                let dispArea = d.width * d.height
                let near = (abs(h - d.height) <= tolNear && w >= d.width * 0.98) ||
                           (abs(w - d.width) <= tolNear && h >= d.height * 0.98) ||
                           (area >= dispArea * 0.98)
                if near { nearCoverAny = true }
                
                // Split screen detection - more conservative
                if abs(h - d.height) <= tolNear && w >= d.width * 0.48 && w <= d.width * 0.52 {
                    splitCountByDisplay[i] += 1
                }
            }
        }
        
        let splitOnAny = splitCountByDisplay.contains { $0 >= 2 }
        return exactCoverAny || nearCoverAny || splitOnAny
    }
    
    // MARK: Visibility helpers
    private func hideForFullscreen() {
        if debugFS { print("[FS] Hiding window for fullscreen") }
        // More aggressive hiding
        ignoresMouseEvents = true
        alphaValue = 0
        orderOut(nil)
    }
    private func fastShowAfterFullscreen() {
        ignoresMouseEvents = false
        if isVisible && alphaValue >= 0.95 { return }
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.08
            animator().alphaValue = 1
        }
    }
    private func showAfterFullscreen() {
        ignoresMouseEvents = false
        if alphaValue == 1 && isVisible { return }
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            animator().alphaValue = 1
        }
    }
    
    // MARK: Dock / layout (unchanged)
    private func setupDockObserver() { /* intentionally disabled */ }
    private func updateWindowFrame() {
        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let windowFrame = calculateWindowFrame(screenFrame: screenFrame)
        setFrame(windowFrame, display: true)
    }
    private func setupWindow() {
        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let dockHeight = getDockHeight()
        let windowHeight = max(dockHeight, 70)
        let windowFrame = NSRect(x: 0, y: 0, width: screenFrame.width, height: windowHeight)
        setFrame(windowFrame, display: true)
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
    }
    private func getDockHeight() -> CGFloat {
        guard let screen = NSScreen.main else { return 70 }
        let scaleFactor = screen.backingScaleFactor
        let dockFrame = dockPositionManager.dockFrame
        if dockFrame.height > 0 { return dockFrame.height * scaleFactor }
        if let tileSize = UserDefaults.standard.object(forKey: "tilesize") as? CGFloat { return tileSize * scaleFactor }
        let task = Process(); task.launchPath = "/usr/bin/defaults"; task.arguments = ["read", "com.apple.dock", "tilesize"]
        let pipe = Pipe(); task.standardOutput = pipe; task.launch(); task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), let v = Double(output) { return CGFloat(v) * scaleFactor }
        return 70 * scaleFactor
    }
    private func updateContentView() {
        guard let widgetManager = widgetManager else { return }
        let contentView = WidgetContainerView(window: self, widgetManager: widgetManager)
        self.contentView = NSHostingView(rootView: contentView)
    }
    private func calculateWindowFrame(screenFrame: NSRect) -> NSRect {
        let dockFrame = dockPositionManager.dockFrame
        let buffer: CGFloat = 50
        return NSRect(x: 0, y: 0, width: screenFrame.width, height: dockFrame.maxY + buffer + 100)
    }
}

enum DockPosition { case bottom, left, right }
