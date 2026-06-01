import AppKit
import Foundation

private enum DefaultsKey {
    static let use24Hour = "use24Hour"
    static let shownUpdateResultSignature = "shownUpdateResultSignature"
}

private let githubLatestReleaseURL = URL(string: "https://api.github.com/repos/r2d2-off/mac-clock/releases/latest")!
private let defaultStatusPath = "/Library/Application Support/IPTime/status.json"
private let statusURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["IPTIME_STATUS_PATH"] ?? defaultStatusPath)
private let statusSupportURL = statusURL.deletingLastPathComponent()
private let regionCheckStateURL = statusSupportURL.appendingPathComponent("check-state.json")
private let userSupportURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/IPTime", isDirectory: true)
private let updateRequestURL = userSupportURL.appendingPathComponent("update-request.json")
private let updateResultURL = userSupportURL.appendingPathComponent("update-result.json")
private let recheckRequestURL = userSupportURL.appendingPathComponent("recheck-request.json")
private let stopRequestURL = userSupportURL.appendingPathComponent("stop-request.json")
private let daemonStopStateURL = userSupportURL.appendingPathComponent("daemon-stop-state.json")
private let configURL = userSupportURL.appendingPathComponent("config.json")
private let regionSyncRestoreStateURL = userSupportURL.appendingPathComponent("region-sync-restore-state.json")
private let userPreferenceBackupURL = userSupportURL.appendingPathComponent("original-user-preferences.json")
private let userPreferenceRestoreScriptURL = userSupportURL.appendingPathComponent("restore-user-preferences.sh")
private let moscowTimeZone = TimeZone(identifier: "Europe/Moscow")!
private let launchDaemonLabel = "local.iptime.daemon"
private let launchDaemonURL = URL(fileURLWithPath: "/Library/LaunchDaemons/\(launchDaemonLabel).plist")
private let launchAgentLabel = "local.iptime.menubar"
private let launchAgentURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")
private let defaultRegionCheckIntervalSeconds = 600
private let regionCheckIntervalOptions = [60, 300, 600, 900, 1_800, 3_600]
private let statusRefreshInterval: TimeInterval = 5
private let activeCheckStatusRefreshInterval: TimeInterval = 1
private let uiRefreshInterval: TimeInterval = 0.25
private let manualRecheckTimeout: TimeInterval = 120
private let regionCheckStateMaxAge: TimeInterval = 120
private let completedCheckIndicatorDuration: TimeInterval = 1.5
private let daemonStopSettleTimeout: TimeInterval = 8
private let daemonStopSettlePollInterval: TimeInterval = 0.1
private let userPreferenceKeysToBackup = [
    "AppleLanguages",
    "AppleLocale",
    "AppleMetricUnits",
    "AppleMeasurementUnits",
    "AppleTemperatureUnit",
    "AppleFirstWeekday"
]

private enum StatusActivityIndicator {
    case none
    case checking
    case completed(Date)

    var isVisible: Bool {
        switch self {
        case .none:
            return false
        case .checking, .completed:
            return true
        }
    }
}

private struct StatusSegment {
    let flag: String
    let primary: String
    let detail: String?
    let detailFirst: Bool
    let isError: Bool
    let activity: StatusActivityIndicator

    init(
        flag: String,
        primary: String,
        detail: String?,
        detailFirst: Bool,
        isError: Bool,
        activity: StatusActivityIndicator = .none
    ) {
        self.flag = flag
        self.primary = primary
        self.detail = detail
        self.detailFirst = detailFirst
        self.isError = isError
        self.activity = activity
    }

    var summary: String {
        let flagPart = flag.isEmpty ? nil : flag
        if detailFirst {
            return [flagPart, detail, primary].compactMap { $0 }.joined(separator: " ")
        }

        return [flagPart, primary, detail].compactMap { $0 }.joined(separator: " ")
    }
}

private struct StatusDisplay {
    let segments: [StatusSegment]
    let summary: String
}

private struct IPTimeStatus: Decodable {
    let generatedAt: String?
    let ip: String?
    let city: String?
    let region: String?
    let countryCode: String?
    let country: String?
    let timeZone: String?
    let locale: String?
    let measurementUnits: String?
    let metricUnits: Bool?
    let temperatureUnit: String?
    let firstWeekday: Int?
    let activeUser: String?
    let error: String?
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: String?
    let assets: [GitHubReleaseAsset]

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets
    }
}

private struct GitHubReleaseAsset: Decodable {
    let name: String
    let browserDownloadURL: String

    private enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

private struct UpdateCandidate {
    let version: String
    let assetName: String
    let downloadURL: String
    let releaseURL: String?
}

private struct UpdateRequest: Codable {
    let requestedAt: String
    let version: String
    let assetName: String
    let downloadURL: String
}

private struct UpdateResult: Codable {
    let generatedAt: String
    let version: String
    let status: String
    let message: String
}

private struct RecheckRequest: Codable {
    let requestedAt: String
}

private struct StopRequest: Codable {
    let requestedAt: String
}

private struct DaemonStopState: Codable {
    let requestedAt: String
}

private struct HomeClockConfig: Codable {
    let mode: String
    let label: String
    let countryCode: String?
    let timeZoneIdentifier: String?
    let offsetMinutes: Int?
}

private struct RegionCheckState: Codable {
    let startedAt: String
    let completedAt: String?
    let trigger: String?
}

private struct IPTimeConfig: Codable {
    let regionCheckIntervalSeconds: Int
    let homeClock: HomeClockConfig?
    let regionalPermissions: RegionalPermissions?

    init(regionCheckIntervalSeconds: Int, homeClock: HomeClockConfig?, regionalPermissions: RegionalPermissions = .none) {
        self.regionCheckIntervalSeconds = regionCheckIntervalSeconds
        self.homeClock = homeClock
        self.regionalPermissions = regionalPermissions
    }
}

private struct RegionalPermissions: Codable, Equatable {
    let timeZone: Bool
    let locale: Bool
    let measurementUnits: Bool
    let temperatureUnit: Bool
    let firstWeekday: Bool

    static let none = RegionalPermissions(
        timeZone: false,
        locale: false,
        measurementUnits: false,
        temperatureUnit: false,
        firstWeekday: false
    )

    var anyEnabled: Bool {
        timeZone || userPreferencesEnabled
    }

    var userPreferencesEnabled: Bool {
        locale || measurementUnits || temperatureUnit || firstWeekday
    }

    init(
        timeZone: Bool = false,
        locale: Bool = false,
        measurementUnits: Bool = false,
        temperatureUnit: Bool = false,
        firstWeekday: Bool = false
    ) {
        self.timeZone = timeZone
        self.locale = locale
        self.measurementUnits = measurementUnits
        self.temperatureUnit = temperatureUnit
        self.firstWeekday = firstWeekday
    }

    private enum CodingKeys: String, CodingKey {
        case timeZone
        case locale
        case measurementUnits
        case temperatureUnit
        case firstWeekday
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timeZone = try container.decodeIfPresent(Bool.self, forKey: .timeZone) ?? false
        locale = try container.decodeIfPresent(Bool.self, forKey: .locale) ?? false
        measurementUnits = try container.decodeIfPresent(Bool.self, forKey: .measurementUnits) ?? false
        temperatureUnit = try container.decodeIfPresent(Bool.self, forKey: .temperatureUnit) ?? false
        firstWeekday = try container.decodeIfPresent(Bool.self, forKey: .firstWeekday) ?? false
    }

    func setting(_ key: RegionalPermissionKey, to value: Bool) -> RegionalPermissions {
        switch key {
        case .timeZone:
            return RegionalPermissions(timeZone: value, locale: locale, measurementUnits: measurementUnits, temperatureUnit: temperatureUnit, firstWeekday: firstWeekday)
        case .locale:
            return RegionalPermissions(timeZone: timeZone, locale: value, measurementUnits: measurementUnits, temperatureUnit: temperatureUnit, firstWeekday: firstWeekday)
        case .measurementUnits:
            return RegionalPermissions(timeZone: timeZone, locale: locale, measurementUnits: value, temperatureUnit: temperatureUnit, firstWeekday: firstWeekday)
        case .temperatureUnit:
            return RegionalPermissions(timeZone: timeZone, locale: locale, measurementUnits: measurementUnits, temperatureUnit: value, firstWeekday: firstWeekday)
        case .firstWeekday:
            return RegionalPermissions(timeZone: timeZone, locale: locale, measurementUnits: measurementUnits, temperatureUnit: temperatureUnit, firstWeekday: value)
        }
    }

    func isEnabled(_ key: RegionalPermissionKey) -> Bool {
        switch key {
        case .timeZone:
            return timeZone
        case .locale:
            return locale
        case .measurementUnits:
            return measurementUnits
        case .temperatureUnit:
            return temperatureUnit
        case .firstWeekday:
            return firstWeekday
        }
    }
}

private enum RegionalPermissionKey: String, CaseIterable {
    case timeZone
    case locale
    case measurementUnits
    case temperatureUnit
    case firstWeekday

    var menuTitle: String {
        switch self {
        case .timeZone:
            return "System Time Zone"
        case .locale:
            return "Locale"
        case .measurementUnits:
            return "Measurement Units"
        case .temperatureUnit:
            return "Temperature Unit"
        case .firstWeekday:
            return "First Weekday"
        }
    }
}

private struct RegionSyncRestoreState: Encodable {
    let restoredAt: String
}

private struct UserPreferenceBackup: Codable {
    let createdAt: String
    let user: String
    let preferences: [String: UserPreferenceBackupValue]
}

private struct UserPreferenceBackupValue: Codable {
    enum Kind: String, Codable {
        case missing
        case string
        case bool
        case int
        case stringArray
    }

    let kind: Kind
    let stringValue: String?
    let boolValue: Bool?
    let intValue: Int?
    let stringArrayValue: [String]?

    static func missing() -> UserPreferenceBackupValue {
        UserPreferenceBackupValue(kind: .missing, stringValue: nil, boolValue: nil, intValue: nil, stringArrayValue: nil)
    }

    static func string(_ value: String) -> UserPreferenceBackupValue {
        UserPreferenceBackupValue(kind: .string, stringValue: value, boolValue: nil, intValue: nil, stringArrayValue: nil)
    }

    static func bool(_ value: Bool) -> UserPreferenceBackupValue {
        UserPreferenceBackupValue(kind: .bool, stringValue: nil, boolValue: value, intValue: nil, stringArrayValue: nil)
    }

    static func int(_ value: Int) -> UserPreferenceBackupValue {
        UserPreferenceBackupValue(kind: .int, stringValue: nil, boolValue: nil, intValue: value, stringArrayValue: nil)
    }

    static func stringArray(_ value: [String]) -> UserPreferenceBackupValue {
        UserPreferenceBackupValue(kind: .stringArray, stringValue: nil, boolValue: nil, intValue: nil, stringArrayValue: value)
    }
}

private enum UserDefaultExpectedValue {
    case string(String)
    case bool(Bool)
    case int(Int)
}

private struct UserRegionalPreferences {
    let signature: String
    let permissions: RegionalPermissions
    let locale: String
    let metricUnits: Bool
    let measurementUnits: String
    let temperatureUnit: String
    let firstWeekday: Int
}

private enum UserRegionalPreferencesSyncRequest {
    case apply(UserRegionalPreferences)
    case restore
}

private enum UserRegionalPreferencesSyncResult {
    case applied(String)
    case restored
    case skipped
    case failed(String)
}

private struct HomeClockOption {
    let id: String
    let menuTitle: String
    let config: HomeClockConfig
}

private struct ResolvedHomeClock {
    let symbol: String
    let label: String
    let timeZone: TimeZone
}

private enum HomeClockMode {
    static let timeZone = "timeZone"
    static let fixedOffset = "fixedOffset"
}

private let defaultHomeClockConfig = HomeClockConfig(
    mode: HomeClockMode.timeZone,
    label: "Moscow",
    countryCode: "RU",
    timeZoneIdentifier: "Europe/Moscow",
    offsetMinutes: nil
)

private let homeClockPresetOptions = [
    HomeClockOption(id: "tz:Europe/Moscow", menuTitle: "Moscow", config: HomeClockConfig(mode: HomeClockMode.timeZone, label: "Moscow", countryCode: "RU", timeZoneIdentifier: "Europe/Moscow", offsetMinutes: nil)),
    HomeClockOption(id: "tz:America/Los_Angeles", menuTitle: "California", config: HomeClockConfig(mode: HomeClockMode.timeZone, label: "California", countryCode: "US", timeZoneIdentifier: "America/Los_Angeles", offsetMinutes: nil)),
    HomeClockOption(id: "tz:America/New_York", menuTitle: "New York", config: HomeClockConfig(mode: HomeClockMode.timeZone, label: "New York", countryCode: "US", timeZoneIdentifier: "America/New_York", offsetMinutes: nil)),
    HomeClockOption(id: "tz:Asia/Dubai", menuTitle: "Dubai", config: HomeClockConfig(mode: HomeClockMode.timeZone, label: "Dubai", countryCode: "AE", timeZoneIdentifier: "Asia/Dubai", offsetMinutes: nil)),
    HomeClockOption(id: "tz:Asia/Shanghai", menuTitle: "Shanghai", config: HomeClockConfig(mode: HomeClockMode.timeZone, label: "Shanghai", countryCode: "CN", timeZoneIdentifier: "Asia/Shanghai", offsetMinutes: nil)),
    HomeClockOption(id: "tz:Asia/Singapore", menuTitle: "Singapore", config: HomeClockConfig(mode: HomeClockMode.timeZone, label: "Singapore", countryCode: "SG", timeZoneIdentifier: "Asia/Singapore", offsetMinutes: nil)),
    HomeClockOption(id: "tz:Asia/Bangkok", menuTitle: "Bangkok", config: HomeClockConfig(mode: HomeClockMode.timeZone, label: "Bangkok", countryCode: "TH", timeZoneIdentifier: "Asia/Bangkok", offsetMinutes: nil)),
    HomeClockOption(id: "tz:Europe/Berlin", menuTitle: "Berlin", config: HomeClockConfig(mode: HomeClockMode.timeZone, label: "Berlin", countryCode: "DE", timeZoneIdentifier: "Europe/Berlin", offsetMinutes: nil)),
    HomeClockOption(id: "tz:Europe/Amsterdam", menuTitle: "Amsterdam", config: HomeClockConfig(mode: HomeClockMode.timeZone, label: "Amsterdam", countryCode: "NL", timeZoneIdentifier: "Europe/Amsterdam", offsetMinutes: nil)),
    HomeClockOption(id: "tz:Europe/Paris", menuTitle: "Paris", config: HomeClockConfig(mode: HomeClockMode.timeZone, label: "Paris", countryCode: "FR", timeZoneIdentifier: "Europe/Paris", offsetMinutes: nil)),
    HomeClockOption(id: "tz:Europe/London", menuTitle: "London", config: HomeClockConfig(mode: HomeClockMode.timeZone, label: "London", countryCode: "GB", timeZoneIdentifier: "Europe/London", offsetMinutes: nil)),
    HomeClockOption(id: "tz:Europe/Warsaw", menuTitle: "Warsaw", config: HomeClockConfig(mode: HomeClockMode.timeZone, label: "Warsaw", countryCode: "PL", timeZoneIdentifier: "Europe/Warsaw", offsetMinutes: nil)),
    HomeClockOption(id: "tz:Asia/Tokyo", menuTitle: "Tokyo", config: HomeClockConfig(mode: HomeClockMode.timeZone, label: "Tokyo", countryCode: "JP", timeZoneIdentifier: "Asia/Tokyo", offsetMinutes: nil))
]

private let fixedUTCOffsetOptions = [
    -720, -660, -600, -570, -540, -480, -420, -360, -300, -240,
    -210, -180, -150, -120, -60, 0, 60, 120, 180, 210, 240, 270,
    300, 330, 345, 360, 390, 420, 480, 525, 540, 570, 600, 630,
    660, 720, 765, 780, 825, 840
]

private enum UpdateState {
    case idle
    case checking
    case upToDate(String)
    case available(UpdateCandidate)
    case requested(String)
    case failed(String)
}

private enum UpdateCheckOutcome {
    case alreadyChecking
    case updateInProgress(String)
    case upToDate(String)
    case available(UpdateCandidate)
    case failed(String)
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store = UserDefaults.standard
    private let regionalPreferencesQueue = DispatchQueue(label: "local.iptime.regional-preferences")
    private var statusView: StatusBarView?
    private var timer: Timer?
    private var status: IPTimeStatus?
    private var regionCheckState: RegionCheckState?
    private var statusReadError: String?
    private var daemonStartError: String?
    private var lastStatusRead = Date.distantPast
    private var config = IPTimeConfig(regionCheckIntervalSeconds: defaultRegionCheckIntervalSeconds, homeClock: defaultHomeClockConfig)
    private var manualRecheckRequestedAt: Date?
    private var manualRecheckError: String?
    private var updateState: UpdateState = .idle
    private var lastUpdateCheck = Date.distantPast
    private var updateCheckInFlight = false
    private var regionalPreferencesSyncInFlight = false
    private var pendingRegionalPreferencesSyncRequest: UserRegionalPreferencesSyncRequest?
    private var lastAppliedRegionalPreferencesSignature: String?
    private var lastUpdateResultSignature: String?
    private var latestUpdateResult: UpdateResult?
    private var updateProgressWindow: NSWindow?
    private weak var updateProgressTitle: NSTextField?
    private weak var updateProgressLabel: NSTextField?
    private weak var updateProgressIndicator: NSProgressIndicator?

    private lazy var timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private lazy var dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d"
        return formatter
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if store.object(forKey: DefaultsKey.use24Hour) == nil {
            store.set(true, forKey: DefaultsKey.use24Hour)
        }

        ensureLaunchAgent()
        if handOffToLaunchAgentIfNeeded() {
            return
        }

        settlePendingDaemonStopIfNeeded()
        loadConfig()
        loadPendingManualRecheckState()

        let statusView = StatusBarView()
        statusView.toolTip = "IP time / Moscow time"
        statusView.onClick = { [weak self, weak statusView] in
            guard let self, let statusView else {
                return
            }

            self.showMenu(from: statusView)
        }
        self.statusView = statusView
        statusItem.view = statusView

        ensureLaunchDaemonRunning()
        loadStatus()
        loadRegionCheckState()
        loadPendingUpdateState()
        buildMenu()
        updateStatusTitle()

        timer = Timer.scheduledTimer(timeInterval: uiRefreshInterval, target: self, selector: #selector(timerFired), userInfo: nil, repeats: true)

        Task { [weak self] in
            await self?.checkForUpdates(silent: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }

    private var statusFont: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
    }

    private func ensureLaunchAgent() {
        let executableURL = Bundle.main.executableURL
            ?? URL(fileURLWithPath: "/Applications/IP Time.app/Contents/MacOS/DualTimeMenuBar")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(launchAgentLabel)</string>
            <key>EnvironmentVariables</key>
            <dict>
                <key>IPTIME_LAUNCH_AGENT</key>
                <string>1</string>
            </dict>
            <key>ProgramArguments</key>
            <array>
                <string>\(executableURL.path)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>LimitLoadToSessionType</key>
            <string>Aqua</string>
            <key>StandardOutPath</key>
            <string>\(home)/Library/Logs/IPTimeMenuBar.out.log</string>
            <key>StandardErrorPath</key>
            <string>\(home)/Library/Logs/IPTimeMenuBar.err.log</string>
        </dict>
        </plist>
        """

        do {
            let data = Data(plist.utf8)
            if let existing = try? Data(contentsOf: launchAgentURL), existing == data {
                return
            }

            try FileManager.default.createDirectory(at: launchAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: launchAgentURL, options: .atomic)
        } catch {
            statusReadError = "Failed to install login item: \(error.localizedDescription)"
        }
    }

    private func handOffToLaunchAgentIfNeeded() -> Bool {
        guard !isRunningAsLaunchAgent else {
            return false
        }

        if !isLaunchAgentLoaded() {
            let result = runProcess(path: "/bin/launchctl", arguments: ["bootstrap", launchAgentDomain, launchAgentURL.path])
            if !result.success && !result.message.contains("Service is already loaded") {
                statusReadError = "Failed to start login item: \(result.message)"
                return false
            }
        }

        _ = runProcess(path: "/bin/launchctl", arguments: ["enable", launchAgentService])
        if !isLaunchAgentRunning() {
            _ = runProcess(path: "/bin/launchctl", arguments: ["kickstart", launchAgentService])
        }

        NSApp.terminate(nil)
        return true
    }

    private var isRunningAsLaunchAgent: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["IPTIME_LAUNCH_AGENT"] == "1"
            || environment["XPC_SERVICE_NAME"] == launchAgentLabel
            || isCurrentProcessLaunchAgentService
    }

    private var isCurrentProcessLaunchAgentService: Bool {
        let result = runProcess(path: "/bin/launchctl", arguments: ["print", launchAgentService])
        return result.success && result.message.contains("pid = \(getpid())")
    }

    private var launchAgentDomain: String {
        "gui/\(getuid())"
    }

    private var launchAgentService: String {
        "\(launchAgentDomain)/\(launchAgentLabel)"
    }

    private func isLaunchAgentLoaded() -> Bool {
        runProcess(path: "/bin/launchctl", arguments: ["print", launchAgentService]).success
    }

    private func isLaunchAgentRunning() -> Bool {
        let result = runProcess(path: "/bin/launchctl", arguments: ["print", launchAgentService])
        return result.success && result.message.contains("state = running")
    }

    private var countryCode: String {
        let stored = status?.countryCode?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let stored, !stored.isEmpty else {
            return "?"
        }

        return stored.uppercased()
    }

    private var ipLabel: String {
        nonEmpty(status?.ip) ?? "IP"
    }

    private var displayedError: String? {
        if let statusError = status?.error, !statusError.isEmpty {
            return statusError
        }

        return statusReadError
    }

    private var regionalChangesAllowed: Bool {
        regionalPermissions.anyEnabled
    }

    private var regionalPermissions: RegionalPermissions {
        config.regionalPermissions ?? .none
    }

    private var hasIPLookupError: Bool {
        status?.error != nil && nonEmpty(status?.ip) == nil
    }

    @objc private func timerFired() {
        loadUpdateResult(showRecentWindow: true)
        loadRegionCheckState()
        expireManualRecheckIfNeeded()

        let refreshInterval = showsIPActivityIndicator ? activeCheckStatusRefreshInterval : statusRefreshInterval
        if Date().timeIntervalSince(lastStatusRead) >= refreshInterval {
            loadStatus()
            buildMenu()
        }

        if Date().timeIntervalSince(lastUpdateCheck) >= 21_600, !updateCheckInFlight {
            Task { [weak self] in
                await self?.checkForUpdates(silent: true)
            }
        }

        updateStatusTitle()
    }

    @objc private func toggle24Hour(_ sender: NSMenuItem) {
        let enabled = !store.bool(forKey: DefaultsKey.use24Hour)
        store.set(enabled, forKey: DefaultsKey.use24Hour)
        sender.state = enabled ? .on : .off
        updateStatusTitle()
    }

    @objc private func openSystemSettings() {
        let settingsURL = URL(fileURLWithPath: "/System/Applications/System Settings.app")
        NSWorkspace.shared.open(settingsURL)
    }

    private func requestRegionCheck() throws -> Date {
        try FileManager.default.createDirectory(at: userSupportURL, withIntermediateDirectories: true)
        let requestedAt = Date()
        let request = RecheckRequest(requestedAt: timestamp(requestedAt))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(request).write(to: recheckRequestURL, options: .atomic)
        return requestedAt
    }

    @objc private func recheckIPNow() {
        do {
            let requestedAt = try requestRegionCheck()
            manualRecheckRequestedAt = requestedAt
            manualRecheckError = nil
            updateStatusTitle()
        } catch {
            manualRecheckError = "Failed to request IP recheck: \(error.localizedDescription)"
        }

        buildMenu()
    }

    @objc private func toggleRegionalPermission(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let permission = RegionalPermissionKey(rawValue: rawValue) else {
            return
        }

        let enabled = !regionalPermissions.isEnabled(permission)
        let permissions = regionalPermissions.setting(permission, to: enabled)
        config = IPTimeConfig(
            regionCheckIntervalSeconds: normalizedRegionCheckInterval(config.regionCheckIntervalSeconds),
            homeClock: normalizedHomeClock(config.homeClock),
            regionalPermissions: permissions
        )

        do {
            try writeConfig()
            syncUserRegionalPreferences()
            _ = try requestRegionCheck()
            manualRecheckError = nil
        } catch {
            manualRecheckError = "Failed to save settings: \(error.localizedDescription)"
        }

        sender.state = enabled ? .on : .off
        buildMenu()
        updateStatusTitle()
    }

    @objc private func setRegionCheckInterval(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Int else {
            return
        }

        config = IPTimeConfig(
            regionCheckIntervalSeconds: normalizedRegionCheckInterval(seconds),
            homeClock: normalizedHomeClock(config.homeClock),
            regionalPermissions: regionalPermissions
        )
        do {
            try writeConfig()
            manualRecheckError = nil
        } catch {
            manualRecheckError = "Failed to save settings: \(error.localizedDescription)"
        }

        buildMenu()
    }

    @objc private func setHomeClock(_ sender: NSMenuItem) {
        guard let optionID = sender.representedObject as? String,
              let homeClock = homeClockConfig(for: optionID) else {
            return
        }

        config = IPTimeConfig(
            regionCheckIntervalSeconds: normalizedRegionCheckInterval(config.regionCheckIntervalSeconds),
            homeClock: normalizedHomeClock(homeClock),
            regionalPermissions: regionalPermissions
        )

        do {
            try writeConfig()
            manualRecheckError = nil
        } catch {
            manualRecheckError = "Failed to save settings: \(error.localizedDescription)"
        }

        buildMenu()
        updateStatusTitle()
    }

    @objc private func checkForUpdatesFromMenu() {
        Task { [weak self] in
            guard let self else {
                return
            }

            let outcome = await self.checkForUpdates(silent: false)
            self.showUpdateCheckAlert(outcome)
        }
    }

    @objc private func installUpdateFromMenu() {
        guard case .available(let candidate) = updateState else {
            return
        }

        do {
            try FileManager.default.createDirectory(at: userSupportURL, withIntermediateDirectories: true)
            let request = UpdateRequest(
                requestedAt: timestamp(),
                version: candidate.version,
                assetName: candidate.assetName,
                downloadURL: candidate.downloadURL
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(request).write(to: updateRequestURL, options: .atomic)
            try? writeLocalUpdateResult(
                version: candidate.version,
                status: "queued",
                message: "Queued update \(candidate.version)"
            )
            updateState = .requested(candidate.version)
            showUpdateProgressWindow(
                version: candidate.version,
                message: "Queued update \(candidate.version)",
                isError: false,
                isActive: true
            )
            updateStatusTitle()
        } catch {
            updateState = .failed("Failed to request update: \(error.localizedDescription)")
            showUpdateProgressWindow(
                version: "Update",
                message: "Failed to request update: \(error.localizedDescription)",
                isError: true,
                isActive: false
            )
        }

        buildMenu()
    }

    @objc private func quit() {
        restoreAndStopBeforeQuit()
        NSApp.terminate(nil)
    }

    private func restoreAndStopBeforeQuit() {
        timer?.invalidate()
        regionalPreferencesQueue.sync {
            _ = performUserRegionalPreferencesSync(.restore)
        }
        requestDaemonStop()
        removeLaunchAgent()
    }

    private func requestDaemonStop() {
        do {
            try FileManager.default.createDirectory(at: userSupportURL, withIntermediateDirectories: true)
            let request = StopRequest(requestedAt: timestamp())
            let state = DaemonStopState(requestedAt: request.requestedAt)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: daemonStopStateURL, options: .atomic)
            try encoder.encode(request).write(to: stopRequestURL, options: .atomic)
        } catch {
            statusReadError = "Failed to request daemon stop: \(error.localizedDescription)"
        }
    }

    private func removeLaunchAgent() {
        try? FileManager.default.removeItem(at: launchAgentURL)
        _ = runProcess(path: "/bin/launchctl", arguments: ["bootout", launchAgentService])
    }

    private func settlePendingDaemonStopIfNeeded() {
        let hasStopState = FileManager.default.fileExists(atPath: daemonStopStateURL.path)
        let hasStopRequest = FileManager.default.fileExists(atPath: stopRequestURL.path)
        guard hasStopState || hasStopRequest else {
            return
        }

        let deadline = Date().addingTimeInterval(daemonStopSettleTimeout)
        while isLaunchDaemonRunning(), Date() < deadline {
            Thread.sleep(forTimeInterval: daemonStopSettlePollInterval)
        }

        if isLaunchDaemonRunning() {
            try? FileManager.default.removeItem(at: daemonStopStateURL)
            try? FileManager.default.removeItem(at: stopRequestURL)
        } else {
            try? FileManager.default.removeItem(at: stopRequestURL)
        }
    }

    private func clearDaemonStopStateIfRunning() {
        guard isLaunchDaemonRunning() else {
            return
        }

        try? FileManager.default.removeItem(at: daemonStopStateURL)
        try? FileManager.default.removeItem(at: stopRequestURL)
    }

    private func ensureLaunchDaemonRunning() {
        daemonStartError = nil
        guard FileManager.default.fileExists(atPath: launchDaemonURL.path),
              !isLaunchDaemonRunning() else {
            return
        }

        let command = [
            "/bin/launchctl enable system/\(launchDaemonLabel) >/dev/null 2>&1 || true",
            "/bin/launchctl bootstrap system \(shellQuoted(launchDaemonURL.path)) >/dev/null 2>&1 || true",
            "/bin/launchctl kickstart -k system/\(launchDaemonLabel) >/dev/null 2>&1 || true"
        ].joined(separator: "; ")
        let script = "do shell script \(appleScriptString(command)) with administrator privileges"
        let result = runProcess(path: "/usr/bin/osascript", arguments: ["-e", script])
        if !result.success {
            daemonStartError = "Background service is stopped: \(result.message)"
            statusReadError = daemonStartError
        } else {
            clearDaemonStopStateIfRunning()
        }
    }

    private func isLaunchDaemonRunning() -> Bool {
        runProcess(path: "/bin/launchctl", arguments: ["print", "system/\(launchDaemonLabel)"]).success
    }

    private func showMenu(from view: NSView) {
        buildMenu()
        statusItem.menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.minY - 4), in: view)
    }

    private func loadStatus() {
        lastStatusRead = Date()

        do {
            let data = try Data(contentsOf: statusURL)
            status = try JSONDecoder().decode(IPTimeStatus.self, from: data)
            statusReadError = daemonStartError
            clearManualRecheckIfCompleted()
            if daemonStartError == nil {
                syncUserRegionalPreferences()
            }
        } catch {
            status = nil
            statusReadError = "No daemon status yet: \(error.localizedDescription)"
        }
    }

    private func loadRegionCheckState() {
        guard let data = try? Data(contentsOf: regionCheckStateURL),
              let state = try? JSONDecoder().decode(RegionCheckState.self, from: data),
              isFreshRegionCheckState(state) else {
            regionCheckState = nil
            return
        }

        regionCheckState = state
    }

    private func loadConfig() {
        guard let data = try? Data(contentsOf: configURL),
              let decoded = try? JSONDecoder().decode(IPTimeConfig.self, from: data) else {
            config = IPTimeConfig(regionCheckIntervalSeconds: defaultRegionCheckIntervalSeconds, homeClock: defaultHomeClockConfig)
            return
        }

        config = IPTimeConfig(
            regionCheckIntervalSeconds: normalizedRegionCheckInterval(decoded.regionCheckIntervalSeconds),
            homeClock: normalizedHomeClock(decoded.homeClock),
            regionalPermissions: decoded.regionalPermissions ?? .none
        )
    }

    private func syncUserRegionalPreferences() {
        guard let status,
              status.error == nil,
              let preferences = regionalPreferences(from: status),
              preferences.signature != lastAppliedRegionalPreferencesSignature else {
            return
        }

        enqueueRegionalPreferencesSync(.apply(preferences))
    }

    private func regionalPreferences(from status: IPTimeStatus) -> UserRegionalPreferences? {
        guard let locale = status.locale,
              let measurementUnits = status.measurementUnits,
              let metricUnits = status.metricUnits,
              let temperatureUnit = status.temperatureUnit,
              let firstWeekday = status.firstWeekday else {
            return nil
        }

        let permissions = regionalPermissions
        let signature = [
            permissions.timeZone ? "tz=1" : "tz=0",
            permissions.locale ? "locale=1" : "locale=0",
            permissions.measurementUnits ? "units=1" : "units=0",
            permissions.temperatureUnit ? "temp=1" : "temp=0",
            permissions.firstWeekday ? "weekday=1" : "weekday=0",
            permissions.locale ? locale : "",
            permissions.measurementUnits ? measurementUnits : "",
            permissions.measurementUnits ? String(metricUnits) : "",
            permissions.temperatureUnit ? temperatureUnit : "",
            permissions.firstWeekday ? String(firstWeekday) : ""
        ].joined(separator: "|")

        return UserRegionalPreferences(
            signature: signature,
            permissions: permissions,
            locale: locale,
            metricUnits: metricUnits,
            measurementUnits: measurementUnits,
            temperatureUnit: temperatureUnit,
            firstWeekday: firstWeekday
        )
    }

    private func enqueueRegionalPreferencesSync(_ request: UserRegionalPreferencesSyncRequest) {
        if regionalPreferencesSyncInFlight {
            pendingRegionalPreferencesSyncRequest = request
            return
        }

        regionalPreferencesSyncInFlight = true
        regionalPreferencesQueue.async { [weak self] in
            let result = performUserRegionalPreferencesSync(request)
            Task { @MainActor [weak self] in
                self?.finishRegionalPreferencesSync(result)
            }
        }
    }

    private func finishRegionalPreferencesSync(_ result: UserRegionalPreferencesSyncResult) {
        regionalPreferencesSyncInFlight = false
        var shouldRefreshDisplay = false

        switch result {
        case .applied(let signature):
            lastAppliedRegionalPreferencesSignature = signature
            shouldRefreshDisplay = clearRegionalPreferencesError()
        case .restored:
            lastAppliedRegionalPreferencesSignature = nil
            shouldRefreshDisplay = clearRegionalPreferencesError()
        case .skipped:
            break
        case .failed(let message):
            statusReadError = message
            shouldRefreshDisplay = true
        }

        if shouldRefreshDisplay {
            buildMenu()
            updateStatusTitle()
        }

        if let pendingRequest = pendingRegionalPreferencesSyncRequest {
            pendingRegionalPreferencesSyncRequest = nil
            enqueueRegionalPreferencesSync(pendingRequest)
        }
    }

    @discardableResult
    private func clearRegionalPreferencesError() -> Bool {
        let prefixes = [
            "Failed to apply user regional preferences:",
            "Failed to restore user preferences:",
            "Failed to record user restore state:"
        ]

        guard let statusReadError, prefixes.contains(where: { statusReadError.hasPrefix($0) }) else {
            return false
        }

        self.statusReadError = nil
        return true
    }

    private func loadPendingManualRecheckState() {
        guard FileManager.default.fileExists(atPath: recheckRequestURL.path),
              let data = try? Data(contentsOf: recheckRequestURL),
              let request = try? JSONDecoder().decode(RecheckRequest.self, from: data),
              let requestedAt = parseTimestamp(request.requestedAt) else {
            return
        }

        manualRecheckRequestedAt = requestedAt
    }

    private func writeConfig() throws {
        try FileManager.default.createDirectory(at: userSupportURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: configURL, options: .atomic)
    }

    private func normalizedRegionCheckInterval(_ seconds: Int) -> Int {
        regionCheckIntervalOptions.contains(seconds) ? seconds : defaultRegionCheckIntervalSeconds
    }

    private func clearManualRecheckIfCompleted() {
        guard let manualRecheckRequestedAt,
              let generatedAt = nonEmpty(status?.generatedAt),
              let statusDate = parseTimestamp(generatedAt),
              statusDate >= manualRecheckRequestedAt else {
            return
        }

        self.manualRecheckRequestedAt = nil
    }

    private func expireManualRecheckIfNeeded() {
        guard let manualRecheckRequestedAt,
              Date().timeIntervalSince(manualRecheckRequestedAt) > manualRecheckTimeout else {
            return
        }

        self.manualRecheckRequestedAt = nil
        manualRecheckError = "Timed out waiting for daemon response"
        buildMenu()
    }

    private func loadPendingUpdateState() {
        let hasPendingRequest: Bool
        if FileManager.default.fileExists(atPath: updateRequestURL.path),
           let data = try? Data(contentsOf: updateRequestURL),
           let request = try? JSONDecoder().decode(UpdateRequest.self, from: data) {
            updateState = .requested(request.version)
            hasPendingRequest = true
        } else {
            hasPendingRequest = false
        }

        loadUpdateResult(showRecentWindow: true)

        if hasPendingRequest, case .upToDate = updateState {
            updateState = .requested(latestUpdateResult?.version ?? "update")
        }
    }

    private func loadUpdateResult(showRecentWindow: Bool) {
        guard let data = try? Data(contentsOf: updateResultURL),
              let result = try? JSONDecoder().decode(UpdateResult.self, from: data) else {
            return
        }

        let signature = [result.generatedAt, result.version, result.status, result.message].joined(separator: "|")
        guard signature != lastUpdateResultSignature else {
            return
        }

        lastUpdateResultSignature = signature
        latestUpdateResult = result
        let showWindow = shouldShowUpdateResultWindow(result, signature: signature, showRecentWindow: showRecentWindow)
        applyUpdateResult(result, showWindow: showWindow)
        buildMenu()
        updateStatusTitle()
    }

    private func applyUpdateResult(_ result: UpdateResult, showWindow: Bool) {
        switch result.status {
        case "queued", "validating", "downloading", "unpacking", "installing", "restarting":
            updateState = .requested(result.version)
            if showWindow {
                showUpdateProgressWindow(version: result.version, message: result.message, isError: false, isActive: true)
            }
        case "installed":
            updateState = .upToDate(result.version)
            if showWindow {
                showUpdateProgressWindow(version: result.version, message: result.message, isError: false, isActive: false)
                recordShownUpdateResult(result)
                closeUpdateProgressWindow(after: 2.5)
            }
        case "failed":
            updateState = .failed("Update \(result.version) failed: \(result.message)")
            if showWindow {
                showUpdateProgressWindow(version: result.version, message: result.message, isError: true, isActive: false)
                recordShownUpdateResult(result)
            }
        default:
            break
        }
    }

    private func shouldShowUpdateResultWindow(_ result: UpdateResult, signature: String, showRecentWindow: Bool) -> Bool {
        guard showRecentWindow, isRecentUpdateResult(result) else {
            return false
        }

        switch result.status {
        case "installed", "failed":
            return store.string(forKey: DefaultsKey.shownUpdateResultSignature) != signature
        default:
            return true
        }
    }

    private func recordShownUpdateResult(_ result: UpdateResult) {
        let signature = [result.generatedAt, result.version, result.status, result.message].joined(separator: "|")
        store.set(signature, forKey: DefaultsKey.shownUpdateResultSignature)
    }

    private func writeLocalUpdateResult(version: String, status: String, message: String) throws {
        let result = UpdateResult(generatedAt: timestamp(), version: version, status: status, message: message)
        try FileManager.default.createDirectory(at: userSupportURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: updateResultURL, options: .atomic)
        latestUpdateResult = result
        lastUpdateResultSignature = [result.generatedAt, result.version, result.status, result.message].joined(separator: "|")
    }

    private func isRecentUpdateResult(_ result: UpdateResult) -> Bool {
        guard let date = parseTimestamp(result.generatedAt) else {
            return false
        }

        return abs(date.timeIntervalSinceNow) <= 600
    }

    private func showUpdateProgressWindow(version: String, message: String, isError: Bool, isActive: Bool) {
        let window: NSWindow
        if let existingWindow = updateProgressWindow {
            window = existingWindow
        } else {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 390, height: 128),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            panel.title = "IP Time Update"
            panel.isReleasedWhenClosed = false
            panel.level = .floating

            let content = NSView(frame: NSRect(x: 0, y: 0, width: 390, height: 128))

            let title = NSTextField(labelWithString: isActive ? "Installing \(version)" : "Update \(version)")
            title.frame = NSRect(x: 22, y: 82, width: 346, height: 24)
            title.font = .systemFont(ofSize: 15, weight: .semibold)

            let label = NSTextField(labelWithString: message)
            label.frame = NSRect(x: 22, y: 52, width: 346, height: 22)
            label.font = .systemFont(ofSize: 13, weight: .regular)
            label.lineBreakMode = .byTruncatingMiddle

            let progress = NSProgressIndicator(frame: NSRect(x: 22, y: 24, width: 346, height: 12))
            progress.style = .bar
            progress.isIndeterminate = true

            content.addSubview(title)
            content.addSubview(label)
            content.addSubview(progress)
            panel.contentView = content

            updateProgressLabel = label
            updateProgressTitle = title
            updateProgressIndicator = progress
            updateProgressWindow = panel
            window = panel
        }

        updateProgressWindow?.title = "IP Time Update"
        updateProgressTitle?.stringValue = isActive ? "Installing \(version)" : "Update \(version)"
        updateProgressLabel?.stringValue = message
        updateProgressLabel?.textColor = isError ? .systemRed : .labelColor

        if isActive {
            updateProgressIndicator?.isHidden = false
            updateProgressIndicator?.startAnimation(nil)
        } else {
            updateProgressIndicator?.stopAnimation(nil)
            updateProgressIndicator?.isHidden = true
        }

        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func closeUpdateProgressWindow(after delay: TimeInterval) {
        guard let window = updateProgressWindow else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak window] in
            guard let self, let window, self.updateProgressWindow === window else {
                return
            }

            window.close()
            self.updateProgressWindow = nil
        }
    }

    private func buildMenu() {
        loadConfig()

        let menu = NSMenu()
        menu.autoenablesItems = false

        let summary = NSMenuItem(title: statusDisplay().summary, action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)

        menu.addItem(.separator())

        let ipCheck = NSMenuItem(title: "IP check: every \(intervalLabel(config.regionCheckIntervalSeconds))", action: nil, keyEquivalent: "")
        ipCheck.isEnabled = false
        menu.addItem(ipCheck)

        let allowedChanges = NSMenuItem(title: "Allowed changes: \(regionalPermissionsDescription())", action: nil, keyEquivalent: "")
        allowedChanges.isEnabled = false
        menu.addItem(allowedChanges)

        addRegionalPermissionItems(to: menu)

        for title in detailRows() {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        if let error = displayedError {
            menu.addItem(.separator())
            let item = NSMenuItem(title: "Error: \(error)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.attributedTitle = NSAttributedString(
                string: item.title,
                attributes: [.foregroundColor: NSColor.systemRed]
            )
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let recheck = NSMenuItem(
            title: isIPCheckInProgress ? "Rechecking IP..." : "Recheck IP Now",
            action: isIPCheckInProgress ? nil : #selector(recheckIPNow),
            keyEquivalent: ""
        )
        recheck.target = self
        recheck.isEnabled = !isIPCheckInProgress
        menu.addItem(recheck)

        let settings = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settings.submenu = settingsMenu()
        menu.addItem(settings)

        menu.addItem(.separator())

        let use24Hour = NSMenuItem(title: "24-hour time", action: #selector(toggle24Hour(_:)), keyEquivalent: "")
        use24Hour.target = self
        use24Hour.state = store.bool(forKey: DefaultsKey.use24Hour) ? .on : .off
        menu.addItem(use24Hour)

        menu.addItem(.separator())

        let version = NSMenuItem(title: "Version: \(currentVersionLabel)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)

        for updateItem in updateMenuItems() {
            updateItem.target = self
            menu.addItem(updateItem)
        }

        menu.addItem(.separator())

        let openSettings = NSMenuItem(title: "Open System Settings...", action: #selector(openSystemSettings), keyEquivalent: "")
        openSettings.target = self
        menu.addItem(openSettings)

        let quit = NSMenuItem(title: "Quit IP Time", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func addRegionalPermissionItems(to menu: NSMenu) {
        let header = NSMenuItem(title: "Approve changes:", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        for permission in RegionalPermissionKey.allCases {
            let item = NSMenuItem(title: "Allow \(permission.menuTitle)", action: #selector(toggleRegionalPermission(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = permission.rawValue
            item.state = regionalPermissions.isEnabled(permission) ? .on : .off
            item.indentationLevel = 1
            menu.addItem(item)
        }

        menu.addItem(.separator())
    }

    private func settingsMenu() -> NSMenu {
        let menu = NSMenu()

        let homeClockMenuItem = NSMenuItem(title: "Home Clock", action: nil, keyEquivalent: "")
        homeClockMenuItem.submenu = homeClockMenu()
        menu.addItem(homeClockMenuItem)

        menu.addItem(.separator())

        let permissionsMenuItem = NSMenuItem(title: "Allowed Changes", action: nil, keyEquivalent: "")
        permissionsMenuItem.submenu = regionalPermissionsMenu()
        menu.addItem(permissionsMenuItem)

        menu.addItem(.separator())

        let intervalMenuItem = NSMenuItem(title: "IP Check Interval", action: nil, keyEquivalent: "")
        let intervalMenu = NSMenu()

        for seconds in regionCheckIntervalOptions {
            let item = NSMenuItem(title: intervalLabel(seconds), action: #selector(setRegionCheckInterval(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = seconds
            item.state = config.regionCheckIntervalSeconds == seconds ? .on : .off
            intervalMenu.addItem(item)
        }

        intervalMenuItem.submenu = intervalMenu
        menu.addItem(intervalMenuItem)
        return menu
    }

    private func regionalPermissionsMenu() -> NSMenu {
        let menu = NSMenu()

        let current = NSMenuItem(title: "Current: \(regionalPermissionsDescription())", action: nil, keyEquivalent: "")
        current.isEnabled = false
        menu.addItem(current)
        menu.addItem(.separator())

        for permission in RegionalPermissionKey.allCases {
            let item = NSMenuItem(title: permission.menuTitle, action: #selector(toggleRegionalPermission(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = permission.rawValue
            item.state = regionalPermissions.isEnabled(permission) ? .on : .off
            menu.addItem(item)
        }

        return menu
    }

    private func homeClockMenu() -> NSMenu {
        let menu = NSMenu()
        let current = NSMenuItem(title: "Current: \(homeClockDescription())", action: nil, keyEquivalent: "")
        current.isEnabled = false
        menu.addItem(current)
        menu.addItem(.separator())

        let presets = NSMenuItem(title: "Presets", action: nil, keyEquivalent: "")
        presets.submenu = homeClockPresetsMenu()
        menu.addItem(presets)

        let offsets = NSMenuItem(title: "Fixed UTC Offset", action: nil, keyEquivalent: "")
        offsets.submenu = fixedUTCOffsetMenu()
        menu.addItem(offsets)

        return menu
    }

    private func homeClockPresetsMenu() -> NSMenu {
        let menu = NSMenu()

        for option in homeClockPresetOptions {
            let countryFlag = option.config.countryCode.map(flag(for:)) ?? ""
            let title = [countryFlag, option.menuTitle].filter { !$0.isEmpty }.joined(separator: " ")
            let item = NSMenuItem(title: title, action: #selector(setHomeClock(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.id
            item.state = homeClockID(normalizedHomeClock(config.homeClock)) == option.id ? .on : .off
            menu.addItem(item)
        }

        return menu
    }

    private func fixedUTCOffsetMenu() -> NSMenu {
        let menu = NSMenu()

        for minutes in fixedUTCOffsetOptions {
            let optionID = "offset:\(minutes)"
            let item = NSMenuItem(title: utcOffsetMenuLabel(minutes), action: #selector(setHomeClock(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = optionID
            item.state = homeClockID(normalizedHomeClock(config.homeClock)) == optionID ? .on : .off
            menu.addItem(item)
        }

        return menu
    }

    private func updateMenuItems() -> [NSMenuItem] {
        switch updateState {
        case .idle:
            return [NSMenuItem(title: "Check Update...", action: #selector(checkForUpdatesFromMenu), keyEquivalent: "")]
        case .checking:
            let item = NSMenuItem(title: "Checking for Updates...", action: nil, keyEquivalent: "")
            item.isEnabled = false
            return [item]
        case .upToDate(let version):
            let status = NSMenuItem(title: "Up to Date (\(version))", action: nil, keyEquivalent: "")
            status.isEnabled = false
            return [
                status,
                NSMenuItem(title: "Check Update...", action: #selector(checkForUpdatesFromMenu), keyEquivalent: "")
            ]
        case .available(let candidate):
            return [NSMenuItem(title: "Install Update \(candidate.version)", action: #selector(installUpdateFromMenu), keyEquivalent: "")]
        case .requested(let version):
            let item = NSMenuItem(title: "Installing Update \(version)...", action: nil, keyEquivalent: "")
            item.isEnabled = false
            return [item]
        case .failed(let message):
            let status = NSMenuItem(title: "Update Check Failed", action: nil, keyEquivalent: "")
            status.isEnabled = false
            status.toolTip = message
            status.attributedTitle = NSAttributedString(
                string: status.title,
                attributes: [.foregroundColor: NSColor.systemRed]
            )
            return [
                status,
                NSMenuItem(title: "Check Update...", action: #selector(checkForUpdatesFromMenu), keyEquivalent: "")
            ]
        }
    }

    private func detailRows() -> [String] {
        var rows: [String] = [
            "Home clock: \(homeClockDescription())"
        ]

        if let ip = nonEmpty(status?.ip) {
            rows.append("External IP: \(ip)")
        }

        let location = [status?.city, status?.region, status?.countryCode]
            .compactMap(nonEmpty)
            .joined(separator: ", ")

        if !location.isEmpty {
            rows.append("Location: \(location)")
        }

        if let country = nonEmpty(status?.country) {
            rows.append("Country: \(country)")
        }

        if let timeZone = nonEmpty(status?.timeZone) {
            rows.append("Time zone: \(timeZone)")
        }

        if let locale = nonEmpty(status?.locale) {
            rows.append("Locale: \(locale)")
        }

        if let measurementUnits = nonEmpty(status?.measurementUnits) {
            let metric = status?.metricUnits == false ? "imperial" : "metric"
            rows.append("Units: \(measurementUnits) (\(metric))")
        }

        if let temperatureUnit = nonEmpty(status?.temperatureUnit) {
            rows.append("Temperature: \(temperatureUnit)")
        }

        if let firstWeekday = status?.firstWeekday {
            rows.append("First weekday: \(weekdayName(firstWeekday))")
        }

        if let activeUser = nonEmpty(status?.activeUser) {
            rows.append("Active user: \(activeUser)")
        }

        if let generatedAt = nonEmpty(status?.generatedAt) {
            rows.append("Last check: \(generatedAt)")
        }

        if let startedAt = activeIPCheckStartedAt {
            let trigger = nonEmpty(regionCheckState?.trigger).map { " (\($0))" } ?? ""
            rows.append("IP check: in progress since \(shortTime(startedAt))\(trigger)")
        }

        if let manualRecheckError {
            rows.append("Manual recheck: \(manualRecheckError)")
        }

        rows.append("App language: English only")

        switch updateState {
        case .upToDate(let version):
            rows.append("Updates: latest version \(version)")
        case .available(let candidate):
            rows.append("Updates: \(candidate.version) available")
        case .requested(let version):
            rows.append("Updates: \(latestUpdateResult?.message ?? "installing \(version)")")
        case .failed(let message):
            rows.append("Updates: \(message)")
        case .checking:
            rows.append("Updates: checking")
        case .idle:
            break
        }

        return rows
    }

    @discardableResult
    private func checkForUpdates(silent: Bool) async -> UpdateCheckOutcome {
        guard !updateCheckInFlight else {
            return .alreadyChecking
        }

        if case .requested(let version) = updateState {
            return .updateInProgress(version)
        }

        updateCheckInFlight = true
        lastUpdateCheck = Date()
        if !silent {
            updateState = .checking
            buildMenu()
        }

        defer {
            updateCheckInFlight = false
            buildMenu()
        }

        do {
            let release = try await fetchLatestRelease()
            guard let candidate = updateCandidate(from: release) else {
                let message = "No \(updateAssetName) asset in latest release"
                if !silent {
                    updateState = .failed(message)
                }
                return .failed(message)
            }

            if isVersion(candidate.version, newerThan: currentAppVersion) {
                updateState = .available(candidate)
                return .available(candidate)
            } else if !silent {
                updateState = .upToDate(candidate.version)
            } else if case .available = updateState {
                updateState = .upToDate(candidate.version)
            }

            return .upToDate(candidate.version)
        } catch {
            let message = error.localizedDescription
            if !silent {
                updateState = .failed(message)
            }
            return .failed(message)
        }
    }

    private func showUpdateCheckAlert(_ outcome: UpdateCheckOutcome) {
        let alert = NSAlert()
        alert.alertStyle = .informational

        switch outcome {
        case .alreadyChecking:
            alert.messageText = "Checking for Updates"
            alert.informativeText = "An update check is already running."
            alert.addButton(withTitle: "OK")
        case .updateInProgress(let version):
            alert.messageText = "Update in Progress"
            alert.informativeText = "IP Time is already installing \(version)."
            alert.addButton(withTitle: "OK")
        case .upToDate(let version):
            alert.messageText = "IP Time is Up to Date"
            alert.informativeText = "Installed version: \(currentVersionLabel)\nLatest version: \(version)"
            alert.addButton(withTitle: "OK")
        case .available(let candidate):
            alert.messageText = "Update Available"
            alert.informativeText = "\(candidate.version) is available.\nInstalled version: \(currentVersionLabel)"
            alert.addButton(withTitle: "Install Update")
            alert.addButton(withTitle: "Later")
        case .failed(let message):
            alert.alertStyle = .warning
            alert.messageText = "Update Check Failed"
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
        }

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if case .available = outcome, response == .alertFirstButtonReturn {
            installUpdateFromMenu()
        }
    }

    private func fetchLatestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: githubLatestReleaseURL)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            if httpResponse.statusCode == 404 {
                throw IPTimeError("GitHub release not found")
            }

            throw IPTimeError("GitHub returned HTTP \(httpResponse.statusCode)")
        }

        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    private func updateCandidate(from release: GitHubRelease) -> UpdateCandidate? {
        guard let asset = release.assets.first(where: { $0.name == updateAssetName }) else {
            return nil
        }

        return UpdateCandidate(
            version: release.tagName,
            assetName: asset.name,
            downloadURL: asset.browserDownloadURL,
            releaseURL: release.htmlURL
        )
    }

    private func updateStatusTitle() {
        let display = statusDisplay()
        statusView?.segments = display.segments
        statusView?.setAnimating(display.segments.contains { $0.activity.isVisible })

        if let statusView {
            statusItem.length = statusView.intrinsicContentSize.width
        }
    }

    private func statusDisplay() -> StatusDisplay {
        let now = Date()
        let homeClock = resolvedHomeClock()
        let homeText = formattedTime(now, in: homeClock.timeZone)
        let homeDate = formattedDate(now, in: homeClock.timeZone)

        if !regionalChangesAllowed {
            let homeSegment = StatusSegment(
                flag: homeClock.symbol,
                primary: homeText,
                detail: homeDate,
                detailFirst: true,
                isError: false
            )
            var ipSegment = StatusSegment(
                flag: flag(for: countryCode),
                primary: ipLabel,
                detail: nil,
                detailFirst: false,
                isError: displayedError != nil,
                activity: ipActivityIndicator
            )

            if hasIPLookupError {
                ipSegment = StatusSegment(
                    flag: "",
                    primary: "[ ip-api.com error ]",
                    detail: nil,
                    detailFirst: false,
                    isError: true,
                    activity: ipActivityIndicator
                )
            }

            if case .requested(let version) = updateState {
                ipSegment = StatusSegment(flag: "⬆", primary: "Updating", detail: version, detailFirst: false, isError: false)
            }

            let segments = [homeSegment, ipSegment]
            return StatusDisplay(segments: segments, summary: segments.map(\.summary).joined(separator: "  "))
        }

        let localText = formattedTime(now, in: .autoupdatingCurrent)
        var segments = [
            StatusSegment(flag: homeClock.symbol, primary: homeText, detail: homeDate, detailFirst: true, isError: false),
            StatusSegment(
                flag: flag(for: countryCode),
                primary: localText,
                detail: ipLabel,
                detailFirst: false,
                isError: displayedError != nil,
                activity: ipActivityIndicator
            )
        ]

        if hasIPLookupError {
            segments[1] = StatusSegment(
                flag: "",
                primary: "[ ip-api.com error ]",
                detail: nil,
                detailFirst: false,
                isError: true
            )
        }

        if case .requested(let version) = updateState {
            segments[1] = StatusSegment(flag: "⬆", primary: "Updating", detail: version, detailFirst: false, isError: false)
        }

        return StatusDisplay(
            segments: segments,
            summary: segments.map(\.summary).joined(separator: "  ")
        )
    }

    private func formattedDate(_ date: Date, in timeZone: TimeZone) -> String {
        dateFormatter.timeZone = timeZone
        return dateFormatter.string(from: date)
    }

    private func formattedTime(_ date: Date, in timeZone: TimeZone) -> String {
        timeFormatter.timeZone = timeZone
        timeFormatter.dateFormat = store.bool(forKey: DefaultsKey.use24Hour) ? "HH:mm" : "h:mm a"
        return timeFormatter.string(from: date)
    }

    private func shortTime(_ date: Date) -> String {
        formattedTime(date, in: .autoupdatingCurrent)
    }

    private func resolvedHomeClock() -> ResolvedHomeClock {
        let homeClock = normalizedHomeClock(config.homeClock)

        if homeClock.mode == HomeClockMode.fixedOffset,
           let offsetMinutes = homeClock.offsetMinutes,
           let timeZone = TimeZone(secondsFromGMT: offsetMinutes * 60) {
            return ResolvedHomeClock(
                symbol: shortUTCOffsetLabel(offsetMinutes),
                label: homeClock.label,
                timeZone: timeZone
            )
        }

        if let identifier = homeClock.timeZoneIdentifier,
           let timeZone = TimeZone(identifier: identifier) {
            let symbol = homeClock.countryCode.map(flag(for:)) ?? shortUTCOffsetLabel(timeZone.secondsFromGMT() / 60)
            return ResolvedHomeClock(symbol: symbol, label: homeClock.label, timeZone: timeZone)
        }

        return ResolvedHomeClock(symbol: "🇷🇺", label: "Moscow", timeZone: moscowTimeZone)
    }

    private func normalizedHomeClock(_ homeClock: HomeClockConfig?) -> HomeClockConfig {
        guard let homeClock else {
            return defaultHomeClockConfig
        }

        if homeClock.mode == HomeClockMode.fixedOffset,
           let offsetMinutes = homeClock.offsetMinutes,
           fixedUTCOffsetOptions.contains(offsetMinutes),
           TimeZone(secondsFromGMT: offsetMinutes * 60) != nil {
            return HomeClockConfig(
                mode: HomeClockMode.fixedOffset,
                label: nonEmpty(homeClock.label) ?? utcOffsetMenuLabel(offsetMinutes),
                countryCode: nil,
                timeZoneIdentifier: nil,
                offsetMinutes: offsetMinutes
            )
        }

        guard let identifier = nonEmpty(homeClock.timeZoneIdentifier),
              TimeZone(identifier: identifier) != nil else {
            return defaultHomeClockConfig
        }

        return HomeClockConfig(
            mode: HomeClockMode.timeZone,
            label: nonEmpty(homeClock.label) ?? identifier.replacingOccurrences(of: "_", with: " "),
            countryCode: nonEmpty(homeClock.countryCode)?.uppercased(),
            timeZoneIdentifier: identifier,
            offsetMinutes: nil
        )
    }

    private func homeClockConfig(for optionID: String) -> HomeClockConfig? {
        if let preset = homeClockPresetOptions.first(where: { $0.id == optionID }) {
            return preset.config
        }

        guard optionID.hasPrefix("offset:"),
              let minutes = Int(optionID.dropFirst("offset:".count)),
              fixedUTCOffsetOptions.contains(minutes) else {
            return nil
        }

        return HomeClockConfig(
            mode: HomeClockMode.fixedOffset,
            label: utcOffsetMenuLabel(minutes),
            countryCode: nil,
            timeZoneIdentifier: nil,
            offsetMinutes: minutes
        )
    }

    private func homeClockID(_ homeClock: HomeClockConfig) -> String {
        let normalized = normalizedHomeClock(homeClock)
        if normalized.mode == HomeClockMode.fixedOffset, let offsetMinutes = normalized.offsetMinutes {
            return "offset:\(offsetMinutes)"
        }

        return "tz:\(normalized.timeZoneIdentifier ?? defaultHomeClockConfig.timeZoneIdentifier ?? "Europe/Moscow")"
    }

    private func homeClockDescription() -> String {
        let homeClock = normalizedHomeClock(config.homeClock)
        if homeClock.mode == HomeClockMode.fixedOffset, let offsetMinutes = homeClock.offsetMinutes {
            return "\(utcOffsetMenuLabel(offsetMinutes)) (fixed offset)"
        }

        let countryFlag = homeClock.countryCode.map(flag(for:)) ?? ""
        let identifier = homeClock.timeZoneIdentifier ?? "Europe/Moscow"
        return [countryFlag, homeClock.label].filter { !$0.isEmpty }.joined(separator: " ") + " (\(identifier))"
    }

    private func regionalPermissionsDescription() -> String {
        let enabled = RegionalPermissionKey.allCases.filter { regionalPermissions.isEnabled($0) }
        if enabled.isEmpty {
            return "None"
        }

        return enabled.map(\.menuTitle).joined(separator: ", ")
    }

    private var isManualRecheckInProgress: Bool {
        manualRecheckRequestedAt != nil
    }

    private var isIPCheckInProgress: Bool {
        isManualRecheckInProgress || isRegionCheckActive
    }

    private var showsIPActivityIndicator: Bool {
        ipActivityIndicator.isVisible
    }

    private var ipActivityIndicator: StatusActivityIndicator {
        if let state = regionCheckState {
            if state.completedAt == nil, isRegionCheckActive {
                return .checking
            }

            if let completedAt = state.completedAt,
               let completedDate = parseTimestamp(completedAt),
               Date().timeIntervalSince(completedDate) <= completedCheckIndicatorDuration {
                return .completed(completedDate)
            }
        }

        if isManualRecheckInProgress {
            return .checking
        }

        return .none
    }

    private var activeIPCheckStartedAt: Date? {
        if let state = regionCheckState,
           state.completedAt == nil,
           let startedAt = parseTimestamp(state.startedAt) {
            return startedAt
        }

        return manualRecheckRequestedAt
    }

    private var isRegionCheckActive: Bool {
        guard let state = regionCheckState,
              state.completedAt == nil,
              let startedAt = parseTimestamp(state.startedAt) else {
            return false
        }

        return Date().timeIntervalSince(startedAt) <= regionCheckStateMaxAge
    }

    private var isRegionCheckVisible: Bool {
        guard let state = regionCheckState else {
            return false
        }

        return isFreshRegionCheckState(state)
    }

    private func isFreshRegionCheckState(_ state: RegionCheckState) -> Bool {
        if let completedAt = state.completedAt,
           let completedDate = parseTimestamp(completedAt) {
            return Date().timeIntervalSince(completedDate) <= completedCheckIndicatorDuration
        }

        guard let startedAt = parseTimestamp(state.startedAt) else {
            return false
        }

        return Date().timeIntervalSince(startedAt) <= regionCheckStateMaxAge
    }

    private func intervalLabel(_ seconds: Int) -> String {
        let minutes = seconds / 60
        switch minutes {
        case 1:
            return "1 minute"
        case 60:
            return "1 hour"
        default:
            return "\(minutes) minutes"
        }
    }

    private func utcOffsetMenuLabel(_ minutes: Int) -> String {
        let sign = minutes >= 0 ? "+" : "-"
        let absoluteMinutes = abs(minutes)
        return String(format: "UTC%@%02d:%02d", sign, absoluteMinutes / 60, absoluteMinutes % 60)
    }

    private func shortUTCOffsetLabel(_ minutes: Int) -> String {
        let sign = minutes >= 0 ? "+" : "-"
        let absoluteMinutes = abs(minutes)
        if absoluteMinutes % 60 == 0 {
            return "UTC\(sign)\(absoluteMinutes / 60)"
        }

        return String(format: "UTC%@%d:%02d", sign, absoluteMinutes / 60, absoluteMinutes % 60)
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func flag(for countryCode: String) -> String {
        let code = countryCode.uppercased()
        guard code.count == 2 else {
            return "??"
        }

        let scalars = code.unicodeScalars.compactMap { scalar -> UnicodeScalar? in
            guard scalar.value >= 65, scalar.value <= 90 else {
                return nil
            }

            return UnicodeScalar(127397 + scalar.value)
        }

        guard scalars.count == 2 else {
            return "??"
        }

        return String(String.UnicodeScalarView(scalars))
    }

    private func weekdayName(_ appleFirstWeekday: Int) -> String {
        switch appleFirstWeekday {
        case 1:
            return "Monday"
        case 7:
            return "Sunday"
        default:
            return String(appleFirstWeekday)
        }
    }

    private var currentAppVersion: String {
        let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return nonEmpty(value) ?? "0.0.0"
    }

    private var currentVersionLabel: String {
        currentAppVersion.hasPrefix("v") ? currentAppVersion : "v\(currentAppVersion)"
    }

    private var updateAssetName: String {
        "IPTime-macos-\(currentArchitecture).zip"
    }

    private var currentArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    private func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let lhs = versionParts(candidate)
        let rhs = versionParts(current)
        let count = max(lhs.count, rhs.count)

        for index in 0..<count {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0

            if left != right {
                return left > right
            }
        }

        return false
    }

    private func versionParts(_ version: String) -> [Int] {
        version
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            .split(separator: ".")
            .map { part in
                let digits = part.prefix { $0.isNumber }
                return Int(digits) ?? 0
            }
    }
}

private func timestamp(_ date: Date = Date()) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private func parseTimestamp(_ value: String) -> Date? {
    let fractionalFormatter = ISO8601DateFormatter()
    fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractionalFormatter.date(from: value) {
        return date
    }

    return ISO8601DateFormatter().date(from: value)
}

private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: url, options: .atomic)
}

private func performUserRegionalPreferencesSync(_ request: UserRegionalPreferencesSyncRequest) -> UserRegionalPreferencesSyncResult {
    do {
        switch request {
        case .apply(let preferences):
            if preferences.permissions.userPreferencesEnabled {
                try? FileManager.default.removeItem(at: regionSyncRestoreStateURL)
                try backupUserPreferencesIfNeeded()
            }
            try syncUserRegionalPreferences(preferences)
            return .applied(preferences.signature)
        case .restore:
            return try restoreOriginalUserPreferences(keys: userPreferenceKeysToBackup)
        }
    } catch {
        return .failed("Failed to apply user regional preferences: \(error.localizedDescription)")
    }
}

private func backupUserPreferencesIfNeeded() throws {
    if FileManager.default.fileExists(atPath: userPreferenceBackupURL.path) {
        return
    }

    let exportResult = runProcess(path: "/usr/bin/defaults", arguments: ["export", "NSGlobalDomain", "-"])
    guard exportResult.success,
          let data = exportResult.message.data(using: .utf8),
          let propertyList = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
          let globalDomain = propertyList as? [String: Any] else {
        throw IPTimeMenuError("failed to read original user preferences")
    }

    let preferences = Dictionary(uniqueKeysWithValues: userPreferenceKeysToBackup.map { key in
        (key, userPreferenceBackupValue(from: globalDomain[key]))
    })
    let backup = UserPreferenceBackup(createdAt: timestamp(), user: NSUserName(), preferences: preferences)

    try FileManager.default.createDirectory(at: userSupportURL, withIntermediateDirectories: true)
    try writeJSON(backup, to: userPreferenceBackupURL)
    try userPreferenceRestoreScript(preferences: preferences).data(using: .utf8)?.write(to: userPreferenceRestoreScriptURL, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: userPreferenceBackupURL.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: userPreferenceRestoreScriptURL.path)
}

private func syncUserRegionalPreferences(_ preferences: UserRegionalPreferences) throws {
    if preferences.permissions.locale {
        try writeUserDefaultIfNeeded(
            readArguments: ["read", "NSGlobalDomain", "AppleLocale"],
            writeArguments: ["write", "NSGlobalDomain", "AppleLocale", "-string", preferences.locale],
            expected: .string(preferences.locale),
            label: "AppleLocale"
        )
    } else {
        try restoreOriginalUserPreferences(keys: ["AppleLocale"])
    }

    if preferences.permissions.measurementUnits {
        try writeUserDefaultIfNeeded(
            readArguments: ["read", "NSGlobalDomain", "AppleMetricUnits"],
            writeArguments: ["write", "NSGlobalDomain", "AppleMetricUnits", "-bool", preferences.metricUnits ? "true" : "false"],
            expected: .bool(preferences.metricUnits),
            label: "AppleMetricUnits"
        )
        try writeUserDefaultIfNeeded(
            readArguments: ["read", "NSGlobalDomain", "AppleMeasurementUnits"],
            writeArguments: ["write", "NSGlobalDomain", "AppleMeasurementUnits", "-string", preferences.measurementUnits],
            expected: .string(preferences.measurementUnits),
            label: "AppleMeasurementUnits"
        )
    } else {
        try restoreOriginalUserPreferences(keys: ["AppleMetricUnits", "AppleMeasurementUnits"])
    }

    if preferences.permissions.temperatureUnit {
        try writeUserDefaultIfNeeded(
            readArguments: ["read", "NSGlobalDomain", "AppleTemperatureUnit"],
            writeArguments: ["write", "NSGlobalDomain", "AppleTemperatureUnit", "-string", preferences.temperatureUnit],
            expected: .string(preferences.temperatureUnit),
            label: "AppleTemperatureUnit"
        )
    } else {
        try restoreOriginalUserPreferences(keys: ["AppleTemperatureUnit"])
    }

    if preferences.permissions.firstWeekday {
        try writeUserDefaultIfNeeded(
            readArguments: ["read", "NSGlobalDomain", "AppleFirstWeekday"],
            writeArguments: ["write", "NSGlobalDomain", "AppleFirstWeekday", "-int", String(preferences.firstWeekday)],
            expected: .int(preferences.firstWeekday),
            label: "AppleFirstWeekday"
        )
    } else {
        try restoreOriginalUserPreferences(keys: ["AppleFirstWeekday"])
    }
}

private func writeUserDefaultIfNeeded(
    readArguments: [String],
    writeArguments: [String],
    expected: UserDefaultExpectedValue,
    label: String
) throws {
    let readResult = runProcess(path: "/usr/bin/defaults", arguments: readArguments)
    if readResult.success, userDefaultValue(readResult.message, matches: expected) {
        return
    }

    let writeResult = runProcess(path: "/usr/bin/defaults", arguments: writeArguments)
    if !writeResult.success {
        throw IPTimeMenuError("failed to set \(label): \(writeResult.message)")
    }
}

@discardableResult
private func restoreOriginalUserPreferences(keys: [String]) throws -> UserRegionalPreferencesSyncResult {
    guard FileManager.default.fileExists(atPath: userPreferenceBackupURL.path) else {
        return .skipped
    }

    let data = try Data(contentsOf: userPreferenceBackupURL)
    let backup = try JSONDecoder().decode(UserPreferenceBackup.self, from: data)

    for key in keys {
        guard let value = backup.preferences[key] else {
            continue
        }

        try restoreUserDefault(key: key, value: value)
    }

    try FileManager.default.createDirectory(at: userSupportURL, withIntermediateDirectories: true)
    try writeJSON(RegionSyncRestoreState(restoredAt: timestamp()), to: regionSyncRestoreStateURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: regionSyncRestoreStateURL.path)
    return .restored
}

private func restoreUserDefault(key: String, value: UserPreferenceBackupValue) throws {
    let arguments: [String]

    switch value.kind {
    case .missing:
        arguments = ["delete", "NSGlobalDomain", key]
    case .string:
        guard let stringValue = value.stringValue else {
            return
        }
        arguments = ["write", "NSGlobalDomain", key, "-string", stringValue]
    case .bool:
        guard let boolValue = value.boolValue else {
            return
        }
        arguments = ["write", "NSGlobalDomain", key, "-bool", boolValue ? "true" : "false"]
    case .int:
        guard let intValue = value.intValue else {
            return
        }
        arguments = ["write", "NSGlobalDomain", key, "-int", String(intValue)]
    case .stringArray:
        guard let stringArrayValue = value.stringArrayValue else {
            return
        }
        arguments = ["write", "NSGlobalDomain", key, "-array"] + stringArrayValue
    }

    let result = runProcess(path: "/usr/bin/defaults", arguments: arguments)
    if !result.success && value.kind != .missing {
        throw IPTimeMenuError("failed to restore \(key): \(result.message)")
    }
}

private func userPreferenceBackupValue(from value: Any?) -> UserPreferenceBackupValue {
    guard let value else {
        return .missing()
    }

    if let stringArray = value as? [String] {
        return .stringArray(stringArray)
    }

    if let array = value as? [Any] {
        let strings = array.compactMap { $0 as? String }
        if strings.count == array.count {
            return .stringArray(strings)
        }
    }

    if let stringValue = value as? String {
        return .string(stringValue)
    }

    if let boolValue = value as? Bool {
        return .bool(boolValue)
    }

    if let numberValue = value as? NSNumber {
        if CFGetTypeID(numberValue) == CFBooleanGetTypeID() {
            return .bool(numberValue.boolValue)
        }

        return .int(numberValue.intValue)
    }

    if let intValue = value as? Int {
        return .int(intValue)
    }

    return .missing()
}

private func userPreferenceRestoreScript(preferences: [String: UserPreferenceBackupValue]) -> String {
    var lines = [
        "#!/bin/sh",
        "set +e"
    ]

    for key in userPreferenceKeysToBackup {
        guard let value = preferences[key] else {
            continue
        }

        switch value.kind {
        case .missing:
            lines.append("/usr/bin/defaults delete NSGlobalDomain \(shellQuoted(key)) >/dev/null 2>&1 || true")
        case .string:
            guard let stringValue = value.stringValue else {
                continue
            }
            lines.append("/usr/bin/defaults write NSGlobalDomain \(shellQuoted(key)) -string \(shellQuoted(stringValue)) >/dev/null 2>&1 || true")
        case .bool:
            guard let boolValue = value.boolValue else {
                continue
            }
            lines.append("/usr/bin/defaults write NSGlobalDomain \(shellQuoted(key)) -bool \(boolValue ? "true" : "false") >/dev/null 2>&1 || true")
        case .int:
            guard let intValue = value.intValue else {
                continue
            }
            lines.append("/usr/bin/defaults write NSGlobalDomain \(shellQuoted(key)) -int \(intValue) >/dev/null 2>&1 || true")
        case .stringArray:
            guard let stringArrayValue = value.stringArrayValue else {
                continue
            }
            let values = stringArrayValue.map(shellQuoted).joined(separator: " ")
            lines.append("/usr/bin/defaults write NSGlobalDomain \(shellQuoted(key)) -array \(values) >/dev/null 2>&1 || true")
        }
    }

    lines.append("/usr/bin/killall cfprefsd >/dev/null 2>&1 || true")
    lines.append("exit 0")
    return lines.joined(separator: "\n") + "\n"
}

private func userDefaultValue(_ value: String, matches expected: UserDefaultExpectedValue) -> Bool {
    let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)

    switch expected {
    case .string(let expectedValue):
        return normalizedValue == expectedValue
    case .bool(let expectedValue):
        let lowercased = normalizedValue.lowercased()
        let trueValues = Set(["1", "true", "yes"])
        let falseValues = Set(["0", "false", "no"])
        return expectedValue ? trueValues.contains(lowercased) : falseValues.contains(lowercased)
    case .int(let expectedValue):
        return Int(normalizedValue) == expectedValue
    }
}

private func runProcess(path: String, arguments: [String]) -> (success: Bool, message: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments

    let output = Pipe()
    process.standardOutput = output
    process.standardError = output

    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return (false, error.localizedDescription)
    }

    let data = output.fileHandleForReading.readDataToEndOfFile()
    let message = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    if process.terminationStatus == 0 {
        return (true, message)
    }

    return (false, message.isEmpty ? "exit code \(process.terminationStatus)" : message)
}

private func shellQuoted(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}

private func appleScriptString(_ value: String) -> String {
    let escaped = value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
    return "\"\(escaped)\""
}

private struct IPTimeError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

private struct IPTimeMenuError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

private final class StatusBarView: NSView {
    var segments: [StatusSegment] = [] {
        didSet {
            let width = intrinsicContentSize.width
            frame = NSRect(x: frame.origin.x, y: frame.origin.y, width: width, height: NSStatusBar.system.thickness)
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    var onClick: (() -> Void)?
    private var frameTimer: Timer?

    private let capsuleInset: CGFloat = 1
    private let capsuleHeight: CGFloat = 20
    private let segmentPadding: CGFloat = 9
    private let dividerPadding: CGFloat = 7
    private let flagGap: CGFloat = 5
    private let detailGap: CGFloat = 7
    private let activityIndicatorGap: CGFloat = 5
    private let activityIndicatorSize: CGFloat = 8
    private let primaryFont = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
    private let detailFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)

    override var intrinsicContentSize: NSSize {
        guard !segments.isEmpty else {
            return NSSize(width: 24, height: NSStatusBar.system.thickness)
        }

        let totalSegmentsWidth = segments.reduce(CGFloat(0)) { total, segment in
            total + segmentWidth(for: segment)
        }
        let dividerWidth = CGFloat(max(segments.count - 1, 0)) * (dividerPadding * 2 + 1)
        let width = capsuleInset * 2 + totalSegmentsWidth + dividerWidth

        return NSSize(width: ceil(width), height: NSStatusBar.system.thickness)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        frame = NSRect(x: 0, y: 0, width: 24, height: NSStatusBar.system.thickness)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    func setAnimating(_ enabled: Bool) {
        if enabled {
            guard frameTimer == nil else {
                return
            }

            let timer = Timer(timeInterval: 1.0 / 60.0, target: self, selector: #selector(animationFrameFired), userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .common)
            frameTimer = timer
        } else {
            frameTimer?.invalidate()
            frameTimer = nil
        }
    }

    @objc private func animationFrameFired() {
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard !segments.isEmpty else {
            return
        }

        let capsuleRect = NSRect(
            x: capsuleInset,
            y: (bounds.height - capsuleHeight) / 2,
            width: max(bounds.width - capsuleInset * 2, 0),
            height: capsuleHeight
        )
        let path = NSBezierPath(roundedRect: capsuleRect, xRadius: 8, yRadius: 8)
        NSColor.labelColor.withAlphaComponent(0.10).setFill()
        path.fill()
        NSColor.labelColor.withAlphaComponent(0.17).setStroke()
        path.lineWidth = 0.8
        path.stroke()

        var x = capsuleRect.minX
        for (index, segment) in segments.enumerated() {
            let width = self.segmentWidth(for: segment)
            let rect = NSRect(x: x, y: capsuleRect.minY, width: width, height: capsuleRect.height)
            drawSegment(segment, in: rect)
            x += width

            if index < segments.count - 1 {
                x += dividerPadding
                drawDivider(x: x, in: capsuleRect)
                x += 1 + dividerPadding
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onClick?()
    }

    private func drawSegment(_ segment: StatusSegment, in rect: NSRect) {
        var x = rect.minX + segmentPadding

        if !segment.flag.isEmpty {
            let flag = attributed(segment.flag, font: primaryFont, color: NSColor.controlTextColor)
            draw(flag, atX: x, centerY: rect.midY)
            x += flag.size().width + flagGap
        }

        let primaryColor = segment.isError ? NSColor.systemRed : NSColor.controlTextColor
        let primary = attributed(segment.primary, font: primaryFont, color: primaryColor)
        if let detail = segment.detail, segment.detailFirst {
            let detailColor = segment.isError ? NSColor.systemRed : NSColor.secondaryLabelColor
            let detailText = attributed(detail, font: detailFont, color: detailColor)
            draw(detailText, atX: x, centerY: rect.midY + 0.4)
            x += detailText.size().width + detailGap
        }

        draw(primary, atX: x, centerY: rect.midY)
        x += primary.size().width

        if let detail = segment.detail, !segment.detailFirst {
            x += detailGap
            let detailColor = segment.isError ? NSColor.systemRed : NSColor.secondaryLabelColor
            let detailText = attributed(detail, font: detailFont, color: detailColor)
            draw(detailText, atX: x, centerY: rect.midY + 0.4)
            x += detailText.size().width
        }

        if segment.activity.isVisible {
            x += activityIndicatorGap
            drawActivityIndicator(segment.activity, atX: x, centerY: rect.midY, color: segment.isError ? .systemRed : .secondaryLabelColor)
        }
    }

    private func drawDivider(x: CGFloat, in rect: NSRect) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x, y: rect.minY + 4))
        path.line(to: NSPoint(x: x, y: rect.maxY - 4))
        NSColor.labelColor.withAlphaComponent(0.18).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func draw(_ text: NSAttributedString, atX x: CGFloat, centerY: CGFloat) {
        let size = text.size()
        text.draw(in: NSRect(x: x, y: centerY - size.height / 2 - 0.5, width: size.width, height: size.height))
    }

    private func drawActivityIndicator(_ activity: StatusActivityIndicator, atX x: CGFloat, centerY: CGFloat, color: NSColor) {
        let rect = NSRect(
            x: x,
            y: centerY - activityIndicatorSize / 2 - 0.2,
            width: activityIndicatorSize,
            height: activityIndicatorSize
        )
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = activityIndicatorSize / 2 - 0.8

        switch activity {
        case .none:
            break
        case .checking:
            drawCometIndicator(center: center, radius: radius, rect: rect, color: color)
        case .completed(let completedAt):
            drawCompletionCheck(center: center, radius: radius, completedAt: completedAt)
        }
    }

    private func drawCometIndicator(center: NSPoint, radius: CGFloat, rect: NSRect, color: NSColor) {
        let track = NSBezierPath(ovalIn: rect.insetBy(dx: 0.6, dy: 0.6))
        NSColor.labelColor.withAlphaComponent(0.10).setStroke()
        track.lineWidth = 1
        track.stroke()

        let phase = Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
        let head = CGFloat(phase * 360)
        let segmentCount = 24
        let tailSpan: CGFloat = 280

        for index in 0..<segmentCount {
            let tailPosition = CGFloat(index) / CGFloat(segmentCount)
            let startAngle = head - tailPosition * tailSpan
            let endAngle = startAngle - tailSpan / CGFloat(segmentCount) - 1
            let segment = NSBezierPath()
            segment.appendArc(withCenter: center, radius: radius, startAngle: endAngle, endAngle: startAngle, clockwise: false)
            segment.lineWidth = 1.25
            segment.lineCapStyle = .round
            color.withAlphaComponent(0.95 * (1 - tailPosition)).setStroke()
            segment.stroke()
        }
    }

    private func drawCompletionCheck(center: NSPoint, radius: CGFloat, completedAt: Date) {
        let elapsed = max(Date().timeIntervalSince(completedAt), 0)
        let drawProgress = min(1, CGFloat(elapsed / 0.35))
        let fadeProgress = max(0, min(1, CGFloat((elapsed - 0.9) / 0.6)))
        let alpha = 0.95 * (1 - fadeProgress)

        guard alpha > 0 else {
            return
        }

        let start = NSPoint(x: center.x - radius * 0.62, y: center.y - radius * 0.02)
        let corner = NSPoint(x: center.x - radius * 0.13, y: center.y - radius * 0.47)
        let end = NSPoint(x: center.x + radius * 0.67, y: center.y + radius * 0.48)
        let check = NSBezierPath()
        check.move(to: start)

        if drawProgress < 0.5 {
            check.line(to: lerp(start, corner, drawProgress / 0.5))
        } else {
            check.line(to: corner)
            check.line(to: lerp(corner, end, (drawProgress - 0.5) / 0.5))
        }

        check.lineWidth = 1.45
        check.lineCapStyle = .round
        check.lineJoinStyle = .round
        NSColor.systemGreen.withAlphaComponent(alpha).setStroke()
        check.stroke()
    }

    private func lerp(_ start: NSPoint, _ end: NSPoint, _ progress: CGFloat) -> NSPoint {
        NSPoint(
            x: start.x + (end.x - start.x) * progress,
            y: start.y + (end.y - start.y) * progress
        )
    }

    private func segmentWidth(for segment: StatusSegment) -> CGFloat {
        var width = segmentPadding * 2
        if !segment.flag.isEmpty {
            width += attributed(segment.flag, font: primaryFont, color: .controlTextColor).size().width
            width += flagGap
        }
        width += attributed(segment.primary, font: primaryFont, color: .controlTextColor).size().width

        if let detail = segment.detail {
            width += detailGap
            width += attributed(detail, font: detailFont, color: .secondaryLabelColor).size().width
        }

        if segment.activity.isVisible {
            width += activityIndicatorGap + activityIndicatorSize
        }

        return ceil(width)
    }

    private func attributed(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    }
}

@main
private enum DualTimeMenuBar {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
