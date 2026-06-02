import CoreGraphics
import CoreWLAN
import Darwin
import Foundation
import IOKit
import IOKit.usb
import ObjectiveC.runtime

/// Set to 1 by our SIGTERM handler when a newer rescue preempts us. The
/// rescue loop polls this between attempts so we exit cleanly between
/// SidecarCore calls (running our `defer` blocks, releasing the lock
/// directory) instead of being torn down mid-XPC.
nonisolated(unsafe) var preemptRequested: sig_atomic_t = 0

/// Cross-rescue state used to detect a SidecarCore wedge — a state where
/// `connectToDevice:` keeps returning -100 ("already active") even though
/// the iPad display is gone, typically triggered by unplugging USB-C
/// mid-session. Within a single rescue we stay passive on -100 (mutating
/// state mid-teardown wedges SidecarCore worse), but if a *second* shortcut
/// press lands 15+ seconds after a previous rescue first saw -100, we know
/// teardown is long since done — so a single bounded force-disconnect at
/// startup is safe and breaks the wedge.
private struct PersistentState: Codable {
    /// Set when a rescue first observes -100 in a polling cycle. Cleared on
    /// success, on a non-already-active outcome, or by the force-disconnect
    /// path once it consumes the signal.
    var alreadyActiveSeenAt: Date?
}

private enum PersistentStateStore {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/SidecarRescue/state.plist")

    static func load() -> PersistentState {
        guard let data = try? Data(contentsOf: url),
              let state = try? PropertyListDecoder().decode(PersistentState.self, from: data) else {
            return PersistentState()
        }
        return state
    }

    static func save(_ state: PersistentState) {
        let parent = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        guard let data = try? PropertyListEncoder().encode(state) else { return }
        try? data.write(to: url)
    }
}

private func installPreemptionHandler() {
    // Only async-signal-safe operations are allowed inside the handler;
    // assignment to a sig_atomic_t is the safe minimum.
    signal(SIGTERM) { _ in
        preemptRequested = 1
    }
}

private func shouldExitForPreemption() -> Bool {
    preemptRequested != 0
}

// The SidecarCore runtime bridge is adapted from the MIT-licensed
// Ocasio-J/SidecarLauncher project by Jovany Ocasio.

private enum RescueError: Error, CustomStringConvertible {
    case callbackTimedOut
    case deviceNameRequired([String])
    case deviceUnavailable(String)
    case invalidArguments(String)
    case missingClass(String)
    case missingConfigValue(String)
    case missingSelector(String)
    case privateFrameworkUnavailable
    case privateFrameworkError(NSError)
    case queryFailed

    var description: String {
        switch self {
        case .callbackTimedOut:
            return "Sidecar did not respond before the callback timeout."
        case .deviceNameRequired(let devices):
            if devices.isEmpty {
                return "No reachable Sidecar devices were found."
            }
            return "More than one Sidecar device is reachable. Choose one with --device. Available devices: \(devices.joined(separator: ", "))"
        case .deviceUnavailable(let name):
            return "The Sidecar device is not currently reachable: \(name)"
        case .invalidArguments(let message):
            return message
        case .missingClass(let name):
            return "The private Sidecar class is unavailable: \(name)"
        case .missingConfigValue(let key):
            return "The configuration file is missing a value for \(key)."
        case .missingSelector(let name):
            return "The private Sidecar method is unavailable: \(name)"
        case .privateFrameworkUnavailable:
            return "The private SidecarCore framework could not be loaded."
        case .privateFrameworkError(let error):
            return error.description
        case .queryFailed:
            return "Sidecar devices could not be queried."
        }
    }
}

private enum ConnectionResult {
    case alreadyActive
    case connected(TransportMode)
}

private enum SidecarErrorCode {
    static let domain = "SidecarErrorDomain"
    static let alreadyActive = -100
    static let serviceDisconnected = -101
    static let deviceNotFound = -200
    static let wiFiNotEnabled = -203
}

/// Classifies a SidecarCore error for a specific transport attempt to decide
/// whether the transport is worth retrying within this rescue run.
/// `transportHopeless == true` means SidecarCore returned an error that won't
/// fix itself without the user changing system state (toggling Wi-Fi, plugging
/// in a cable). Re-attempting in the loop just spawns more system alerts.
private struct AttemptOutcome {
    var transportHopeless: Bool
    var summary: String
}

private func classify(_ error: Error, attempting transport: TransportMode) -> AttemptOutcome {
    guard case RescueError.privateFrameworkError(let nsError) = error,
          nsError.domain == SidecarErrorCode.domain else {
        return AttemptOutcome(transportHopeless: false, summary: String(describing: error))
    }
    let summary = "SidecarErrorDomain code=\(nsError.code)"
    switch (transport, nsError.code) {
    case (.wireless, SidecarErrorCode.wiFiNotEnabled):
        return AttemptOutcome(transportHopeless: true, summary: summary)
    default:
        return AttemptOutcome(transportHopeless: false, summary: summary)
    }
}

private enum TransportMode: String {
    case automatic
    case wired
    case wireless
}

private struct SidecarDevice {
    let name: String
    let object: NSObject
}

private final class CompletionState: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var storedError: NSError?

    func finish(with error: NSError?) {
        lock.lock()
        storedError = error
        lock.unlock()
        semaphore.signal()
    }

    func error() -> NSError? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }
}

private struct Reachability {
    var isConnected: Bool?
    var wiredReachable: Bool?
    var wirelessReachable: Bool?

    func shouldAttempt(_ transport: TransportMode) -> Bool {
        if isConnected == true { return true }
        switch transport {
        case .automatic:
            if wiredReachable == false && wirelessReachable == false { return false }
            return true
        case .wired:
            return wiredReachable != false
        case .wireless:
            return wirelessReachable != false
        }
    }
}

private enum DeviceProbe {
    static let wiredHints = ["wired", "usb", "tethered", "cable"]
    static let wirelessHints = ["wireless", "wifi", "ids", "rapport", "bluetooth"]
    static let connectedHints = ["connected", "active", "insession"]

    static func reachability(of object: NSObject) -> Reachability {
        var reachability = Reachability()
        for (selector, value) in zeroArgBoolValues(of: object) {
            let lower = selector.lowercased()
            let connectedMatch = connectedHints.contains { lower.contains($0) }
            if connectedMatch {
                reachability.isConnected = (reachability.isConnected ?? false) || value
                continue
            }
            let wiredMatch = wiredHints.contains { lower.contains($0) }
            let wirelessMatch = wirelessHints.contains { lower.contains($0) }
            // Skip selectors that match both lists — too ambiguous to trust.
            if wiredMatch && !wirelessMatch {
                reachability.wiredReachable = (reachability.wiredReachable ?? false) || value
            } else if wirelessMatch && !wiredMatch {
                reachability.wirelessReachable = (reachability.wirelessReachable ?? false) || value
            }
        }
        return reachability
    }

    static func zeroArgBoolValues(of object: NSObject) -> [(String, Bool)] {
        var results: [(String, Bool)] = []
        var cls: AnyClass? = object_getClass(object)
        var seen = Set<String>()
        while let current = cls, current != NSObject.self {
            var count: UInt32 = 0
            if let methods = class_copyMethodList(current, &count) {
                for index in 0..<Int(count) {
                    let selector = method_getName(methods[index])
                    let name = NSStringFromSelector(selector)
                    if name.contains(":") || name.hasPrefix("_") || name.hasPrefix(".") {
                        continue
                    }
                    if seen.contains(name) { continue }
                    seen.insert(name)
                    guard let signature = object.method(for: selector) else { continue }
                    let typeEncoding = method_getTypeEncoding(methods[index]).map { String(cString: $0) } ?? ""
                    // Only invoke methods whose return type is a single-byte BOOL/char.
                    guard typeEncoding.first.map({ "Bc".contains($0) }) ?? false else { continue }
                    typealias BoolGetter = @convention(c) (AnyObject, Selector) -> Bool
                    let getter = unsafeBitCast(signature, to: BoolGetter.self)
                    let value = getter(object, selector)
                    results.append((name, value))
                }
                free(methods)
            }
            cls = class_getSuperclass(current)
        }
        return results
    }

    static func describe(_ object: NSObject) -> [String] {
        var lines: [String] = []
        var cls: AnyClass? = object_getClass(object)
        lines.append("class: \(NSStringFromClass(object_getClass(object)!))")
        var seen = Set<String>()
        while let current = cls, current != NSObject.self {
            var propCount: UInt32 = 0
            if let props = class_copyPropertyList(current, &propCount) {
                for index in 0..<Int(propCount) {
                    let name = String(cString: property_getName(props[index]))
                    if seen.contains(name) { continue }
                    seen.insert(name)
                    let attrs = property_getAttributes(props[index]).map { String(cString: $0) } ?? ""
                    var rendered = "<unreadable>"
                    if object.responds(to: Selector(name)),
                       let raw = object.perform(Selector(name))?.takeUnretainedValue() {
                        rendered = String(describing: raw)
                    }
                    lines.append("  property \(name) [\(attrs)] = \(rendered)")
                }
                free(props)
            }
            var methodCount: UInt32 = 0
            if let methods = class_copyMethodList(current, &methodCount) {
                for index in 0..<Int(methodCount) {
                    let selector = method_getName(methods[index])
                    let selName = NSStringFromSelector(selector)
                    let encoding = method_getTypeEncoding(methods[index]).map { String(cString: $0) } ?? ""
                    lines.append("  method \(selName)  encoding: \(encoding)")
                }
                free(methods)
            }
            cls = class_getSuperclass(current)
            if let next = cls {
                lines.append("  -- super: \(NSStringFromClass(next)) --")
            }
        }
        return lines
    }
}

/// Pre-flight checks for whether a given Sidecar transport can possibly
/// succeed right now. The point is to avoid calling into SidecarCore when we
/// can prove the call will fail — because the failed call spawns an
/// "iPad unavailable" alert via SidecarRelay. CoreWLAN gives a definitive
/// answer for the Wi-Fi side; IOKit gives a definitive answer for whether
/// any iPad is plugged in over USB. Both are public-framework, no AppleScript.
private enum TransportAvailability {
    /// `true` when the Mac's Wi-Fi radio is powered on. When it's off, a
    /// wireless `connectToDevice:` call definitely fails with -203 and
    /// SidecarRelay surfaces that as an alert.
    static func macWiFiPoweredOn() -> Bool {
        // Default to `true` on any lookup failure — better to attempt and
        // possibly get one alert than to silently skip a working transport.
        guard let interface = CWWiFiClient.shared().interface() else { return true }
        return interface.powerOn()
    }

    /// `true` when some Apple iPad-class device is currently enumerated on
    /// USB. We don't try to match the exact configured device name (the USB
    /// product string and the Sidecar device name aren't guaranteed to
    /// match), just whether *any* iPad is plugged in.
    static func iPadOnUSB() -> Bool {
        let matchers: [String] = ["IOUSBHostDevice", "IOUSBDevice"]
        for className in matchers {
            guard let matching = IOServiceMatching(className) else { continue }
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
                continue
            }
            defer { IOObjectRelease(iterator) }
            var service = IOIteratorNext(iterator)
            while service != 0 {
                let current = service
                service = IOIteratorNext(iterator)
                defer { IOObjectRelease(current) }
                if usbServiceLooksLikeIPad(current) {
                    return true
                }
            }
        }
        return false
    }

    private static func usbServiceLooksLikeIPad(_ service: io_service_t) -> Bool {
        if let product = ioRegistryString(service, key: "USB Product Name"),
           product.localizedCaseInsensitiveContains("ipad") {
            return true
        }
        if let product = ioRegistryString(service, key: "kUSBProductString"),
           product.localizedCaseInsensitiveContains("ipad") {
            return true
        }
        return false
    }

    private static func ioRegistryString(_ service: io_service_t, key: String) -> String? {
        guard let raw = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return nil
        }
        return raw as? String
    }
}

/// SidecarCore's `connectToDevice:` can return success without the iPad
/// display actually materializing — SidecarRelay or SidecarDisplayAgent ends
/// up in a half-state where it accepts the call but never delivers a session.
/// We detect this by asking CoreGraphics whether *any* non-built-in display
/// is currently active. For SidecarRescue's whole use case (MacBook with a
/// broken built-in screen using an iPad as its display), a non-built-in
/// display present means the user has a usable screen; absent means they
/// don't, regardless of what the SidecarCore API claimed.
private enum DisplayVerification {
    /// `true` if at least one currently-online display is not the laptop's
    /// built-in panel. We use the *online* list rather than the active list
    /// so a Sidecar display set to mirror the built-in panel (the SidecarRescue
    /// default for the broken-screen use case) still counts — mirrored
    /// displays show up online but not active.
    static func nonBuiltinDisplayPresent() -> Bool {
        for display in onlineDisplays() {
            if CGDisplayIsBuiltin(display) == 0 { return true }
        }
        return false
    }

    static func waitForNonBuiltinDisplay(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if nonBuiltinDisplayPresent() { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    /// Diagnostic snapshot of every display CoreGraphics knows about, so we
    /// can tell from the log why a ghost-success verdict was reached.
    static func describe() -> String {
        let displays = onlineDisplays()
        if displays.isEmpty { return "no online displays" }
        let parts = displays.map { display -> String in
            let id = display
            let builtin = CGDisplayIsBuiltin(display) != 0
            let active = CGDisplayIsActive(display) != 0
            let online = CGDisplayIsOnline(display) != 0
            let inMirror = CGDisplayIsInMirrorSet(display) != 0
            return "[id=\(id) builtin=\(builtin) active=\(active) online=\(online) mirrored=\(inMirror)]"
        }
        return parts.joined(separator: " ")
    }

    private static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else {
            return []
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else {
            return []
        }
        return displays
    }
}

private enum AgentReset {
    /// Targets the user-space Sidecar agents. We deliberately don't touch
    /// the system-level `SidecarRelay` directly via this path — launchd
    /// will restart these user agents as soon as we SIGTERM them, and that's
    /// usually enough to clear a ghost-success wedge. Returns the names of
    /// processes that were actually signalled, so the caller can log it.
    @discardableResult
    static func resetUserspaceAgents() -> [String] {
        let candidates = ["SidecarDisplayAgent", "SidecarRelay"]
        var killed: [String] = []
        for name in candidates {
            let task = Process()
            task.launchPath = "/usr/bin/pkill"
            // Use SIGTERM, not SIGKILL — let the process clean up. launchd
            // will relaunch either way; SIGTERM is gentler.
            task.arguments = ["-x", name]
            do {
                try task.run()
                task.waitUntilExit()
                if task.terminationStatus == 0 {
                    killed.append(name)
                }
            } catch {
                // pkill not present or not allowed — best-effort, swallow.
            }
        }
        return killed
    }
}

private final class SidecarClient {
    private let manager: NSObject

    init() throws {
        let framework = "/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore"
        guard dlopen(framework, RTLD_NOW) != nil else {
            throw RescueError.privateFrameworkUnavailable
        }

        guard let managerClass = NSClassFromString("SidecarDisplayManager") as? NSObject.Type else {
            throw RescueError.missingClass("SidecarDisplayManager")
        }

        let sharedManager = Selector(("sharedManager"))
        guard managerClass.responds(to: sharedManager),
              let value = managerClass.perform(sharedManager)?.takeUnretainedValue() as? NSObject else {
            throw RescueError.missingSelector("SidecarDisplayManager.sharedManager")
        }
        manager = value
    }

    func devices() throws -> [SidecarDevice] {
        let selector = Selector(("devices"))
        guard manager.responds(to: selector),
              let objects = manager.perform(selector)?.takeUnretainedValue() as? [NSObject] else {
            throw RescueError.queryFailed
        }

        return objects.compactMap { object in
            let nameSelector = Selector(("name"))
            guard object.responds(to: nameSelector),
                  let name = object.perform(nameSelector)?.takeUnretainedValue() as? String else {
                return nil
            }
            return SidecarDevice(name: name, object: object)
        }
    }

    func connect(name: String, transport: TransportMode) throws -> ConnectionResult {
        let device = try matchingDevice(named: name)
        return try connect(device: device, transport: transport)
    }

    func connect(device: SidecarDevice, transport: TransportMode) throws -> ConnectionResult {
        do {
            switch transport {
            case .automatic:
                do {
                    try connectWired(device)
                    return .connected(.wired)
                } catch RescueError.privateFrameworkError(let error)
                    where error.domain == "SidecarErrorDomain" && error.code == -100 {
                    return .alreadyActive
                } catch {
                    try connectWireless(device)
                    return .connected(.wireless)
                }
            case .wired:
                try connectWired(device)
                return .connected(.wired)
            case .wireless:
                try connectWireless(device)
                return .connected(.wireless)
            }
        } catch RescueError.privateFrameworkError(let error)
            where error.domain == "SidecarErrorDomain" && error.code == -100 {
            return .alreadyActive
        }
    }

    func attempt(_ transport: TransportMode, on device: SidecarDevice) throws -> ConnectionResult {
        do {
            switch transport {
            case .wired:
                try connectWired(device)
                return .connected(.wired)
            case .wireless:
                try connectWireless(device)
                return .connected(.wireless)
            case .automatic:
                preconditionFailure("attempt(_:on:) does not accept .automatic")
            }
        } catch RescueError.privateFrameworkError(let error)
            where error.domain == "SidecarErrorDomain" && error.code == -100 {
            return .alreadyActive
        }
    }

    func device(named name: String) throws -> SidecarDevice? {
        try devices().first { $0.name.compare(name, options: [.caseInsensitive]) == .orderedSame }
    }

    func reachability(of device: SidecarDevice) -> Reachability {
        DeviceProbe.reachability(of: device.object)
    }

    func describe(_ device: SidecarDevice) -> [String] {
        DeviceProbe.describe(device.object)
    }

    func disconnect(name: String) throws {
        let device = try matchingDevice(named: name)
        let selector = Selector(("disconnectFromDevice:completion:"))
        guard manager.responds(to: selector) else {
            throw RescueError.missingSelector("disconnectFromDevice:completion:")
        }

        try invokeAndWait { completion in
            _ = manager.perform(selector, with: device.object, with: completion)
        }
    }

    private func matchingDevice(named name: String) throws -> SidecarDevice {
        guard let device = try devices().first(where: {
            $0.name.compare(name, options: [.caseInsensitive]) == .orderedSame
        }) else {
            throw RescueError.deviceUnavailable(name)
        }
        return device
    }

    private func connectWireless(_ device: SidecarDevice) throws {
        let selector = Selector(("connectToDevice:completion:"))
        guard manager.responds(to: selector) else {
            throw RescueError.missingSelector("connectToDevice:completion:")
        }

        try invokeAndWait { completion in
            _ = manager.perform(selector, with: device.object, with: completion)
        }
    }

    private func connectWired(_ device: SidecarDevice) throws {
        guard let configClass = NSClassFromString("SidecarDisplayConfig") as? NSObject.Type else {
            throw RescueError.missingClass("SidecarDisplayConfig")
        }

        let config = configClass.init()
        let transportSelector = Selector(("setTransport:"))
        guard config.responds(to: transportSelector) else {
            throw RescueError.missingSelector("SidecarDisplayConfig.setTransport:")
        }

        typealias SetTransport = @convention(c) (AnyObject, Selector, Int64) -> Void
        let setTransport = unsafeBitCast(config.method(for: transportSelector), to: SetTransport.self)
        setTransport(config, transportSelector, 2)

        let connectSelector = Selector(("connectToDevice:withConfig:completion:"))
        guard manager.responds(to: connectSelector) else {
            throw RescueError.missingSelector("connectToDevice:withConfig:completion:")
        }

        try invokeAndWait { completion in
            typealias Connect = @convention(c) (AnyObject, Selector, AnyObject, AnyObject, AnyObject) -> Void
            let connect = unsafeBitCast(manager.method(for: connectSelector), to: Connect.self)
            connect(manager, connectSelector, device.object, config, completion as AnyObject)
        }
    }

    private func invokeAndWait(_ operation: (@escaping @convention(block) (NSError?) -> Void) -> Void) throws {
        let state = CompletionState()
        let completion: @convention(block) (NSError?) -> Void = { error in
            state.finish(with: error)
        }

        operation(completion)
        guard state.semaphore.wait(timeout: .now() + 30) == .success else {
            throw RescueError.callbackTimedOut
        }
        if let error = state.error() {
            throw RescueError.privateFrameworkError(error)
        }
    }
}

private struct Options {
    var command = ""
    var configPath: String?
    var deviceName: String?
    var interval = 1
    var timeout = 180
    var transport = TransportMode.automatic

    static func parse(_ arguments: [String]) throws -> Options {
        guard arguments.count >= 2 else {
            throw RescueError.invalidArguments(usage)
        }
        if arguments[1] == "--help" || arguments[1] == "-h" {
            throw RescueError.invalidArguments(usage)
        }

        var options = Options()
        options.command = arguments[1].lowercased()

        var index = 2
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--config", "--device", "--interval", "--timeout":
                guard index + 1 < arguments.count else {
                    throw RescueError.invalidArguments("Missing value after \(argument).\n\n\(usage)")
                }
                let value = arguments[index + 1]
                switch argument {
                case "--config":
                    options.configPath = value
                case "--device":
                    options.deviceName = value
                case "--interval":
                    guard let interval = Int(value), interval > 0 else {
                        throw RescueError.invalidArguments("--interval must be a positive integer.")
                    }
                    options.interval = interval
                case "--timeout":
                    guard let timeout = Int(value), timeout > 0 else {
                        throw RescueError.invalidArguments("--timeout must be a positive integer.")
                    }
                    options.timeout = timeout
                default:
                    break
                }
                index += 2
            case "--wired":
                options.transport = .wired
                index += 1
            case "--wireless":
                options.transport = .wireless
                index += 1
            case "--help", "-h":
                throw RescueError.invalidArguments(usage)
            default:
                throw RescueError.invalidArguments("Unknown argument: \(argument)\n\n\(usage)")
            }
        }

        return options
    }
}

private let usage = """
Usage:
  sidecar-rescue list
  sidecar-rescue inspect [--device "My iPad"]
  sidecar-rescue connect --device "My iPad" [--wired | --wireless]
  sidecar-rescue disconnect --device "My iPad"
  sidecar-rescue rescue [--device "My iPad"] [--config path] [--timeout 180] [--interval 3] [--wired | --wireless]

The rescue command retries until Sidecar connects or the timeout expires.
By default, it tries a wired Sidecar session first and falls back to wireless.
The inspect command dumps SidecarCore device class properties and selectors
so reachability detection can be tuned without AppleScript.
"""

private func configuredDeviceName(at path: String) throws -> String {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let value = try PropertyListSerialization.propertyList(from: data, format: nil)
    guard let dictionary = value as? [String: Any],
          let name = dictionary["deviceName"] as? String,
          !name.isEmpty else {
        throw RescueError.missingConfigValue("deviceName")
    }
    return name
}

private func selectedDeviceName(options: Options, client: SidecarClient) throws -> String {
    if let name = options.deviceName {
        return name
    }
    if let path = options.configPath {
        return try configuredDeviceName(at: path)
    }

    let names = try client.devices().map(\.name)
    guard names.count == 1, let onlyDevice = names.first else {
        throw RescueError.deviceNameRequired(names)
    }
    return onlyDevice
}

private func withSingleInstanceLock(named lockName: String, body: () throws -> Void) throws {
    let applicationDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/SidecarRescue")
    let lockDirectory = applicationDirectory.appendingPathComponent(lockName)
    let pidFile = lockDirectory.appendingPathComponent("pid")

    try FileManager.default.createDirectory(
        at: applicationDirectory,
        withIntermediateDirectories: true
    )

    func tryCreateLockDirectory() throws -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: lockDirectory,
                withIntermediateDirectories: false
            )
            return true
        } catch CocoaError.fileWriteFileExists {
            return false
        }
    }

    var claimed = try tryCreateLockDirectory()
    if !claimed {
        // Rapid-fire shortcut presses must not cascade-preempt each other —
        // that's how the user wound up never letting any rescue finish a
        // connect cycle. If the existing holder is still young (< 3s) the
        // new press yields and lets it run; the user gets the result of
        // the first press in the burst. After 3s, presses can preempt
        // as designed, so a stuck rescue still gets cleared.
        let holderAge = lockHolderAge(lockDirectory: lockDirectory)
        let preemptThreshold: TimeInterval = 3
        let holderAlive = lockHolderIsAlive(pidFile: pidFile)
        if holderAlive, let age = holderAge, age < preemptThreshold {
            logLine("Skipping SidecarRescue \(lockName): another rescue started \(String(format: "%.1f", age))s ago. Letting it finish.")
            return
        }
        preemptLockHolder(pidFile: pidFile, lockName: lockName)
        try? FileManager.default.removeItem(at: lockDirectory)
        claimed = try tryCreateLockDirectory()
    }
    guard claimed else {
        logLine("Failed to acquire SidecarRescue \(lockName).")
        return
    }

    try? Data("\(getpid())".utf8).write(to: pidFile)
    defer {
        try? FileManager.default.removeItem(at: lockDirectory)
    }
    try body()
}

private func lockHolderAge(lockDirectory: URL) -> TimeInterval? {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: lockDirectory.path),
          let created = attrs[.creationDate] as? Date else {
        return nil
    }
    return Date().timeIntervalSince(created)
}

private func lockHolderIsAlive(pidFile: URL) -> Bool {
    guard let raw = try? String(contentsOf: pidFile, encoding: .utf8),
          let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
          pid > 0 else {
        return false
    }
    return kill(pid, 0) == 0
}

private func preemptLockHolder(pidFile: URL, lockName: String) {
    guard let raw = try? String(contentsOf: pidFile, encoding: .utf8),
          let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
          pid > 0 else {
        return
    }
    if kill(pid, 0) != 0 {
        // Already gone; nothing to preempt.
        return
    }
    logLine("Preempting existing SidecarRescue \(lockName) (pid \(pid)).")
    // SIGTERM hands off to the in-process handler, which flips the preempt
    // flag. The target's rescue loop notices it at the next iteration
    // boundary, returns through its withSingleInstanceLock body, runs the
    // defer that removes the lock directory, and exits cleanly. We poll
    // here until the process is actually gone, so we never race with its
    // teardown or end up with overlapping lock-directory state.
    _ = kill(pid, SIGTERM)
    // Wait up to 6 seconds for the graceful exit. That covers a worst-case
    // 30s callback wait inside SidecarCore being interrupted plus a sleep
    // boundary; in practice the loop wakes within one --interval (1s).
    let gracefulDeadline = Date().addingTimeInterval(6)
    while Date() < gracefulDeadline {
        if kill(pid, 0) != 0 && errno == ESRCH {
            // Process exited; its `defer` has already removed the lock dir.
            return
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    // Holder ignored SIGTERM (stuck in an uninterruptible syscall, most
    // likely). Escalate so we don't leave a stale lock around. SIGKILL
    // skips the defer, so we'll have to clean up the lock dir ourselves
    // in the caller.
    logLine("Preempted holder did not exit within 6s; escalating to SIGKILL.")
    _ = kill(pid, SIGKILL)
    // Brief wait for the kernel to reap the PID so subsequent kill(0)
    // probes don't transiently report the zombie as alive.
    for _ in 0..<10 {
        if kill(pid, 0) != 0 && errno == ESRCH { return }
        Thread.sleep(forTimeInterval: 0.1)
    }
}

private func runRescue(options: Options, client: SidecarClient) throws {
    try withSingleInstanceLock(named: "rescue.lock") {
        let name = try selectedDeviceName(options: options, client: client)
        let deadline = Date().addingTimeInterval(TimeInterval(options.timeout))

        logLine("Starting Sidecar rescue for \(name). Timeout: \(options.timeout)s.")

        // Single up-front force-disconnect to clear any state left over —
        // healthy session, stale wedge, half-torn-down session, doesn't
        // matter. We don't try to detect which case we're in. After this
        // one call we leave SidecarCore alone and just wait for the
        // device to be reachable, then connect.
        //
        // The earlier wedge-class bugs were caused by *multiple* mutations
        // back-to-back during a teardown window. A single disconnect
        // followed by read-only polling can't race itself.
        logLine("Force-disconnect at startup to clear any leftover session state.")
        do {
            try client.disconnect(name: name)
            logLine("Force-disconnect returned cleanly.")
        } catch {
            // Errors here usually mean there was nothing to disconnect.
            // That's fine — we're about to wait for the device anyway.
            logLine("Force-disconnect returned: \(error). Continuing.")
        }
        // Give SidecarCore time to actually finish the teardown before we
        // start probing — connect calls inside the teardown window are what
        // were wedging things historically.
        Thread.sleep(forTimeInterval: 3)

        var wiredHopeless = false
        var wirelessHopeless = false
        var wirelessFailures = 0
        let wirelessFailureBudget = 1
        var consecutiveWiredFailures = 0
        let wiredFailureBudget = 3
        var attempt = 0
        var lastSkip = ""
        var agentResetUsed = false

        attemptLoop: while Date() < deadline {
            if shouldExitForPreemption() {
                logLine("Preempted by a newer rescue press. Exiting cleanly.")
                return
            }
            attempt += 1

            // Wait for the iPad to show up in the device list. This is a
            // read-only call — no alerts, no state mutations.
            guard let device = (try? client.device(named: name)) ?? nil else {
                logSkip("\(name) not yet visible", attempt: attempt, previous: &lastSkip)
                Thread.sleep(forTimeInterval: TimeInterval(options.interval))
                continue attemptLoop
            }

            // Pre-flight: only try transports whose infrastructure (Mac Wi-Fi
            // radio, USB-attached iPad) is actually present. Skipping
            // impossible transports avoids the "iPad unavailable" alert
            // SidecarRelay spawns when SidecarCore tries and fails.
            let (order, skipReasons) = transportOrder(
                requested: options.transport,
                wiredHopeless: wiredHopeless,
                wirelessHopeless: wirelessHopeless
            )
            if order.isEmpty {
                let reason = skipReasons.isEmpty ? "no candidate transports" : skipReasons.joined(separator: "; ")
                logSkip("no usable transport: \(reason)", attempt: attempt, previous: &lastSkip)
                Thread.sleep(forTimeInterval: failureBackoffInterval(
                    consecutiveFailures: consecutiveWiredFailures,
                    baseInterval: options.interval
                ))
                continue attemptLoop
            }

            var attemptFailures: [(TransportMode, String)] = []
            var sawAlreadyActive = false
            for transport in order {
                if shouldExitForPreemption() {
                    logLine("Preempted between transports. Exiting cleanly.")
                    return
                }
                if sawAlreadyActive { break }
                do {
                    switch try client.attempt(transport, on: device) {
                    case .alreadyActive:
                        // After the up-front disconnect, SidecarCore really
                        // shouldn't still say -100. If it does, just wait —
                        // teardown may not have finished yet.
                        sawAlreadyActive = true
                    case .connected(let actual):
                        logLine("Sidecar connected via \(actual.rawValue) on attempt \(attempt). Verifying display materializes…")
                        if DisplayVerification.waitForNonBuiltinDisplay(timeout: 8) {
                            logLine("Sidecar display verified. Displays: \(DisplayVerification.describe()).")
                            return
                        }
                        logLine("Display snapshot: \(DisplayVerification.describe()).")
                        // Ghost success: SidecarCore reported connected but
                        // no new display showed up within 8s. The wedged
                        // agents need a kick — but only once per rescue,
                        // and only if we haven't tried yet. After that, we
                        // give up so we're not in an infinite kill/retry
                        // loop on a system-wide issue.
                        if agentResetUsed {
                            logLine("Display still didn't appear after the agent reset. Exiting — try the shortcut again, or `sidecar-rescue disconnect` if it stays broken.")
                            return
                        }
                        let killed = AgentReset.resetUserspaceAgents()
                        logLine("Display didn't materialize (ghost success). Reset agents: \(killed.isEmpty ? "(none matched)" : killed.joined(separator: ", ")). Waiting 3s for relaunch, then retrying.")
                        agentResetUsed = true
                        Thread.sleep(forTimeInterval: 3)
                        // Reset the per-transport counters so the retry
                        // isn't tripped by stale state from this attempt.
                        consecutiveWiredFailures = 0
                        wiredHopeless = false
                        wirelessHopeless = false
                        wirelessFailures = 0
                        continue attemptLoop
                    }
                } catch {
                    let outcome = classify(error, attempting: transport)
                    switch transport {
                    case .wired:
                        consecutiveWiredFailures += 1
                        if outcome.transportHopeless || consecutiveWiredFailures >= wiredFailureBudget {
                            wiredHopeless = true
                        }
                    case .wireless:
                        wirelessFailures += 1
                        if outcome.transportHopeless || wirelessFailures >= wirelessFailureBudget {
                            wirelessHopeless = true
                        }
                    case .automatic:
                        break
                    }
                    attemptFailures.append((transport, String(describing: error)))
                }
            }

            if sawAlreadyActive {
                consecutiveWiredFailures = 0
                logSkip("SidecarCore still reports already-active — waiting", attempt: attempt, previous: &lastSkip)
                Thread.sleep(forTimeInterval: TimeInterval(options.interval))
                continue attemptLoop
            }

            if !attemptFailures.isEmpty {
                let message = attemptFailures
                    .map { "[\($0.0.rawValue)] \($0.1)" }
                    .joined(separator: " | ")
                if attempt == 1 || message != lastSkip || attempt.isMultiple(of: 10) {
                    logLine("Attempt \(attempt) failed: \(message)")
                }
                lastSkip = message
            }
            Thread.sleep(forTimeInterval: failureBackoffInterval(
                consecutiveFailures: consecutiveWiredFailures,
                baseInterval: options.interval
            ))
        }

        throw RescueError.callbackTimedOut
    }
}

/// Writes a line to stderr (line-buffered through shell `>> file` redirects,
/// so the log reflects progress even when the process is short-lived), with
/// a timestamp prefix so individual shortcut presses can be correlated to
/// the rescue runs they triggered.
private let logTimestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter
}()

private func logLine(_ message: String) {
    let stamped = "\(logTimestampFormatter.string(from: Date())) \(message)\n"
    FileHandle.standardError.write(Data(stamped.utf8))
}

/// Sleep duration between failed rescue attempts. Stays at the base interval
/// for the first few failures so a quick fix (plugging in USB-C, turning Wi-Fi
/// on) still catches; then steps up so we don't keep firing connect calls —
/// and the alerts they spawn — every second when nothing's reachable.
private func failureBackoffInterval(consecutiveFailures: Int, baseInterval: Int) -> TimeInterval {
    let base = TimeInterval(baseInterval)
    switch consecutiveFailures {
    case 0...3: return base
    case 4...6: return base * 5
    default: return base * 30
    }
}

/// Builds the ordered list of transports to attempt this cycle, filtering
/// out any that have already proven hopeless or that the runtime reachability
/// probe says aren't currently usable. Returning an empty array tells the
/// rescue loop to exit early instead of spamming SidecarCore.
/// Returns the transports to attempt this iteration plus, for diagnostics,
/// the reason each filtered transport was skipped. Filters are kept to the
/// definitive infrastructure signals (CoreWLAN for Wi-Fi radio power, IOKit
/// for whether any iPad is enumerated on USB). We deliberately do *not* use
/// the fuzzy SidecarDevice BOOL probe here — when connectivity was just
/// restored its flags lag behind reality, and that lag was causing the loop
/// to skip a transport that had genuinely come back.
private func transportOrder(
    requested: TransportMode,
    wiredHopeless: Bool,
    wirelessHopeless: Bool
) -> (order: [TransportMode], skipReasons: [String]) {
    let candidates: [TransportMode]
    switch requested {
    case .automatic: candidates = [.wired, .wireless]
    case .wired: candidates = [.wired]
    case .wireless: candidates = [.wireless]
    }
    let wiFiPowered = TransportAvailability.macWiFiPoweredOn()
    let iPadOnUSB = TransportAvailability.iPadOnUSB()

    var order: [TransportMode] = []
    var skipReasons: [String] = []
    for transport in candidates {
        switch transport {
        case .wired:
            if wiredHopeless {
                skipReasons.append("wired hopeless this run")
            } else if !iPadOnUSB {
                skipReasons.append("no iPad on USB (IOKit)")
            } else {
                order.append(.wired)
            }
        case .wireless:
            if wirelessHopeless {
                skipReasons.append("wireless hopeless this run")
            } else if !wiFiPowered {
                skipReasons.append("Mac Wi-Fi off (CoreWLAN)")
            } else {
                order.append(.wireless)
            }
        case .automatic:
            break
        }
    }
    return (order, skipReasons)
}

private func logSkip(_ message: String, attempt: Int, previous: inout String) {
    if attempt == 1 || message != previous || attempt.isMultiple(of: 10) {
        logLine("Attempt \(attempt) skipped: \(message). Waiting...")
    }
    previous = message
}

private func reachable(_ reachability: Reachability) -> String {
    var parts: [String] = []
    parts.append("wired=\(describe(reachability.wiredReachable))")
    parts.append("wireless=\(describe(reachability.wirelessReachable))")
    if let connected = reachability.isConnected {
        parts.append("connected=\(connected)")
    }
    return parts.joined(separator: ", ")
}

private func describe(_ value: Bool?) -> String {
    switch value {
    case .some(true): return "yes"
    case .some(false): return "no"
    case .none: return "unknown"
    }
}

private func requireDeviceName(_ options: Options) throws -> String {
    guard let name = options.deviceName else {
        throw RescueError.invalidArguments("--device is required for \(options.command).")
    }
    return name
}

if CommandLine.arguments.count == 2,
   CommandLine.arguments[1] == "--help" || CommandLine.arguments[1] == "-h" {
    print(usage)
    exit(0)
}

installPreemptionHandler()

do {
    let options = try Options.parse(CommandLine.arguments)
    let client = try SidecarClient()

    switch options.command {
    case "list":
        for device in try client.devices() {
            print(device.name)
        }
    case "connect":
        try withSingleInstanceLock(named: "connect.lock") {
            let name = try requireDeviceName(options)
            guard let device = try client.device(named: name) else {
                throw RescueError.deviceUnavailable(name)
            }
            let (order, skipReasons) = transportOrder(
                requested: options.transport,
                wiredHopeless: false,
                wirelessHopeless: false
            )
            if order.isEmpty {
                let reason = skipReasons.isEmpty ? "no candidate transports" : skipReasons.joined(separator: "; ")
                print("\(name) is not currently reachable: \(reason). Skipping to avoid system alerts.")
                return
            }
            switch try client.connect(device: device, transport: options.transport) {
            case .alreadyActive:
                print("A Sidecar session is already active.")
            case .connected(let transport):
                print("Sidecar connected via \(transport.rawValue).")
            }
        }
    case "disconnect":
        try client.disconnect(name: requireDeviceName(options))
        print("Sidecar disconnected.")
    case "rescue":
        try runRescue(options: options, client: client)
    case "inspect":
        let devices = try client.devices()
        if devices.isEmpty {
            print("No Sidecar devices visible.")
        }
        let target = options.deviceName?.lowercased()
        for device in devices {
            if let target, device.name.lowercased() != target { continue }
            print("Device: \(device.name)")
            for line in client.describe(device) {
                print("  " + line)
            }
            let reachability = client.reachability(of: device)
            print("  reachability: \(reachable(reachability))")
        }
    default:
        throw RescueError.invalidArguments("Unknown command: \(options.command)\n\n\(usage)")
    }
} catch {
    FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
    exit(1)
}
