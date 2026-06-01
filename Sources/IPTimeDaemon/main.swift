import Foundation
import Darwin
import SystemConfiguration

private let ipAPIURL = URL(string: "http://ip-api.com/json")!
private let defaultStatusPath = "/Library/Application Support/IPTime/status.json"
private let statusURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["IPTIME_STATUS_PATH"] ?? defaultStatusPath)
private let supportDirectoryURL = statusURL.deletingLastPathComponent()
private let regionCheckStateURL = supportDirectoryURL.appendingPathComponent("check-state.json")
private let systemPreferenceBackupURL = supportDirectoryURL.appendingPathComponent("original-system-preferences.json")
private let systemPreferenceRestoreScriptURL = supportDirectoryURL.appendingPathComponent("restore-system-preferences.sh")
private let systemRegionSyncRestoreStateURL = supportDirectoryURL.appendingPathComponent("region-sync-restore-state.json")
private let isDryRun = ProcessInfo.processInfo.environment["IPTIME_DRY_RUN"] == "1"
private let runOnce = ProcessInfo.processInfo.environment["IPTIME_RUN_ONCE"] == "1"
private let defaultRegionCheckInterval: TimeInterval = 600
private let supportedRegionCheckIntervals = Set([60, 300, 600, 900, 1_800, 3_600])
private let activeUserRefreshInterval: TimeInterval = 60
private let missingActiveUserRefreshInterval: TimeInterval = 5
private let networkFingerprintPollInterval: TimeInterval = 5
private let networkChangeDebounceInterval: TimeInterval = 5
private let networkChangeMinimumCheckInterval: TimeInterval = 10
private let updatePollIntervalNanoseconds: UInt64 = 1_000_000_000
private let githubReleaseDownloadPrefix = "https://github.com/r2d2-off/mac-clock/releases/download/"

private struct IPInfoResponse: Decodable {
    let status: String?
    let message: String?
    let ip: String?
    let city: String?
    let region: String?
    let country: String?
    let countryName: String?
    let timezone: String?

    private enum CodingKeys: String, CodingKey {
        case status
        case message
        case ip = "query"
        case city
        case region
        case regionName
        case country
        case countryCode
        case timezone
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        ip = try container.decodeIfPresent(String.self, forKey: .ip)
        city = try container.decodeIfPresent(String.self, forKey: .city)
        region = try container.decodeIfPresent(String.self, forKey: .regionName)
            ?? container.decodeIfPresent(String.self, forKey: .region)
        country = try container.decodeIfPresent(String.self, forKey: .countryCode)
        countryName = try container.decodeIfPresent(String.self, forKey: .country)
        timezone = try container.decodeIfPresent(String.self, forKey: .timezone)
    }
}

private struct IPInfo {
    let ip: String
    let city: String?
    let region: String?
    let countryCode: String
    let countryName: String?
    let timezone: String
}

private struct IPTimeStatus: Encodable {
    let generatedAt: String
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

private struct RegionRule {
    let locale: String
    let measurementUnits: String
    let metricUnits: Bool
    let temperatureUnit: String
    let firstWeekday: Int
}

private let regionRules: [String: RegionRule] = [
    "PL": RegionRule(locale: "pl_PL", measurementUnits: "Centimeters", metricUnits: true, temperatureUnit: "Celsius", firstWeekday: 1),
    "AE": RegionRule(locale: "en_AE", measurementUnits: "Centimeters", metricUnits: true, temperatureUnit: "Celsius", firstWeekday: 1),
    "DE": RegionRule(locale: "de_DE", measurementUnits: "Centimeters", metricUnits: true, temperatureUnit: "Celsius", firstWeekday: 1),
    "NL": RegionRule(locale: "nl_NL", measurementUnits: "Centimeters", metricUnits: true, temperatureUnit: "Celsius", firstWeekday: 1),
    "FR": RegionRule(locale: "fr_FR", measurementUnits: "Centimeters", metricUnits: true, temperatureUnit: "Celsius", firstWeekday: 1),
    "US": RegionRule(locale: "en_US", measurementUnits: "Inches", metricUnits: false, temperatureUnit: "Fahrenheit", firstWeekday: 7),
    "RU": RegionRule(locale: "ru_RU", measurementUnits: "Centimeters", metricUnits: true, temperatureUnit: "Celsius", firstWeekday: 1),
    "SG": RegionRule(locale: "en_SG", measurementUnits: "Centimeters", metricUnits: true, temperatureUnit: "Celsius", firstWeekday: 1),
    "CN": RegionRule(locale: "zh_CN", measurementUnits: "Centimeters", metricUnits: true, temperatureUnit: "Celsius", firstWeekday: 1)
]

private struct ActiveUser {
    let name: String
    let uid: String
    let home: String
}

private struct ApplyResult {
    let locale: String?
    let rule: RegionRule?
    let error: String?
}

private struct UpdateRequest: Decodable {
    let requestedAt: String
    let version: String
    let assetName: String
    let downloadURL: String
}

private struct UpdateResult: Encodable {
    let generatedAt: String
    let version: String
    let status: String
    let message: String
}

private struct RecheckRequest: Decodable {
    let requestedAt: String
}

private struct RegionCheckState: Encodable {
    let startedAt: String
    let completedAt: String?
    let trigger: String
}

private struct IPTimeConfig: Decodable {
    let regionCheckIntervalSeconds: Int
    let regionSyncEnabled: Bool?
}

private struct RegionSyncRestoreState: Encodable {
    let restoredAt: String
}

private struct SystemPreferenceBackup: Encodable {
    let createdAt: String
    let timeZone: String?
}

private final class NetworkChangeMonitor {
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "local.iptime.network-monitor")
    private var store: SCDynamicStore?

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    func start() {
        guard store == nil else {
            return
        }

        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        guard let dynamicStore = SCDynamicStoreCreate(
            nil,
            "local.iptime.daemon" as CFString,
            { _, _, info in
                guard let info else {
                    return
                }

                let monitor = Unmanaged<NetworkChangeMonitor>.fromOpaque(info).takeUnretainedValue()
                monitor.onChange()
            },
            &context
        ) else {
            FileHandle.standardError.write(Data("Failed to create network change monitor\n".utf8))
            return
        }

        let patterns = [
            "State:/Network/Global/IPv4",
            "State:/Network/Global/IPv6",
            "State:/Network/Global/DNS",
            "State:/Network/Interface/.*/IPv4",
            "State:/Network/Interface/.*/IPv6",
            "State:/Network/Interface/.*/AirPort"
        ] as CFArray

        guard SCDynamicStoreSetNotificationKeys(dynamicStore, nil, patterns),
              SCDynamicStoreSetDispatchQueue(dynamicStore, queue) else {
            FileHandle.standardError.write(Data("Failed to start network change monitor\n".utf8))
            return
        }

        store = dynamicStore
    }

    func stop() {
        if let store {
            SCDynamicStoreSetDispatchQueue(store, nil)
        }

        store = nil
    }
}

@main
private enum IPTimeDaemon {
    static func main() async {
        let runner = Runner()
        await runner.run()
    }
}

private final class Runner {
    private var updateInProgress = false
    private let immediateCheckLock = NSLock()
    private var immediateRegionCheckAfter: Date?
    private var lastNetworkTriggeredRegionCheck = Date.distantPast
    private var lastNetworkFingerprintCheck = Date.distantPast
    private var lastNetworkFingerprint: String?
    private var cachedActiveUser: ActiveUser?
    private var lastActiveUserRefresh = Date.distantPast
    private var networkMonitor: NetworkChangeMonitor?

    func run() async {
        if isDryRun || runOnce {
            await runSingleCheck(activeUser: findActiveUser(), trigger: isDryRun ? "dry-run" : "manual")
            return
        }

        await runLoop()
    }

    private func runLoop() async {
        var lastRegionCheck = Date.distantPast
        let monitor = NetworkChangeMonitor { [weak self] in
            self?.scheduleImmediateRegionCheck()
        }
        networkMonitor = monitor
        monitor.start()

        while true {
            let now = Date()
            let activeUser = activeUser(now: now)
            let regionCheckInterval = configuredRegionCheckInterval(activeUser: activeUser)

            pollNetworkFingerprint(now: now)

            if await handleManualRecheckRequest(activeUser: activeUser) {
                lastRegionCheck = Date()
            } else if consumeImmediateRegionCheckRequest(now: now) {
                await runSingleCheck(activeUser: activeUser, trigger: "network")
                lastRegionCheck = Date()
            } else if now.timeIntervalSince(lastRegionCheck) >= regionCheckInterval {
                await runSingleCheck(activeUser: activeUser, trigger: "scheduled")
                lastRegionCheck = Date()
            }

            await handleUpdateRequest(activeUser: activeUser)
            try? await Task.sleep(nanoseconds: updatePollIntervalNanoseconds)
        }
    }

    private func activeUser(now: Date) -> ActiveUser? {
        let refreshInterval = cachedActiveUser == nil ? missingActiveUserRefreshInterval : activeUserRefreshInterval
        guard now.timeIntervalSince(lastActiveUserRefresh) >= refreshInterval else {
            return cachedActiveUser
        }

        cachedActiveUser = findActiveUser()
        lastActiveUserRefresh = now
        return cachedActiveUser
    }

    private func scheduleImmediateRegionCheck() {
        let dueAt = Date().addingTimeInterval(networkChangeDebounceInterval)

        immediateCheckLock.lock()
        immediateRegionCheckAfter = dueAt
        immediateCheckLock.unlock()
    }

    private func pollNetworkFingerprint(now: Date) {
        guard now.timeIntervalSince(lastNetworkFingerprintCheck) >= networkFingerprintPollInterval else {
            return
        }

        lastNetworkFingerprintCheck = now
        guard let fingerprint = currentNetworkFingerprint() else {
            return
        }

        if let lastNetworkFingerprint, lastNetworkFingerprint != fingerprint {
            scheduleImmediateRegionCheck()
        }

        lastNetworkFingerprint = fingerprint
    }

    private func consumeImmediateRegionCheckRequest(now: Date) -> Bool {
        immediateCheckLock.lock()
        defer {
            immediateCheckLock.unlock()
        }

        guard let dueAt = immediateRegionCheckAfter, now >= dueAt else {
            return false
        }

        immediateRegionCheckAfter = nil
        let nextAllowedCheck = lastNetworkTriggeredRegionCheck.addingTimeInterval(networkChangeMinimumCheckInterval)
        guard now >= nextAllowedCheck else {
            immediateRegionCheckAfter = nextAllowedCheck
            return false
        }

        lastNetworkTriggeredRegionCheck = now
        return true
    }

    private func cancelImmediateRegionCheckRequest() {
        immediateCheckLock.lock()
        immediateRegionCheckAfter = nil
        immediateCheckLock.unlock()
    }

    private func refreshNetworkFingerprintBaseline(now: Date) {
        lastNetworkFingerprintCheck = now
        lastNetworkFingerprint = currentNetworkFingerprint()
    }

    private func handleManualRecheckRequest(activeUser: ActiveUser?) async -> Bool {
        guard let activeUser else {
            return false
        }

        let requestURL = recheckRequestURL(for: activeUser)
        guard FileManager.default.fileExists(atPath: requestURL.path) else {
            return false
        }

        if let data = try? Data(contentsOf: requestURL) {
            _ = try? JSONDecoder().decode(RecheckRequest.self, from: data)
        }

        try? FileManager.default.removeItem(at: requestURL)
        cancelImmediateRegionCheckRequest()
        await runSingleCheck(activeUser: activeUser, trigger: "manual")
        lastNetworkTriggeredRegionCheck = Date()
        cancelImmediateRegionCheckRequest()
        refreshNetworkFingerprintBaseline(now: Date())
        return true
    }

    private func configuredRegionCheckInterval(activeUser: ActiveUser?) -> TimeInterval {
        guard let activeUser,
              let data = try? Data(contentsOf: configURL(for: activeUser)),
              let config = try? JSONDecoder().decode(IPTimeConfig.self, from: data),
              supportedRegionCheckIntervals.contains(config.regionCheckIntervalSeconds) else {
            return defaultRegionCheckInterval
        }

        return TimeInterval(config.regionCheckIntervalSeconds)
    }

    private func isRegionSyncEnabled(activeUser: ActiveUser?) -> Bool {
        guard let activeUser,
              let data = try? Data(contentsOf: configURL(for: activeUser)),
              let config = try? JSONDecoder().decode(IPTimeConfig.self, from: data) else {
            return true
        }

        return config.regionSyncEnabled ?? true
    }

    private func runSingleCheck(activeUser: ActiveUser?, trigger: String) async {
        let startedAt = timestamp()
        writeRegionCheckState(startedAt: startedAt, completedAt: nil, trigger: trigger)
        defer {
            writeRegionCheckState(startedAt: startedAt, completedAt: timestamp(), trigger: trigger)
        }

        guard isRegionSyncEnabled(activeUser: activeUser) else {
            let error = isDryRun ? nil : restoreOriginalSystemPreferencesIfNeeded()
            writeStatus(info: nil, activeUser: activeUser, locale: nil, rule: nil, error: error)
            return
        }

        if !isDryRun {
            clearRegionSyncRestoreState()
        }

        do {
            let info = try await fetchIPInfo()
            let result = apply(info: info)
            writeStatus(info: info, activeUser: activeUser, locale: result.locale, rule: result.rule, error: result.error)
        } catch {
            writeStatus(info: nil, activeUser: activeUser, locale: nil, rule: nil, error: error.localizedDescription)
        }
    }

    private func restoreOriginalSystemPreferencesIfNeeded() -> String? {
        if FileManager.default.fileExists(atPath: systemRegionSyncRestoreStateURL.path) {
            return nil
        }

        if let error = restoreOriginalSystemPreferences() {
            return error
        }

        do {
            try FileManager.default.createDirectory(at: systemRegionSyncRestoreStateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let state = RegionSyncRestoreState(restoredAt: timestamp())
            try writeJSON(state, to: systemRegionSyncRestoreStateURL)
            _ = runProcess(path: "/usr/sbin/chown", arguments: ["root:wheel", systemRegionSyncRestoreStateURL.path])
            _ = runProcess(path: "/bin/chmod", arguments: ["600", systemRegionSyncRestoreStateURL.path])
            return nil
        } catch {
            return "Failed to record region sync restore state: \(error.localizedDescription)"
        }
    }

    private func clearRegionSyncRestoreState() {
        try? FileManager.default.removeItem(at: systemRegionSyncRestoreStateURL)
    }

    private func handleUpdateRequest(activeUser: ActiveUser?) async {
        guard !updateInProgress, let activeUser else {
            return
        }

        let requestURL = updateRequestURL(for: activeUser)
        guard FileManager.default.fileExists(atPath: requestURL.path) else {
            return
        }

        updateInProgress = true
        defer {
            updateInProgress = false
        }

        var requestedVersion = "unknown"
        do {
            let data = try Data(contentsOf: requestURL)
            let request = try JSONDecoder().decode(UpdateRequest.self, from: data)
            requestedVersion = request.version
            writeUpdateResult(
                activeUser: activeUser,
                version: request.version,
                status: "validating",
                message: "Validating update \(request.version)"
            )
            try validateUpdateRequest(request)
            try await installUpdate(request, activeUser: activeUser)
            try? FileManager.default.removeItem(at: requestURL)
            writeUpdateResult(
                activeUser: activeUser,
                version: request.version,
                status: "installed",
                message: "Installed \(request.version)"
            )
            exit(0)
        } catch {
            try? FileManager.default.removeItem(at: requestURL)
            writeUpdateResult(
                activeUser: activeUser,
                version: requestedVersion,
                status: "failed",
                message: error.localizedDescription
            )
        }
    }

    private func validateUpdateRequest(_ request: UpdateRequest) throws {
        guard request.assetName == updateAssetName else {
            throw IPTimeError("Unexpected update asset \(request.assetName); expected \(updateAssetName)")
        }

        guard request.version.range(of: #"^v?[0-9]+(\.[0-9]+)*$"#, options: .regularExpression) != nil else {
            throw IPTimeError("Invalid update version \(request.version)")
        }

        guard let url = URL(string: request.downloadURL),
              url.scheme == "https",
              url.absoluteString.hasPrefix(githubReleaseDownloadPrefix) else {
            throw IPTimeError("Update URL is not an IP Time GitHub release asset")
        }
    }

    private func installUpdate(_ request: UpdateRequest, activeUser: ActiveUser) async throws {
        let updatesDirectory = supportDirectoryURL.appendingPathComponent("updates", isDirectory: true)
        let workDirectory = updatesDirectory.appendingPathComponent("\(safePathComponent(request.version))-\(UUID().uuidString)", isDirectory: true)
        let archiveURL = workDirectory.appendingPathComponent(request.assetName)
        let unpackedURL = workDirectory.appendingPathComponent("unpacked", isDirectory: true)
        let distURL = unpackedURL.appendingPathComponent("IPTime-macos-\(currentArchitecture)", isDirectory: true)
        let appSourceURL = distURL.appendingPathComponent("IP Time.app", isDirectory: true)
        let daemonSourceURL = distURL.appendingPathComponent("iptime-daemon")
        let appDestinationURL = URL(fileURLWithPath: "/Applications/IP Time.app", isDirectory: true)
        let stagedAppURL = URL(fileURLWithPath: "/Applications/IP Time.app.update", isDirectory: true)
        let daemonDestinationURL = URL(fileURLWithPath: "/usr/local/libexec/iptime-daemon")
        let stagedDaemonURL = URL(fileURLWithPath: "/usr/local/libexec/iptime-daemon.update")
        let plistURL = URL(fileURLWithPath: "/Library/LaunchDaemons/local.iptime.daemon.plist")

        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: workDirectory)
        }

        writeUpdateResult(
            activeUser: activeUser,
            version: request.version,
            status: "downloading",
            message: "Downloading update \(request.version)"
        )
        try await downloadUpdate(from: request.downloadURL, to: archiveURL, activeUser: activeUser)
        writeUpdateResult(
            activeUser: activeUser,
            version: request.version,
            status: "unpacking",
            message: "Unpacking update \(request.version)"
        )
        try FileManager.default.createDirectory(at: unpackedURL, withIntermediateDirectories: true)
        try runOrThrow(path: "/usr/bin/ditto", arguments: ["-x", "-k", archiveURL.path, unpackedURL.path])

        guard FileManager.default.fileExists(atPath: appSourceURL.path) else {
            throw IPTimeError("Update archive does not contain IP Time.app")
        }

        guard FileManager.default.fileExists(atPath: daemonSourceURL.path) else {
            throw IPTimeError("Update archive does not contain iptime-daemon")
        }

        writeUpdateResult(
            activeUser: activeUser,
            version: request.version,
            status: "installing",
            message: "Installing update \(request.version)"
        )
        _ = runProcess(path: "/usr/bin/killall", arguments: ["DualTimeMenuBar"])

        try FileManager.default.createDirectory(at: URL(fileURLWithPath: "/usr/local/libexec", isDirectory: true), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: stagedAppURL)
        try runOrThrow(path: "/usr/bin/ditto", arguments: [appSourceURL.path, stagedAppURL.path])
        try? FileManager.default.removeItem(at: appDestinationURL)
        try runOrThrow(path: "/bin/mv", arguments: [stagedAppURL.path, appDestinationURL.path])
        try runOrThrow(path: "/usr/sbin/chown", arguments: ["-R", "root:wheel", appDestinationURL.path])

        try runOrThrow(path: "/usr/bin/install", arguments: ["-o", "root", "-g", "wheel", "-m", "755", daemonSourceURL.path, stagedDaemonURL.path])
        try runOrThrow(path: "/bin/mv", arguments: ["-f", stagedDaemonURL.path, daemonDestinationURL.path])

        try writeLaunchDaemonPlist(to: plistURL)
        try runOrThrow(path: "/usr/sbin/chown", arguments: ["root:wheel", plistURL.path])
        try runOrThrow(path: "/bin/chmod", arguments: ["644", plistURL.path])
        try scheduleLaunchDaemonRestart(plistURL: plistURL)

        writeUpdateResult(
            activeUser: activeUser,
            version: request.version,
            status: "restarting",
            message: "Restarting IP Time"
        )
        _ = runAsUser(activeUser, arguments: ["open", appDestinationURL.path])
    }

    private func apply(info: IPInfo) -> ApplyResult {
        let country = info.countryCode
        guard let rule = regionRules[country] else {
            return ApplyResult(locale: nil, rule: nil, error: "No regional rule for country \(country); system not changed")
        }

        var errors: [String] = []
        guard backupSystemPreferencesIfNeeded(errors: &errors) else {
            return ApplyResult(locale: nil, rule: nil, error: errors.joined(separator: "; "))
        }

        let timeZoneResult = applyTimeZoneIfNeeded(info.timezone)
        if let error = timeZoneResult {
            errors.append(error)
            return ApplyResult(locale: nil, rule: nil, error: errors.joined(separator: "; "))
        }

        return ApplyResult(locale: rule.locale, rule: rule, error: errors.isEmpty ? nil : errors.joined(separator: "; "))
    }

    private func backupSystemPreferencesIfNeeded(errors: inout [String]) -> Bool {
        guard !isDryRun else {
            return true
        }

        if FileManager.default.fileExists(atPath: systemPreferenceBackupURL.path) {
            return true
        }

        let timeZoneResult = runProcess(path: "/usr/sbin/systemsetup", arguments: ["-gettimezone"])
        let timeZone = parseSystemSetupTimeZone(timeZoneResult.message) ?? TimeZone.autoupdatingCurrent.identifier
        let backup = SystemPreferenceBackup(createdAt: timestamp(), timeZone: timeZone)

        do {
            try FileManager.default.createDirectory(at: supportDirectoryURL, withIntermediateDirectories: true)
            try writeJSON(backup, to: systemPreferenceBackupURL)
            try systemPreferenceRestoreScript(timeZone: timeZone).data(using: .utf8)?.write(to: systemPreferenceRestoreScriptURL, options: .atomic)
            _ = runProcess(path: "/usr/sbin/chown", arguments: ["root:wheel", systemPreferenceBackupURL.path, systemPreferenceRestoreScriptURL.path])
            _ = runProcess(path: "/bin/chmod", arguments: ["600", systemPreferenceBackupURL.path])
            _ = runProcess(path: "/bin/chmod", arguments: ["700", systemPreferenceRestoreScriptURL.path])
            return true
        } catch {
            errors.append("Failed to save original system preferences: \(error.localizedDescription); system not changed")
            return false
        }
    }

    private func restoreOriginalSystemPreferences() -> String? {
        if FileManager.default.fileExists(atPath: systemPreferenceRestoreScriptURL.path) {
            let result = runProcess(path: "/bin/sh", arguments: [systemPreferenceRestoreScriptURL.path])
            if !result.success {
                return "Failed to restore system preferences: \(result.message)"
            }
        }

        return nil
    }

    private func applyTimeZoneIfNeeded(_ timeZone: String) -> String? {
        if TimeZone.autoupdatingCurrent.identifier == timeZone {
            return nil
        }

        if isDryRun {
            return nil
        }

        let result = runProcess(path: "/usr/sbin/systemsetup", arguments: ["-settimezone", timeZone])
        return result.success ? nil : "Failed to set timezone: \(result.message)"
    }

    private func writeStatus(info: IPInfo?, activeUser: ActiveUser?, locale: String?, rule: RegionRule?, error: String?) {
        let countryCode = info?.countryCode
        let status = IPTimeStatus(
            generatedAt: timestamp(),
            ip: info?.ip,
            city: info?.city,
            region: info?.region,
            countryCode: countryCode,
            country: countryName(for: countryCode, fallback: info?.countryName ?? info?.region),
            timeZone: info?.timezone,
            locale: locale,
            measurementUnits: rule?.measurementUnits,
            metricUnits: rule?.metricUnits,
            temperatureUnit: rule?.temperatureUnit,
            firstWeekday: rule?.firstWeekday,
            activeUser: activeUser?.name,
            error: normalized(error)
        )

        do {
            let directory = statusURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(status)
            try data.write(to: statusURL, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("Failed to write status: \(error.localizedDescription)\n".utf8))
        }
    }

    private func writeRegionCheckState(startedAt: String, completedAt: String?, trigger: String) {
        let state = RegionCheckState(startedAt: startedAt, completedAt: completedAt, trigger: trigger)

        do {
            try FileManager.default.createDirectory(at: supportDirectoryURL, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state)
            try data.write(to: regionCheckStateURL, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("Failed to write region check state: \(error.localizedDescription)\n".utf8))
        }
    }
}

private func fetchIPInfo() async throws -> IPInfo {
    let response = try await fetchDecodable(IPInfoResponse.self, from: ipAPIURL)
    guard response.status == "success" else {
        let message = safeErrorDetail(response.message) ?? "unknown error"
        throw IPTimeError("ip-api.com lookup failed: \(message)")
    }

    guard let ip = validatedIPAddress(response.ip) else {
        throw IPTimeError("ip-api.com returned an invalid IP address")
    }

    guard let countryCode = validatedCountryCode(response.country) else {
        throw IPTimeError("ip-api.com returned an invalid country code")
    }

    guard regionRules[countryCode] != nil else {
        throw IPTimeError("Unsupported country from ip-api.com: \(countryCode)")
    }

    guard let timezone = validatedTimeZoneIdentifier(response.timezone) else {
        throw IPTimeError("ip-api.com returned an invalid timezone")
    }

    return IPInfo(
        ip: ip,
        city: try validatedDisplayText(response.city, field: "city", maxLength: 96),
        region: try validatedDisplayText(response.region, field: "region", maxLength: 96),
        countryCode: countryCode,
        countryName: try validatedDisplayText(response.countryName, field: "country", maxLength: 96),
        timezone: timezone
    )
}

private func validatedIPAddress(_ value: String?) -> String? {
    guard let value = normalized(value), value.count <= 45 else {
        return nil
    }

    var ipv4 = in_addr()
    if value.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
        return value
    }

    var ipv6 = in6_addr()
    if value.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
        return value
    }

    return nil
}

private func validatedCountryCode(_ value: String?) -> String? {
    guard let value = normalized(value), value.count == 2 else {
        return nil
    }

    let scalars = Array(value.unicodeScalars)
    guard scalars.allSatisfy({ scalar in
        scalar.value >= 65 && scalar.value <= 90
    }) else {
        return nil
    }

    return value
}

private func validatedTimeZoneIdentifier(_ value: String?) -> String? {
    guard let value = normalized(value), value.count <= 96 else {
        return nil
    }

    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_./+-")
    guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }),
          TimeZone(identifier: value) != nil else {
        return nil
    }

    return value
}

private func validatedDisplayText(_ value: String?, field: String, maxLength: Int) throws -> String? {
    guard let value = normalized(value) else {
        return nil
    }

    guard value.count <= maxLength, value.utf8.count <= maxLength * 4 else {
        throw IPTimeError("ip-api.com returned an overlong \(field)")
    }

    guard value.unicodeScalars.allSatisfy({ scalar in
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .surrogate, .unassigned:
            return false
        default:
            return true
        }
    }) else {
        throw IPTimeError("ip-api.com returned an invalid \(field)")
    }

    return value
}

private func safeErrorDetail(_ value: String?) -> String? {
    try? validatedDisplayText(value, field: "message", maxLength: 160)
}

private func currentNetworkFingerprint() -> String? {
    guard let store = SCDynamicStoreCreate(nil, "local.iptime.fingerprint" as CFString, nil, nil) else {
        return nil
    }

    let globalIPv4 = dynamicStoreDictionary(store, key: "State:/Network/Global/IPv4")
    let globalIPv6 = dynamicStoreDictionary(store, key: "State:/Network/Global/IPv6")
    let globalDNS = dynamicStoreDictionary(store, key: "State:/Network/Global/DNS")

    let primaryInterface = stringValue(globalIPv4["PrimaryInterface"])
        ?? stringValue(globalIPv6["PrimaryInterface"])
    let primaryService = stringValue(globalIPv4["PrimaryService"])
        ?? stringValue(globalIPv6["PrimaryService"])
    let interfaceIPv4 = primaryInterface.map { dynamicStoreDictionary(store, key: "State:/Network/Interface/\($0)/IPv4") } ?? [:]

    var parts: [String] = []
    appendFingerprintPart("primaryInterface", primaryInterface, to: &parts)
    appendFingerprintPart("primaryService", primaryService, to: &parts)
    appendFingerprintPart("ipv4Router", stringValue(interfaceIPv4["Router"]) ?? stringValue(globalIPv4["Router"]), to: &parts)
    appendFingerprintPart("ipv4Addresses", stringArray(interfaceIPv4["Addresses"]).sorted(), to: &parts)
    appendFingerprintPart("dnsServers", stringArray(globalDNS["ServerAddresses"]).sorted(), to: &parts)
    appendFingerprintPart("dnsDomain", stringValue(globalDNS["DomainName"]), to: &parts)
    appendFingerprintPart("dnsSearchDomains", stringArray(globalDNS["SearchDomains"]).sorted(), to: &parts)
    appendFingerprintPart("dnsSupplementalMatchDomains", stringArray(globalDNS["SupplementalMatchDomains"]).sorted(), to: &parts)

    guard !parts.isEmpty else {
        return nil
    }

    return parts.joined(separator: "\n")
}

private func dynamicStoreDictionary(_ store: SCDynamicStore, key: String) -> [String: Any] {
    SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any] ?? [:]
}

private func appendFingerprintPart(_ key: String, _ value: String?, to parts: inout [String]) {
    guard let value = normalized(value) else {
        return
    }

    parts.append("\(key)=\(value)")
}

private func appendFingerprintPart(_ key: String, _ values: [String], to parts: inout [String]) {
    guard !values.isEmpty else {
        return
    }

    parts.append("\(key)=\(values.joined(separator: ","))")
}

private func stringValue(_ value: Any?) -> String? {
    value as? String
}

private func stringArray(_ value: Any?) -> [String] {
    if let values = value as? [String] {
        return values.compactMap(normalized)
    }

    if let values = value as? [Any] {
        return values.compactMap { normalized($0 as? String) }
    }

    if let value = value as? String {
        return [value].compactMap(normalized)
    }

    return []
}

private func fetchDecodable<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
    var request = URLRequest(url: url)
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    request.timeoutInterval = 20

    let (data, response) = try await URLSession.shared.data(for: request)

    if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
        throw IPTimeError("ip-api.com returned HTTP \(httpResponse.statusCode)")
    }

    return try JSONDecoder().decode(type, from: data)
}

private func findActiveUser() -> ActiveUser? {
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard let consoleUser = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) else {
        return nil
    }

    let name = (consoleUser as String).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name != "root", name != "loginwindow", !name.hasPrefix("_") else {
        return nil
    }

    return ActiveUser(
        name: name,
        uid: String(uid),
        home: homeDirectory(for: name) ?? "/Users/\(name)"
    )
}

private func homeDirectory(for userName: String) -> String? {
    userName.withCString { pointer in
        guard let passwd = getpwnam(pointer), let home = passwd.pointee.pw_dir else {
            return nil
        }

        return String(cString: home)
    }
}

private func runAsUser(_ user: ActiveUser, arguments: [String]) -> (success: Bool, message: String) {
    runAsUser(user, executablePath: "/usr/bin/\(arguments[0])", arguments: Array(arguments.dropFirst()))
}

private func runAsUser(_ user: ActiveUser, executablePath: String, arguments: [String]) -> (success: Bool, message: String) {
    runProcess(
        path: "/bin/launchctl",
        arguments: ["asuser", user.uid, "/usr/bin/sudo", "-u", user.name, "/usr/bin/env", "HOME=\(user.home)", executablePath] + arguments
    )
}

private func userSupportDirectoryURL(for user: ActiveUser) -> URL {
    URL(fileURLWithPath: user.home, isDirectory: true)
        .appendingPathComponent("Library/Application Support/IPTime", isDirectory: true)
}

private func updateRequestURL(for user: ActiveUser) -> URL {
    userSupportDirectoryURL(for: user).appendingPathComponent("update-request.json")
}

private func updateResultURL(for user: ActiveUser) -> URL {
    userSupportDirectoryURL(for: user).appendingPathComponent("update-result.json")
}

private func recheckRequestURL(for user: ActiveUser) -> URL {
    userSupportDirectoryURL(for: user).appendingPathComponent("recheck-request.json")
}

private func configURL(for user: ActiveUser) -> URL {
    userSupportDirectoryURL(for: user).appendingPathComponent("config.json")
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

private func downloadUpdate(from urlString: String, to destinationURL: URL, activeUser: ActiveUser) async throws {
    guard let url = URL(string: urlString) else {
        throw IPTimeError("Invalid update URL")
    }

    var request = URLRequest(url: url)
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    request.timeoutInterval = 120

    let (temporaryURL, response) = try await URLSession.shared.download(for: request)
    if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
        if httpResponse.statusCode == 404 {
            throw IPTimeError("GitHub update asset not found")
        }

        throw IPTimeError("GitHub asset download returned HTTP \(httpResponse.statusCode)")
    }

    try? FileManager.default.removeItem(at: destinationURL)
    try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
}

private func scheduleLaunchDaemonRestart(plistURL: URL) throws {
    let scriptURL = supportDirectoryURL.appendingPathComponent("restart-daemon.sh")
    let script = """
    #!/bin/sh
    /bin/sleep 2
    /bin/launchctl bootout system \(shellQuoted(plistURL.path)) >/dev/null 2>&1 || true
    /bin/launchctl bootstrap system \(shellQuoted(plistURL.path)) >/dev/null 2>&1 || true
    /bin/launchctl enable system/local.iptime.daemon >/dev/null 2>&1 || true
    /bin/launchctl kickstart -k system/local.iptime.daemon >/dev/null 2>&1 || true
    /bin/rm -f "$0"
    """

    try FileManager.default.createDirectory(at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try script.data(using: .utf8)?.write(to: scriptURL, options: .atomic)
    try runOrThrow(path: "/usr/sbin/chown", arguments: ["root:wheel", scriptURL.path])
    try runOrThrow(path: "/bin/chmod", arguments: ["700", scriptURL.path])

    let command = "(/bin/sh \(shellQuoted(scriptURL.path)) >> /Library/Logs/IPTimeDaemon.out.log 2>> /Library/Logs/IPTimeDaemon.err.log &)"
    try runOrThrow(path: "/bin/sh", arguments: ["-c", command])
}

private func writeLaunchDaemonPlist(to url: URL) throws {
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key>
        <string>local.iptime.daemon</string>
        <key>ProgramArguments</key>
        <array>
            <string>/usr/local/libexec/iptime-daemon</string>
        </array>
        <key>RunAtLoad</key>
        <true/>
        <key>KeepAlive</key>
        <true/>
        <key>StandardOutPath</key>
        <string>/Library/Logs/IPTimeDaemon.out.log</string>
        <key>StandardErrorPath</key>
        <string>/Library/Logs/IPTimeDaemon.err.log</string>
    </dict>
    </plist>
    """

    try plist.data(using: .utf8)?.write(to: url, options: .atomic)
}

private func writeUpdateResult(activeUser: ActiveUser, version: String, status: String, message: String) {
    let resultURL = updateResultURL(for: activeUser)
    let result = UpdateResult(
        generatedAt: timestamp(),
        version: version,
        status: status,
        message: message
    )

    do {
        try FileManager.default.createDirectory(at: resultURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: resultURL, options: .atomic)
        _ = runProcess(path: "/usr/sbin/chown", arguments: ["\(activeUser.name)", resultURL.path])
        _ = runProcess(path: "/bin/chmod", arguments: ["644", resultURL.path])
    } catch {
        FileHandle.standardError.write(Data("Failed to write update result: \(error.localizedDescription)\n".utf8))
    }
}

private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: url, options: .atomic)
}

private func parseSystemSetupTimeZone(_ output: String) -> String? {
    let prefix = "Time Zone:"
    guard let line = output.split(separator: "\n").map(String.init).first(where: { $0.hasPrefix(prefix) }) else {
        return nil
    }

    let value = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
}

private func systemPreferenceRestoreScript(timeZone: String?) -> String {
    var lines = [
        "#!/bin/sh",
        "set +e"
    ]

    if let timeZone, !timeZone.isEmpty {
        lines.append("/usr/sbin/systemsetup -settimezone \(shellQuoted(timeZone)) >/dev/null 2>&1 || true")
    }

    lines.append("exit 0")
    return lines.joined(separator: "\n") + "\n"
}

private func runOrThrow(path: String, arguments: [String]) throws {
    let result = runProcess(path: path, arguments: arguments)
    if !result.success {
        throw IPTimeError("\(URL(fileURLWithPath: path).lastPathComponent) failed: \(result.message)")
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

private func safePathComponent(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
    return String(value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
}

private func shellQuoted(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}

private func countryName(for code: String?, fallback: String?) -> String? {
    guard let code else {
        return fallback
    }

    switch code {
    case "PL":
        return "Poland"
    case "AE":
        return "United Arab Emirates"
    case "DE":
        return "Germany"
    case "NL":
        return "Netherlands"
    case "FR":
        return "France"
    case "US":
        return "United States"
    case "RU":
        return "Russia"
    case "SG":
        return "Singapore"
    case "CN":
        return "China"
    default:
        return fallback
    }
}

private func normalized(_ value: String?) -> String? {
    guard let value else {
        return nil
    }

    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func timestamp() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date())
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
