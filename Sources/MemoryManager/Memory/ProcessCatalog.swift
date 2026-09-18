import Foundation

enum ProcessKind: Sendable, Hashable {
    /// Ships with macOS.
    case system
    /// A regular app with a window.
    case app
    /// A child process working on behalf of an app.
    case helper
    /// Installed by the user, running in the background.
    case userBackground
    case unknown

    var label: String {
        switch self {
        case .system: return "macOS"
        case .app: return "App"
        case .helper: return "Helper"
        case .userBackground: return "Background"
        case .unknown: return ""
        }
    }
}

struct ProcessExplanation: Sendable, Hashable {
    let summary: String
    let kind: ProcessKind
    /// False when the text is inferred from the executable's location rather than
    /// being a description of this specific program.
    let isSpecific: Bool
}

/// Plain-language descriptions for processes people are likely to ask about — mostly
/// the Apple daemons that show up with cryptic names and non-trivial memory use.
///
/// Anything not listed falls back to a description derived from where the executable
/// lives, which is factual rather than guessed.
enum ProcessCatalog {
    static func explain(name: String, path: String, owner: String?, uid: uid_t) -> ProcessExplanation {
        if let known = known[name] {
            return ProcessExplanation(summary: known, kind: kind(for: name, path: path, uid: uid), isSpecific: true)
        }
        if let helper = helperExplanation(name: name, owner: owner) {
            return helper
        }
        return inferred(name: name, path: path, uid: uid)
    }

    // MARK: - Helper processes

    private static func helperExplanation(name: String, owner: String?) -> ProcessExplanation? {
        guard let owner else { return nil }
        // Chromium and Electron apps fan out into helpers whose role is in the name.
        if name.contains("(Renderer)") {
            return .init(summary: "Renders one tab or window of \(owner).", kind: .helper, isSpecific: true)
        }
        if name.contains("(GPU)") {
            return .init(summary: "Draws \(owner)'s graphics on the GPU.", kind: .helper, isSpecific: true)
        }
        if name.contains("(Plugin)") {
            return .init(summary: "Runs \(owner)'s extensions and plug-ins.", kind: .helper, isSpecific: true)
        }
        if name.contains("Crashpad") || name.contains("crashpad") {
            return .init(summary: "Waits to collect a crash report for \(owner).", kind: .helper, isSpecific: true)
        }
        if name.contains("Helper") || name.contains("Service") || name.contains("Agent") {
            return .init(summary: "A background helper belonging to \(owner).", kind: .helper, isSpecific: false)
        }
        return .init(summary: "Part of \(owner).", kind: .helper, isSpecific: false)
    }

    // MARK: - Location-based fallback

    private static func inferred(name: String, path: String, uid: uid_t) -> ProcessExplanation {
        if path.isEmpty {
            return .init(summary: "No executable path available.", kind: .unknown, isSpecific: false)
        }

        // A bundled XPC service names the app it serves in its own path.
        if path.contains(".xpc/"), let app = enclosingBundleName(path) {
            return .init(summary: "A background service used by \(app).", kind: .helper, isSpecific: false)
        }

        // An app bundle wins over the location rules below, so that Apple's own bundled
        // apps in /System/Applications read as apps rather than as system services.
        if let app = enclosingBundleName(path), !path.contains(".framework/") {
            let isApple = path.hasPrefix("/System/")
            if app == name {
                return .init(summary: "The \(app) app.", kind: .app, isSpecific: false)
            }
            return .init(
                summary: "Part of \(app).",
                kind: isApple ? .system : .app,
                isSpecific: false
            )
        }

        if let framework = frameworkName(path) {
            return .init(summary: "Part of Apple's \(framework) system framework.", kind: .system, isSpecific: false)
        }
        if path.hasPrefix("/System/") || path.hasPrefix("/usr/libexec/")
            || path.hasPrefix("/usr/sbin/") || path.hasPrefix("/sbin/") {
            return .init(summary: "A macOS system service.", kind: .system, isSpecific: false)
        }
        if path.hasPrefix("/Library/Apple/") {
            return .init(summary: "Part of Apple's built-in security tooling.", kind: .system, isSpecific: false)
        }
        if path.hasPrefix("/opt/homebrew/") || path.hasPrefix("/usr/local/") {
            return .init(summary: "Installed by Homebrew or another command-line tool.",
                         kind: .userBackground, isSpecific: false)
        }
        if uid == 0 {
            return .init(summary: "A background process running as root.", kind: .unknown, isSpecific: false)
        }
        return .init(summary: "A command-line program.", kind: .userBackground, isSpecific: false)
    }

    private static func enclosingBundleName(_ path: String) -> String? {
        guard let bundle = path.split(separator: "/").first(where: { $0.hasSuffix(".app") }) else {
            return nil
        }
        return String(bundle.dropLast(4))
    }

    private static func frameworkName(_ path: String) -> String? {
        guard path.contains("/System/Library/") else { return nil }
        guard let component = path.split(separator: "/").first(where: { $0.hasSuffix(".framework") }) else {
            return nil
        }
        return String(component.dropLast(10))
    }

    private static func kind(for name: String, path: String, uid: uid_t) -> ProcessKind {
        if appNames.contains(name) { return .app }
        if path.hasPrefix("/System/") || path.hasPrefix("/usr/") || path.hasPrefix("/sbin/")
            || path.isEmpty || uid == 0 {
            return .system
        }
        return .app
    }

    /// Catalogued names that are full apps rather than daemons.
    private static let appNames: Set<String> = [
        "Finder", "Dock", "Safari", "Google Chrome", "Firefox", "Terminal", "iTerm2",
        "Music", "Photos", "Mail", "Messages", "Notes", "Calendar", "Preview",
        "System Settings", "Activity Monitor", "Xcode", "Visual Studio Code", "Code",
        "Slack", "Telegram", "Discord", "Spotify", "Docker Desktop", "Memory Manager - MacOS",
    ]

    // MARK: - The catalog

    private static let known: [String: String] = [
        // --- Core system ---
        "kernel_task": "The macOS kernel itself. Its memory includes what drivers use; macOS also parks CPU time here to cool the machine down.",
        "launchd": "Process 1. Starts, supervises and restarts every other process on the system.",
        "logd": "Collects the unified system log that Console.app reads.",
        "notifyd": "Passes lightweight notifications between running processes.",
        "distnoted": "Delivers notifications between apps, such as a preference changing.",
        "cfprefsd": "Reads and writes app preference files on behalf of other processes.",
        "opendirectoryd": "Looks up user accounts, groups and login information.",
        "configd": "Manages network configuration and reacts when connections change.",
        "mDNSResponder": "Resolves DNS names and finds nearby devices and printers over Bonjour.",
        "diskarbitrationd": "Mounts and unmounts disks when volumes appear or are ejected.",
        "fseventsd": "Records file system changes so apps like Time Machine can see what changed.",
        "runningboardd": "Decides which processes stay awake, get suspended, or are shut down.",
        "powerd": "Manages sleep, wake and battery behaviour.",
        "thermalmonitord": "Watches temperature and asks the system to slow down when it gets hot.",
        "hidd": "Handles input from the keyboard, mouse and trackpad.",
        "coreaudiod": "The audio server. All sound in and out of the machine passes through it.",
        "usbd": "Manages connected USB devices.",
        "bluetoothd": "Runs the Bluetooth stack and connected Bluetooth devices.",
        "airportd": "Manages Wi-Fi connections and scanning.",
        "locationd": "Provides Location Services to apps that ask for your position.",
        "symptomsd": "Watches network quality to spot connections that are failing.",
        "systemstats": "Records system performance statistics over time.",
        "UserEventAgent": "Runs small system plug-ins that react to events like logging in or plugging in a device.",
        "securityd": "Handles keychain access and cryptographic operations.",
        "trustd": "Checks certificates to decide whether a server or app can be trusted.",
        "tccd": "Enforces privacy permissions. This is what asks whether an app may use your camera, mic or files.",
        "amfid": "Verifies an app's code signature when it launches.",
        "syspolicyd": "Gatekeeper. Decides whether a downloaded app is allowed to run.",
        "sandboxd": "Reports when a sandboxed app tries to do something it is not allowed to.",
        "secinitd": "Sets up the sandbox for an app as it starts.",
        "containermanagerd": "Manages the private folders sandboxed apps store their data in.",
        "ctkd": "Handles smart cards and hardware security tokens.",
        "coreauthd": "Runs authentication prompts such as Touch ID and password confirmations.",
        "dprivacyd": "Collects anonymised usage statistics using differential privacy.",

        // --- Spotlight and indexing ---
        "mds": "The Spotlight metadata server, which owns the search index.",
        "mds_stores": "Stores and queries the Spotlight search index. Memory grows with the size of your index.",
        "mdworker": "Extracts text and metadata from a file so Spotlight can find it.",
        "mdworker_shared": "Short-lived worker that reads files to build the Spotlight index. Several run at once after large file changes.",
        "corespotlightd": "Indexes content from inside apps, such as mail and messages, for Spotlight.",
        "Spotlight": "The Spotlight search interface and its results.",
        "parsecd": "Fetches the web and App Store suggestions that appear in Spotlight search.",
        "suggestd": "Builds on-device suggestions from your mail, contacts and browsing.",

        // --- Media and photos ---
        "mediaanalysisd": "Analyses photos and videos for objects, scenes and Live Text. Usually runs while the Mac is idle or charging.",
        "photoanalysisd": "Scans your Photos library for faces, places and Memories. Runs when the Mac is idle.",
        "photolibraryd": "Manages the Photos library database for the Photos app.",
        "VTDecoderXPCService": "Decodes video using the hardware video decoder.",
        "VTEncoderXPCService": "Encodes video using the hardware video encoder.",
        "MTLCompilerService": "Compiles Metal GPU shaders for an app. Many short-lived copies are normal.",
        "SpeechSynthesisServerXPC": "Generates spoken audio for text-to-speech voices.",
        "localspeechrecognition": "Performs speech recognition on the device rather than on a server.",
        "WallpaperDynamicExtension": "Draws dynamic and video desktop wallpapers.",
        "iconservicesagent": "Renders and caches the icons shown in Finder and the Dock.",
        "ColorSyncXPCAgent": "Applies colour profiles so colours match across displays and printers.",
        "com.apple.ColorSyncXPCAgent": "Applies colour profiles so colours match across displays and printers.",

        // --- Interface ---
        "WindowServer": "Draws and composites everything you see on screen. Its memory grows with display resolution, the number of displays, and how many windows are open.",
        "Finder": "The Finder: file windows, the Desktop, and the sidebar.",
        "Dock": "The Dock, Mission Control, and Launchpad.",
        "loginwindow": "Owns your login session and handles logging out, restarting and shutting down.",
        "ControlCenter": "Control Center and the status icons in the menu bar.",
        "NotificationCenter": "Notification banners and the widget panel.",
        "SystemUIServer": "Draws older-style menu bar extras.",
        "talagent": "Restores your windows to where they were the last time you quit an app.",
        "quicklookd": "Generates Quick Look previews when you press the space bar.",
        "QuickLookUIService": "Displays the Quick Look preview window.",
        "universalaccessd": "Provides the accessibility features, including VoiceOver and Zoom.",
        "accessibilityd": "Supports assistive features and apps that control the interface.",

        // --- Network, cloud and accounts ---
        "nsurlsessiond": "Performs downloads and uploads in the background for other apps.",
        "cloudd": "Syncs app data through iCloud (CloudKit).",
        "bird": "Syncs files in iCloud Drive and Desktop & Documents.",
        "apsd": "Keeps the connection to Apple's push notification service open.",
        "akd": "Handles Apple Account sign-in and authentication.",
        "identityservicesd": "Runs iMessage and FaceTime identity and delivery.",
        "contactsd": "Keeps the Contacts database in sync across your devices.",
        "calaccessd": "Provides calendar data to apps that request it.",
        "sharingd": "Runs AirDrop, Handoff, and Universal Clipboard.",
        "rapportd": "Lets your Mac discover and connect to your other Apple devices.",
        "nesessionmanager": "Manages VPN and network extension connections.",
        "netbiosd": "Makes the Mac visible to Windows file sharing.",
        "storedownloadd": "Downloads apps and updates from the App Store.",
        "appstoreagent": "Checks for and installs App Store updates.",
        "softwareupdated": "Checks for and downloads macOS updates.",
        "mobileassetd": "Downloads optional Apple content such as voices, dictionaries and models.",
        "backupd": "Runs Time Machine backups.",

        // --- Security scanning ---
        "XProtect": "Apple's built-in malware scanner.",
        "XProtectService": "Scans apps and files for known malware.",
        "XprotectService": "Scans apps and files for known malware.",
        "XProtectPluginService": "Part of Apple's built-in malware scanning.",

        // --- App infrastructure ---
        "lsd": "Launch Services: keeps track of which app opens which kind of file.",
        "pkd": "Manages app extensions and plug-ins.",
        "extensionkitservice": "Hosts an app extension in its own process.",
        "PlugInLibraryService": "Loads plug-ins on behalf of an app.",
        "nsattributedstringagent": "Converts rich text, such as HTML pasted into a document.",
        "ReportCrash": "Writes a crash report after an app quits unexpectedly.",
        "spindump": "Records a report when an app stops responding.",
        "geod": "Turns addresses into coordinates and back for Maps and other apps.",
        "com.apple.geod": "Turns addresses into coordinates and back for Maps and other apps.",
        "com.apple.audio.SandboxHelper": "Runs an audio plug-in in a sandbox so it cannot affect the rest of the system.",
        "com.apple.WebKit.WebContent": "Renders one web page. Safari and other WebKit apps use one of these per site.",
        "com.apple.WebKit.Networking": "Handles network requests for Safari and other WebKit apps.",
        "com.apple.WebKit.GPU": "Draws web page graphics on the GPU for WebKit apps.",

        // --- Common third-party ---
        "Google Chrome": "The Google Chrome browser's main process.",
        "chrome_crashpad_handler": "Waits to collect a crash report for Chrome.",
        "Code": "The Visual Studio Code editor's main process.",
        "Visual Studio Code": "The Visual Studio Code editor's main process.",
        "Docker": "Docker Desktop.",
        "com.docker.backend": "Runs the Docker virtual machine that containers execute inside.",
        "MemoryManager": "This app.",
        "Memory Manager - MacOS": "This app.",
    ]
}
