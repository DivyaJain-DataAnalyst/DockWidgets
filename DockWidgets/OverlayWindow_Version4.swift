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
    // Update timing constants for better responsiveness and stability
    private let sampleInterval: TimeInterval = 0.15 // Even faster detection
    private let requiredExitStable: TimeInterval = 0.8 // Balanced exit timing
    private let minEnterStable: TimeInterval = 0.1 // Very fast entry
    private let spaceTransitionIgnore: TimeInterval = 0.3 // Reduced transition ignore
    private var resampleBurstWork: DispatchWorkItem?
    private var debugFS = true
    // Exit tracking (fast mode)
    private var firstExitCandidateAt: Date?
    private var lastMenuBarVisibleAt: Date?
    // Optimistic early show
    private let optimisticEarlyShow = false // Disabled to prevent premature showing
    private var optimisticShownAt: Date?
    // Space transition ignore & stable enter
    private var lastSpaceChangeAt: Date?
    private var firstFullscreenCandidateAt: Date?
    
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
            print("[FS] reason=\(reason) isFS=\(snapshot.isFullscreen) enterStable=\(String(format: "%.2f", firstFullscreenCandidateAt.map{Date().timeIntervalSince($0)} ?? 0)) exitStable=\(String(format: "%.2f", firstExitCandidateAt.map{Date().timeIntervalSince($0)} ?? 0)) state=\(fsState) alpha=\(alphaValue)")
        }
        
        switch fsState {
        case .normal:
            // Enhanced fullscreen detection - check for fullscreen windows or hidden menu bar
            if snapshot.isFullscreen && !isInSpaceTransitionIgnore() {
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
            // Enhanced exit detection - check for absence of fullscreen windows AND visible menu bar
            if !snapshot.isFullscreen && !isInSpaceTransitionIgnore() {
                if firstExitCandidateAt == nil {
                    firstExitCandidateAt = Date()
                    if debugFS { print("[FS] Starting exit candidate timer") }
                }
                // Exit after stable period with confirmed non-fullscreen state
                if Date().timeIntervalSince(firstExitCandidateAt!) >= requiredExitStable {
                    if debugFS { print("[FS] Transitioning to normal - no fullscreen windows detected") }
                    transitionToNormal()
                }
            } else {
                // Cancel exit if fullscreen window detected again
                if firstExitCandidateAt != nil && debugFS { print("[FS] Canceling exit candidate - fullscreen window detected") }
                firstExitCandidateAt = nil
                
                // AGGRESSIVE re-hiding if any fullscreen indicator is present
                if snapshot.isFullscreen && (alphaValue > 0) {
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
    
    // MARK: Snapshot model (NSWorkspace detection)
    private struct FSSnapshot { let isFullscreen: Bool }
    
    private func fullscreenSnapshotDetails() -> FSSnapshot {
        let isFullscreen = detectFullscreenApp()
        
        if debugFS && isFullscreen {
            print("[FS] Fullscreen app detected")
        }
        
        return FSSnapshot(isFullscreen: isFullscreen)
    }
    
    private func detectFullscreenApp() -> Bool {
        // Get the frontmost application
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            if debugFS { print("[FS] No frontmost app found") }
            return false
        }
        
        // Skip our own app
        if frontmostApp.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return false
        }
        
        guard let screen = NSScreen.main else {
            if debugFS { print("[FS] No main screen found") }
            return false
        }
        
        let appName = frontmostApp.localizedName ?? "Unknown"
        
        // Primary check: Menu bar visibility (most reliable indicator)
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let menuBarHeight = screenFrame.maxY - visibleFrame.maxY
        
        // Very lenient menu bar check - if menu bar is significantly reduced
        if menuBarHeight < 10 {
            if debugFS {
                print("[FS] FULLSCREEN DETECTED via menu bar for \(appName) - menuBarHeight: \(menuBarHeight)")
            }
            return true
        }
        
        // Secondary check: Simple window size detection without strict accessibility requirements
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        if let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] {
            let pid = frontmostApp.processIdentifier
            
            for windowInfo in windowList {
                guard let windowPID = windowInfo[kCGWindowOwnerPID as String] as? Int32,
                      windowPID == pid,
                      let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: Any],
                      let width = boundsDict["Width"] as? CGFloat,
                      let height = boundsDict["Height"] as? CGFloat else {
                    continue
                }
                
                // Very simple fullscreen detection - if window is close to screen size
                let widthRatio = width / screenFrame.width
                let heightRatio = height / screenFrame.height
                
                if widthRatio > 0.8 && heightRatio > 0.8 {
                    if debugFS {
                        print("[FS] FULLSCREEN DETECTED via large window for \(appName)")
                        print("[FS] Window size: \(Int(width))x\(Int(height)), Screen: \(Int(screenFrame.width))x\(Int(screenFrame.height))")
                        print("[FS] Coverage: \(Int(widthRatio*100))% x \(Int(heightRatio*100))%")
                    }
                    return true
                }
            }
        }
        
        if debugFS {
            print("[FS] No fullscreen for \(appName) - menuBar: \(String(format: "%.1f", menuBarHeight))px")
        }
        
        return false
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
