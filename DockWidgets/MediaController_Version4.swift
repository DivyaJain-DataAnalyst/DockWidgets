import Foundation
import Cocoa

// Move NowPlayingInfo struct to the top-level scope so it is visible everywhere
struct NowPlayingInfo {
    let title: String
    let artist: String
    let album: String
    let app: AppleScriptMediaController.MediaApp
    
    
    var displayText: String {
        if album.isEmpty {
            return "\(title) – \(artist)"
        } else {
            return "\(title) – \(artist) (\(album))"
        }
    }
}

protocol AppleScriptMediaControllerDelegate: AnyObject {
    func mediaController(_ controller: AppleScriptMediaController, didUpdateNowPlaying info: NowPlayingInfo?)
    func mediaController(_ controller: AppleScriptMediaController, didUpdatePlaybackState isPlaying: Bool)
}

class ViewController: NSViewController {
    private var mediaController: AppleScriptMediaController?

    override func viewDidLoad() {
        super.viewDidLoad()
        
        mediaController = AppleScriptMediaController.shared
        mediaController?.delegate = self
        mediaController?.requestPermissionsExplicitly()
        mediaController?.startMonitoring() // Start monitoring here
    }
}

extension ViewController: AppleScriptMediaControllerDelegate {
    func mediaController(_ controller: AppleScriptMediaController, didUpdateNowPlaying info: NowPlayingInfo?) {
        //print("Now playing info updated: \(info?.displayText ?? \"No music playing\")")
    }

    func mediaController(_ controller: AppleScriptMediaController, didUpdatePlaybackState isPlaying: Bool) {
        //print("Playback state updated: \(isPlaying ? \"Playing\" : \"Paused\")")
    }
}

class AppleScriptMediaController: ObservableObject {
    static let shared = AppleScriptMediaController()
    // Optional debug logging
    var enableLogging = false
    
    weak var delegate: AppleScriptMediaControllerDelegate?
    
    @Published var currentTrack: NowPlayingInfo?
    @Published var isPlaying = false
    @Published var currentApp: MediaApp = .none
    
    private var updateTimer: Timer?
    // Cache last valid Music track to survive temporary AppleScript failures (macOS 26 regression workaround)
    private var lastMusicTrack: NowPlayingInfo?
    private var lastMusicTrackTimestamp: Date?
    private var lastMusicNotificationTime: Date?
    private let notificationFreshInterval: TimeInterval = 5
    private let musicTrackStaleInterval: TimeInterval = 45 // extended from 10s to better mask Tahoe gaps
    
    // Track whether monitoring already started to avoid duplicate timers
    private var hasStartedMonitoring = false
    // Flag for whether we received at least one Music distributed notification
    private var receivedMusicNotification = false
    
    enum MediaApp: String, CaseIterable {
        case music = "Music"
        case spotify = "Spotify"
        case none = "None"
        
        var displayName: String {
            switch self {
            case .music: return "Apple Music"
            case .spotify: return "Spotify"
            case .none: return "No music playing"
            }
        }
    }
    func requestPermissionsExplicitly() {
        // Force permission dialog by directly accessing the applications
        let musicPermissionScript = """
        tell application "System Events"
            tell process "Music"
                return "permission requested"
            end tell
        end tell
        """
        
        // These will trigger permission dialogs
        executeAppleScript(musicPermissionScript)
    }
    func startMonitoring() {
        if hasStartedMonitoring { return }
        hasStartedMonitoring = true
        updateTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            self?.periodicUpdate()
        }
        periodicUpdate()
    }
    
    private func periodicUpdate() {
        let musicTrackIsFresh = isLastMusicTrackFresh()
        if !(receivedMusicNotification && musicTrackIsFresh && (Date().timeIntervalSince(lastMusicNotificationTime ?? .distantPast) < notificationFreshInterval)) {
            if let musicInfo = getMusicInfo() {
                currentTrack = musicInfo
                currentApp = .music
                isPlaying = isMusicPlaying()
                delegate?.mediaController(self, didUpdateNowPlaying: musicInfo)
                delegate?.mediaController(self, didUpdatePlaybackState: isPlaying)
            } else if currentTrack == nil && musicTrackIsFresh { // fallback to cache
                currentTrack = lastMusicTrack
                currentApp = .music
                delegate?.mediaController(self, didUpdateNowPlaying: lastMusicTrack)
            }
        }
        // Always poll Spotify (lower cost) – could optimize later
        if let spotifyInfo = getSpotifyInfo() {
            currentTrack = spotifyInfo
            currentApp = .spotify
            isPlaying = isSpotifyPlaying()
            delegate?.mediaController(self, didUpdateNowPlaying: spotifyInfo)
            delegate?.mediaController(self, didUpdatePlaybackState: isPlaying)
        } else if currentApp == .spotify && !isSpotifyPlaying() {
            // Spotify stopped; if Music still playing keep that, else clear
            if !(isMusicPlaying()) && currentApp == .spotify && !(isLastMusicTrackFresh()) {
                currentTrack = nil
                currentApp = .none
                isPlaying = false
                delegate?.mediaController(self, didUpdateNowPlaying: nil)
                delegate?.mediaController(self, didUpdatePlaybackState: false)
            } else if isLastMusicTrackFresh() { // revert to cached music track
                currentTrack = lastMusicTrack
                currentApp = .music
                delegate?.mediaController(self, didUpdateNowPlaying: lastMusicTrack)
            }
        }
        if enableLogging { print("[MediaController] periodicUpdate fresh=\(musicTrackIsFresh) notif=\(receivedMusicNotification)") }
    }
    
    // Disable old updateNowPlaying entry point (leave for compatibility if referenced elsewhere)
    private func updateNowPlaying() { periodicUpdate() }
    
    private init() { // enforce singleton
        setupMusicDistributedNotifications()
    }
    
    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }
    
    private func setupMusicDistributedNotifications() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(self, selector: #selector(handleMusicPlayerInfo(_:)), name: NSNotification.Name("com.apple.Music.playerInfo"), object: nil)
    }
    
    @objc private func handleMusicPlayerInfo(_ notification: Notification) {
        guard let info = notification.userInfo else { return }
        receivedMusicNotification = true
        lastMusicNotificationTime = Date()
        let state = (info["Player State"] as? String) ?? ""
        let isPlayingNow = (state == "Playing")
        if isPlaying != isPlayingNow {
            isPlaying = isPlayingNow
            delegate?.mediaController(self, didUpdatePlaybackState: isPlaying)
        }
        if state == "Stopped" {
            // Only clear if cache is stale and Spotify not active
            if currentApp == .music && !isLastMusicTrackFresh() && currentApp != .spotify {
                currentTrack = nil
                currentApp = .none
                delegate?.mediaController(self, didUpdateNowPlaying: nil)
            }
            return
        }
        // For pauses or transient metadata loss keep showing last track if still fresh
        if state != "Playing" { // e.g. Paused
            if currentTrack == nil, isLastMusicTrackFresh() {
                currentTrack = lastMusicTrack
                currentApp = .music
                delegate?.mediaController(self, didUpdateNowPlaying: lastMusicTrack)
            }
        }
        if let name = info["Name"] as? String, !name.isEmpty {
            let artist = (info["Artist"] as? String) ?? ""
            let album = (info["Album"] as? String) ?? ""
            let trackInfo = NowPlayingInfo(title: name, artist: artist, album: album, app: .music)
            currentTrack = trackInfo
            currentApp = .music
            lastMusicTrack = trackInfo
            lastMusicTrackTimestamp = Date()
            delegate?.mediaController(self, didUpdateNowPlaying: trackInfo)
        } else {
            // Missing metadata; keep cached if fresh
            if currentTrack == nil, isLastMusicTrackFresh() {
                currentTrack = lastMusicTrack
                currentApp = .music
                delegate?.mediaController(self, didUpdateNowPlaying: lastMusicTrack)
            }
        }
        if enableLogging { print("[MediaController] Music notification received: state=\(state) info=\(notification.userInfo ?? [:])") }
    }
    
    // MARK: - Apple Music
    
    private func getMusicInfo() -> NowPlayingInfo? {
        // Robust retrieval with retries due to macOS 26 AppleScript inconsistencies
        var resultString: String? = nil
        for attempt in 0..<3 {
            resultString = executeAppleScript(musicInfoAppleScript)
            if let r = resultString, !r.isEmpty, r != "no track", !r.hasPrefix("error"), r != "not running", r != "not playing" { break }
            // If player is reported playing but metadata missing, brief delay then retry
            if attempt < 2 { usleep(120_000) }
        }
        guard let result = resultString, !result.isEmpty else { return fallbackMusicTrackIfValid() }
        if result == "no track" || result.hasPrefix("error") || result == "not running" || result == "not playing" { return fallbackMusicTrackIfValid() }
        let components = result.components(separatedBy: "|||")
        guard components.count >= 2 else { return fallbackMusicTrackIfValid() }
        let info = NowPlayingInfo(
            title: components[0],
            artist: components[1],
            album: components.count > 2 ? components[2] : "",
            app: .music
        )
        lastMusicTrack = info
        lastMusicTrackTimestamp = Date()
        return info
    }
    
    // AppleScript with stream title & safer existence checks
    // Returns one of:
    //   "title|||artist|||album" on success (album may be empty)
    //   "no track" / "not playing" / "not running" / "error: <details>"
    private var musicInfoAppleScript: String {
        return """
        if application "Music" is running then
            tell application "Music"
                try
                    set playerState to player state as text
                    if playerState is not "playing" then return "not playing"
                    set trackName to ""
                    set artistName to ""
                    set albumName to ""
                    if (exists current track) then
                        try
                            set trackName to (get name of current track)
                        end try
                        try
                            set artistName to (get artist of current track)
                        end try
                        try
                            set albumName to (get album of current track)
                        end try
                    else if (exists current stream title) then
                        set trackName to current stream title
                    end if
                    if trackName is "" then return "no track"
                    return trackName & "|||" & artistName & "|||" & albumName
                on error errMsg number errNum
                    return "error: " & errNum & ":" & errMsg
                end try
            end tell
        else
            return "not running"
        end if
        """
    }
    
    private func fallbackMusicTrackIfValid() -> NowPlayingInfo? {
        // Provide cached track if still fresh OR we just had a notification, even if Music AS temporarily fails
        if isLastMusicTrackFresh() {
            if let last = lastMusicTrack { return last }
        }
        return nil
    }
    private func isLastMusicTrackFresh(_ maxAge: TimeInterval? = nil) -> Bool {
        guard let ts = lastMusicTrackTimestamp else { return false }
        return Date().timeIntervalSince(ts) < (maxAge ?? musicTrackStaleInterval)
    }
    private func isMusicPlaying() -> Bool {
        let script = """
        tell application "Music"
            if it is running then
                try
                    return (player state is playing)
                on error
                    return false
                end try
            end if
        end tell
        return false
        """
        
        return executeAppleScript(script) == "true"
    }
    
    // MARK: - Spotify
    
    private func getSpotifyInfo() -> NowPlayingInfo? {
        let script = """
        if application "Spotify" is running then
            tell application "Spotify"
                try
                    set trackName to name of current track
                    set artistName to artist of current track
                    return trackName & "|||" & artistName
                on error errMsg
                    return "error: " & errMsg
                end try
            end tell
        else
            return "not running"
        end if
        """
        
        guard let result = executeAppleScript(script), !result.isEmpty else {
            return nil
        }
        
        if result == "not running" || result.hasPrefix("error") {
            //print("Spotify info: \(result)")
            return nil
        }
        
        let components = result.components(separatedBy: "|||")
        guard components.count >= 2 else { return nil }
        
        return NowPlayingInfo(
            title: components[0],
            artist: components[1],
            album: "",
            app: .spotify
        )
    }
    
    private func isSpotifyPlaying() -> Bool {
        let script = """
        tell application "Spotify"
            if it is running then
                return (player state is playing)
            end if
        end tell
        return false
        """
        
        return executeAppleScript(script) == "true"
    }
    
    // MARK: - Media Controls
    
    func playPause() {
        //print("playPause called")
        isPlaying.toggle()
            delegate?.mediaController(self, didUpdatePlaybackState: isPlaying)
        
        switch currentApp {
            
        case .music:
            executeAppleScript("tell application \"Music\" to playpause")
        case .spotify:
            executeAppleScript("tell application \"Spotify\" to playpause")
        case .none:
            break
        }
    }
    
    
    func nextTrack() {
        switch currentApp {
        case .music:
            executeAppleScript("tell application \"Music\" to next track")
        case .spotify:
            executeAppleScript("tell application \"Spotify\" to next track")
        case .none:
            break
        }
    }
    
    func previousTrack() {
        switch currentApp {
        case .music:
            executeAppleScript("tell application \"Music\" to previous track")
        case .spotify:
            executeAppleScript("tell application \"Spotify\" to previous track")
        case .none:
            break
        }
    }
    
    // MARK: - AppleScript Execution
    
    @discardableResult
    private func executeAppleScript(_ script: String) -> String? {
        //print("Executing AppleScript:")
        
        // Create the AppleScript
        guard let appleScript = NSAppleScript(source: script) else {
            //print("Failed to create AppleScript")
            return nil
        }
        
        var error: NSDictionary?
        
        // Execute the script
        let result = appleScript.executeAndReturnError(&error)
        
        if let error = error {
            //print("AppleScript error: \(error)")
            
            // Check if it's a permission error
            if let errorCode = error[NSAppleScript.errorNumber] as? Int {
                switch errorCode {
                case -1743: // errAEEventNotPermitted
                    DispatchQueue.main.async {
                        self.showPermissionAlert()
                    }
                case -1728: // errAENoSuchObject
                    print("Application not found or not running")
                default:
                    print("AppleScript error code: \(errorCode)")
                }
            }
            
            let errorInfo = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
            print("Error details: \(errorInfo)")
            return nil
        }
        if enableLogging { print("[MediaController] Executing AppleScript snippet length=\(script.count)") }
        let resultString = result.stringValue ?? ""
        return resultString.isEmpty ? nil : resultString
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Permission Required"
        alert.informativeText = "This app needs permission to control Music and Spotify. Please go to System Preferences > Security & Privacy > Privacy > Automation and enable access for this app."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Preferences")
        alert.addButton(withTitle: "Cancel")
        
        if alert.runModal() == .alertFirstButtonReturn {
            // Open System Preferences to Automation section
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
            NSWorkspace.shared.open(url)
        }
    }
}
