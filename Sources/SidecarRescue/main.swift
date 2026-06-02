import Darwin
import Foundation

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
    var interval = 3
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
  sidecar-rescue connect --device "My iPad" [--wired | --wireless]
  sidecar-rescue disconnect --device "My iPad"
  sidecar-rescue rescue [--device "My iPad"] [--config path] [--timeout 180] [--interval 3] [--wired | --wireless]

The rescue command retries until Sidecar connects or the timeout expires.
By default, it tries a wired Sidecar session first and falls back to wireless.
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

private func runRescue(options: Options, client: SidecarClient) throws {
    let applicationDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/SidecarRescue")
    let lockDirectory = applicationDirectory.appendingPathComponent("rescue.lock")

    try FileManager.default.createDirectory(
        at: applicationDirectory,
        withIntermediateDirectories: true
    )
    do {
        try FileManager.default.createDirectory(
            at: lockDirectory,
            withIntermediateDirectories: false
        )
    } catch CocoaError.fileWriteFileExists {
        print("Another Sidecar rescue attempt is already running.")
        return
    }
    defer {
        try? FileManager.default.removeItem(at: lockDirectory)
    }

    let name = try selectedDeviceName(options: options, client: client)
    let deadline = Date().addingTimeInterval(TimeInterval(options.timeout))
    var attempt = 0
    var lastMessage = ""

    print("Starting Sidecar rescue for \(name). Timeout: \(options.timeout)s.")
    while Date() < deadline {
        attempt += 1
        do {
            switch try client.connect(name: name, transport: options.transport) {
            case .alreadyActive:
                print("A Sidecar session is already active.")
            case .connected(let transport):
                print("Sidecar connected via \(transport.rawValue) on attempt \(attempt).")
            }
            return
        } catch {
            let message = String(describing: error)
            if attempt == 1 || message != lastMessage || attempt.isMultiple(of: 10) {
                print("Attempt \(attempt) failed: \(message)")
            }
            lastMessage = message
        }
        Thread.sleep(forTimeInterval: TimeInterval(options.interval))
    }

    throw RescueError.callbackTimedOut
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

do {
    let options = try Options.parse(CommandLine.arguments)
    let client = try SidecarClient()

    switch options.command {
    case "list":
        for device in try client.devices() {
            print(device.name)
        }
    case "connect":
        let result = try client.connect(name: requireDeviceName(options), transport: options.transport)
        switch result {
        case .alreadyActive:
            print("A Sidecar session is already active.")
        case .connected(let transport):
            print("Sidecar connected via \(transport.rawValue).")
        }
    case "disconnect":
        try client.disconnect(name: requireDeviceName(options))
        print("Sidecar disconnected.")
    case "rescue":
        try runRescue(options: options, client: client)
    default:
        throw RescueError.invalidArguments("Unknown command: \(options.command)\n\n\(usage)")
    }
} catch {
    FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
    exit(1)
}
