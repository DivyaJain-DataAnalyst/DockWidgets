import Cocoa
import SwiftUI
import Combine

class OverlayWindow: NSWindow {
    private let dockPositionManager = DockPositionManager.shared
    private var dockSubscription: AnyCancellable?
    private var widgetManager: WidgetManager?
    // Fullscreen handling (state machine + sampling)
    private enum FSState { case normal, fullscreen }
    private var fsState: FSState = .normal
    private var spaceChangeObserver: Any?
    private var appActivationObserver: Any?
    private var samplingTimer: DispatchSourceTimer?
    private var enterConsistency = 0
    private var exitConsistency = 0 // debug only
    private let enterThreshold = 2
    private let sampleInterval: TimeInterval = 0.28
    private var resampleBurstWork: DispatchWorkItem?
    private var debugFS = false
    // Stable exit tracking (adjusted for faster reappear)
    private var firstExitCandidateAt: Date?
    private let requiredExitStable: TimeInterval = 0.25 // was 0.9
    private var lastMenuBarVisibleAt: Date?
    // Optimistic early show config
    private let optimisticEarlyShow = true
    private var optimisticShownAt: Date?
    // Baseline (autohide) detection
    private var baselineCaptured = false
    private var baselineMenuBarDelta: CGFloat = -1
    private var baselineDockDelta: CGFloat = -1
    private let deltaTolerance: CGFloat = 2
    private let significantDelta: CGFloat = 4
    
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
        // Prime initial classification after slight delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.processSnapshot(reason: "initial") }
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
        // Burst: perform several quick samples over ~0.8s to stabilize after a space transition
        resampleBurstWork?.cancel()
        var remaining = 4
        var work: DispatchWorkItem!  // declare first so closure can reference
        work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.processSnapshot(reason: reason + "-burst")
            remaining -= 1
            if remaining > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
            }
        }
        resampleBurstWork = work
        DispatchQueue.main.async(execute: work)
    }
    
    // MARK: Sampling & State Machine
    private func processSnapshot(reason: String) {
        let snapshot = fullscreenSnapshotDetails()
        if debugFS { print("[FS] reason=\(reason) isFS=\(snapshot.isFullscreen) menuBarVisible=\(snapshot.menuBarVisible) enterC=\(enterConsistency) exitStart=\(String(describing:firstExitCandidateAt)) state=\(fsState) optShown=\(optimisticShownAt != nil)") }
        switch fsState {
        case .normal:
            if snapshot.isFullscreen {
                enterConsistency += 1
                if enterConsistency >= enterThreshold { transitionToFullscreen() }
            } else { enterConsistency = 0 }
            firstExitCandidateAt = nil
            optimisticShownAt = nil
        case .fullscreen:
            if snapshot.isFullscreen {
                // Still fullscreen; ensure hidden if we optimistically showed
                firstExitCandidateAt = nil
                if optimisticShownAt != nil { hideForFullscreen() }
                optimisticShownAt = nil
            } else {
                // Candidate for exit
                if firstExitCandidateAt == nil {
                    firstExitCandidateAt = Date()
                    if optimisticEarlyShow && optimisticShownAt == nil {
                        // Show immediately (fast) to feel responsive
                        fastShowAfterFullscreen()
                        optimisticShownAt = Date()
                    }
                }
                let stableDur = Date().timeIntervalSince(firstExitCandidateAt!)
                if stableDur >= requiredExitStable && snapshot.menuBarVisible {
                    transitionToNormal()
                    optimisticShownAt = nil
                }
            }
        }
    }
    
    private func transitionToFullscreen() {
        guard fsState != .fullscreen else { return }
        fsState = .fullscreen
        enterConsistency = 0
        optimisticShownAt = nil
        hideForFullscreen()
    }
    
    private func transitionToNormal() {
        guard fsState == .fullscreen else { return }
        fsState = .normal
        enterConsistency = 0
        firstExitCandidateAt = nil
        optimisticShownAt = nil
        // If we already showed optimistically, fast fade already done; otherwise full show
        if alphaValue < 1 { showAfterFullscreen() }
    }
    
    // MARK: Snapshot details
    private struct FSSnapshot { let isFullscreen: Bool; let menuBarVisible: Bool }
    private func fullscreenSnapshotDetails() -> FSSnapshot {
        guard let screen = NSScreen.main else { return FSSnapshot(isFullscreen: false, menuBarVisible: false) }
        let frame = screen.frame
        let visible = screen.visibleFrame
        let menuBarDelta = frame.maxY - visible.maxY // height of menu bar if visible
        let dockDelta = visible.minY - frame.minY    // vertical dock gap at bottom when dock visible at bottom
        let menuBarVisible = menuBarDelta > 22
        if menuBarVisible { lastMenuBarVisibleAt = Date() }
        // Window list
        let options: CGWindowListOption = [.excludeDesktopElements, .optionOnScreenOnly]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return FSSnapshot(isFullscreen: false, menuBarVisible: menuBarVisible) }
        let selfPID = ProcessInfo.processInfo.processIdentifier
        var exactCover = false
        var tallCount = 0
        for info in list {
            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let w = bounds["Width"], let h = bounds["Height"],
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = info[kCGWindowLayer as String] as? Int else { continue }
            if pid == selfPID { continue }
            if layer != 0 { continue }
            if abs(w - frame.width) < 2 && abs(h - frame.height) < 2 { exactCover = true }
            if abs(h - frame.height) < 2 && w > frame.width * 0.40 { tallCount += 1 }
        }
        let coveringDetected = exactCover || tallCount >= 2
        // Capture baselines only when clearly NOT fullscreen and menu bar visible (reduces risk of capturing fullscreen state)
        if !coveringDetected && menuBarVisible && !baselineCaptured && (menuBarDelta > significantDelta || dockDelta > significantDelta) {
            baselineMenuBarDelta = menuBarDelta
            baselineDockDelta = dockDelta
            baselineCaptured = true
            if debugFS { print("[FS] baseline captured menuBarΔ=\(baselineMenuBarDelta) dockΔ=\(baselineDockDelta)") }
        }
        // Autohide scenario: menu bar hidden (or auto), dock hidden, no covering window -> NOT fullscreen
        let menuBarCollapsed = abs(menuBarDelta) <= deltaTolerance
        let dockCollapsed = abs(dockDelta) <= deltaTolerance
        var autohideFalsePositive = false
        if !coveringDetected && !menuBarVisible {
            if baselineCaptured && (baselineMenuBarDelta > significantDelta || baselineDockDelta > significantDelta) && menuBarCollapsed && dockCollapsed {
                autohideFalsePositive = true
            }
        }
        let isFullscreen = coveringDetected && !autohideFalsePositive
        if debugFS {
            print("[FS] mΔ=\(Int(menuBarDelta)) dΔ=\(Int(dockDelta)) menuBarVis=\(menuBarVisible) cover=\(coveringDetected) autohideFP=\(autohideFalsePositive) -> FS=\(isFullscreen)")
        }
        return FSSnapshot(isFullscreen: isFullscreen, menuBarVisible: menuBarVisible)
    }
    
    // MARK: Hide/Show helpers
    private func hideForFullscreen() {
        if alphaValue == 0 { orderOut(nil); return }
        ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            animator().alphaValue = 0
        } completionHandler: { [weak self] in self?.orderOut(nil) }
    }
    private func fastShowAfterFullscreen() {
        // Fast reappearance animation
        ignoresMouseEvents = false
        if isVisible && alphaValue >= 0.95 { return }
        alphaValue = 0
        orderFrontRegardless(); makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.08
            animator().alphaValue = 1
        }
    }
    private func showAfterFullscreen() {
        ignoresMouseEvents = false
        if alphaValue == 1 && isVisible { return }
        alphaValue = 0
        orderFrontRegardless(); makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            animator().alphaValue = 1
        }
    }
    
    // MARK: Dock / layout (unchanged from before)
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
