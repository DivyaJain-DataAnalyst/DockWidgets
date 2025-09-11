import Cocoa
import SwiftUI

// @NSApplicationMain removed - using main.swift instead
class AppDelegate: NSObject, NSApplicationDelegate {
    var overlayWindow: OverlayWindow? //main transparent window
    var widgetManager: WidgetManager?
    var preferencesWindow: PreferencesWindow? // Preferences window for settings
    
    override init() {
        super.init()
        //print("🎯 AppDelegate: init() called")
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        //print("🚀 AppDelegate: applicationDidFinishLaunching called")
        
        // Force the app to activate
        NSApp.activate(ignoringOtherApps: true)
        // Create the overlay window
        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        //print("📱 Screen frame: \(screenFrame)")
        
        overlayWindow = OverlayWindow(
            contentRect: screenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        //print("🪟 OverlayWindow created")
        
        widgetManager = WidgetManager(window: overlayWindow!)
        //print("📦 WidgetManager created")
        
        // Connect widget manager to window
        overlayWindow?.setWidgetManager(widgetManager!)
        //print("🔗 WidgetManager connected to window")
        
        // Request permissions
        requestPermissions()
    }
    
    func applicationWillFinishLaunching(_ notification: Notification) {
        //print("🔄 AppDelegate: applicationWillFinishLaunching called")
    }
    
    func applicationDidBecomeActive(_ notification: Notification) {
        //print("✅ AppDelegate: applicationDidBecomeActive called")
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false  // Keep app running even if windows are closed
    }
    
    @objc func showPreferences() {
        if preferencesWindow == nil {
            preferencesWindow = PreferencesWindow()
        }
        preferencesWindow?.makeKeyAndOrderFront(nil)
        preferencesWindow?.center()
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc func reloadWidgets() {
        // Recreate the widget manager to refresh all widgets
        if let window = overlayWindow {
            widgetManager = WidgetManager(window: window)
        }
    }
    
    private func requestPermissions() {
        // Check if accessibility permissions are already granted
        let checkOptPrompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
        let options = [checkOptPrompt: true]
        let accessEnabled = AXIsProcessTrustedWithOptions(options as CFDictionary?)
        
        if !accessEnabled {
            print("🔐 Accessibility permissions not granted - showing system dialog")
            
            // Show a user-friendly alert explaining why we need permissions
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let alert = NSAlert()
                alert.messageText = "Accessibility Permissions Required"
                alert.informativeText = "DockWidgets needs accessibility permissions to detect when apps are in fullscreen mode so it can hide widgets appropriately.\n\nPlease enable DockWidgets in System Settings > Privacy & Security > Accessibility."
                alert.alertStyle = .informational
                alert.addButton(withTitle: "Open System Settings")
                alert.addButton(withTitle: "Cancel")
                
                let response = alert.runModal()
                if response == .alertFirstButtonReturn {
                    // Open System Settings to Accessibility page
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        } else {
            print("✅ Accessibility permissions already granted")
        }
    }
}
