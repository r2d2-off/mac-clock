import AppKit
import Foundation

private enum DefaultsKey {
    static let use24Hour = "use24Hour"
}

private let githubLatestReleaseURL = URL(string: "https://api.github.com/repos/r2d2-off/mac-clock/releases/latest")!
private let defaultStatusPath = "/Library/Application Support/IPTime/status.json"
private let statusURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["IPTIME_STATUS_PATH"] ?? defaultStatusPath)
private let userSupportURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/IPTime", isDirectory: true)
private let updateRequestURL = userSupportURL.appendingPathComponent("update-request.json")
private let updateResultURL = userSupportURL.appendingPathComponent("update-result.json")
private let moscowTimeZone = TimeZone(identifier: "Europe/Moscow")!

private struct StatusSegment {
    let flag: String
    let primary: String
    let detail: String?
    let detailFirst: Bool
    let isError: Bool

    var summary: String {
        if detailFirst {
            return [flag, detail, primary].compactMap { $0 }.joined(separator: " ")
        }

        return [flag, primary, detail].compactMap { $0 }.joined(separator: " ")
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

private struct UpdateResult: Decodable {
    let generatedAt: String
    let version: String
    let status: String
    let message: String
}

private enum UpdateState {
    case idle
    case checking
    case upToDate(String)
    case available(UpdateCandidate)
    case requested(String)
    case failed(String)
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store = UserDefaults.standard
    private var statusView: StatusBarView?
    private var timer: Timer?
    private var status: IPTimeStatus?
    private var statusReadError: String?
    private var lastStatusRead = Date.distantPast
    private var updateState: UpdateState = .idle
    private var lastUpdateCheck = Date.distantPast
    private var updateCheckInFlight = false

    private lazy var timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private lazy var dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d"
        formatter.timeZone = moscowTimeZone
        return formatter
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if store.object(forKey: DefaultsKey.use24Hour) == nil {
            store.set(true, forKey: DefaultsKey.use24Hour)
        }

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

        loadStatus()
        loadPendingUpdateState()
        buildMenu()
        updateStatusTitle()

        timer = Timer.scheduledTimer(timeInterval: 1.0, target: self, selector: #selector(timerFired), userInfo: nil, repeats: true)

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

    @objc private func timerFired() {
        if Date().timeIntervalSince(lastStatusRead) >= 5 {
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

    @objc private func checkForUpdatesFromMenu() {
        Task { [weak self] in
            await self?.checkForUpdates(silent: false)
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
            updateState = .requested(candidate.version)
        } catch {
            updateState = .failed("Failed to request update: \(error.localizedDescription)")
        }

        buildMenu()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
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
            statusReadError = nil
        } catch {
            status = nil
            statusReadError = "No daemon status yet: \(error.localizedDescription)"
        }
    }

    private func loadPendingUpdateState() {
        if FileManager.default.fileExists(atPath: updateRequestURL.path),
           let data = try? Data(contentsOf: updateRequestURL),
           let request = try? JSONDecoder().decode(UpdateRequest.self, from: data) {
            updateState = .requested(request.version)
            return
        }

        guard let data = try? Data(contentsOf: updateResultURL),
              let result = try? JSONDecoder().decode(UpdateResult.self, from: data),
              result.status == "failed" else {
            return
        }

        updateState = .failed("Update \(result.version) failed: \(result.message)")
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let summary = NSMenuItem(title: statusDisplay().summary, action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)

        menu.addItem(.separator())

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

    private func updateMenuItems() -> [NSMenuItem] {
        switch updateState {
        case .idle:
            return [NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdatesFromMenu), keyEquivalent: "")]
        case .checking:
            let item = NSMenuItem(title: "Checking for Updates...", action: nil, keyEquivalent: "")
            item.isEnabled = false
            return [item]
        case .upToDate(let version):
            let status = NSMenuItem(title: "Up to Date (\(version))", action: nil, keyEquivalent: "")
            status.isEnabled = false
            return [
                status,
                NSMenuItem(title: "Check Again...", action: #selector(checkForUpdatesFromMenu), keyEquivalent: "")
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
                NSMenuItem(title: "Retry Update Check...", action: #selector(checkForUpdatesFromMenu), keyEquivalent: "")
            ]
        }
    }

    private func detailRows() -> [String] {
        var rows: [String] = ["Managed by LaunchDaemon every 10 minutes"]

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

        rows.append("App language: English only")

        switch updateState {
        case .upToDate(let version):
            rows.append("Updates: latest version \(version)")
        case .available(let candidate):
            rows.append("Updates: \(candidate.version) available")
        case .requested(let version):
            rows.append("Updates: installing \(version)")
        case .failed(let message):
            rows.append("Updates: \(message)")
        case .checking:
            rows.append("Updates: checking")
        case .idle:
            break
        }

        return rows
    }

    private func checkForUpdates(silent: Bool) async {
        guard !updateCheckInFlight else {
            return
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
                if !silent {
                    updateState = .failed("No \(updateAssetName) asset in latest release")
                }
                return
            }

            if isVersion(candidate.version, newerThan: currentAppVersion) {
                updateState = .available(candidate)
            } else if !silent {
                updateState = .upToDate(candidate.version)
            } else if case .available = updateState {
                updateState = .upToDate(candidate.version)
            }
        } catch {
            if !silent {
                updateState = .failed(error.localizedDescription)
            }
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

        if let statusView {
            statusItem.length = statusView.intrinsicContentSize.width
        }
    }

    private func statusDisplay() -> StatusDisplay {
        let now = Date()
        let localText = formattedTime(now, in: .autoupdatingCurrent)
        let moscowText = formattedTime(now, in: moscowTimeZone)
        let moscowDate = dateFormatter.string(from: now)
        let segments = [
            StatusSegment(flag: "🇷🇺", primary: moscowText, detail: moscowDate, detailFirst: true, isError: false),
            StatusSegment(flag: flag(for: countryCode), primary: localText, detail: ipLabel, detailFirst: false, isError: displayedError != nil)
        ]

        return StatusDisplay(
            segments: segments,
            summary: segments.map(\.summary).joined(separator: "  ")
        )
    }

    private func formattedTime(_ date: Date, in timeZone: TimeZone) -> String {
        timeFormatter.timeZone = timeZone
        timeFormatter.dateFormat = store.bool(forKey: DefaultsKey.use24Hour) ? "HH:mm" : "h:mm a"
        return timeFormatter.string(from: date)
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

private func timestamp() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
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

    private let capsuleInset: CGFloat = 1
    private let capsuleHeight: CGFloat = 20
    private let segmentPadding: CGFloat = 9
    private let dividerPadding: CGFloat = 7
    private let flagGap: CGFloat = 5
    private let detailGap: CGFloat = 7
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

        let flag = attributed(segment.flag, font: primaryFont, color: NSColor.controlTextColor)
        draw(flag, atX: x, centerY: rect.midY)
        x += flag.size().width + flagGap

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

    private func segmentWidth(for segment: StatusSegment) -> CGFloat {
        var width = segmentPadding * 2
        width += attributed(segment.flag, font: primaryFont, color: .controlTextColor).size().width
        width += flagGap
        width += attributed(segment.primary, font: primaryFont, color: .controlTextColor).size().width

        if let detail = segment.detail {
            width += detailGap
            width += attributed(detail, font: detailFont, color: .secondaryLabelColor).size().width
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
