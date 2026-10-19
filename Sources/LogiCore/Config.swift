import Foundation

public struct DeviceSpec: Codable {
    public var vid: String
    public var pid: String
    public var usagePage: String
    public var usage: String
}

public struct Timeouts: Codable {
    public var reply: TimeInterval?
    public var confirm: TimeInterval?
    public var window: TimeInterval?
}

public enum NotifyLevel: String, Codable {
    case all, failures, off
}

public struct Config: Codable {
    public var devices: [String: DeviceSpec]?
    public var hosts: [String: [String: Int]]?
    public var target: String?
    public var timeouts: Timeouts?
    public var notify: NotifyLevel?
    public var trigger: String?
    public var hostName: String?
}

public struct SwitchSettings {
    public var hosts: [String: [String: Int]]
    public var target: String?
    public var reply: TimeInterval
    public var confirm: TimeInterval
    public var window: TimeInterval
    public var notify: NotifyLevel
    public var trigger: UInt16
    // Empty turns name syncing off.
    public var hostName: String
}

public struct ResolvedDevice {
    public let vid: Int
    public let pid: Int
    public let usagePage: Int
    public let usage: Int
}

public enum ConfigError: Error, CustomStringConvertible {
    case unreadable(path: String, reason: String)
    case unknownDevice(name: String, known: [String])
    case badValue(field: String, value: String)

    public var description: String {
        switch self {
        case let .unreadable(path, reason): return "config \(path) unreadable: \(reason)"
        case let .unknownDevice(name, known): return "device '\(name)' not in config, known: \(known.sorted().joined(separator: ", "))"
        case let .badValue(field, value): return "\(field) '\(value)' is not hex, use 0x046D style"
        }
    }

    public var exit: Exit {
        switch self {
        case .unreadable: return .configUnreadable
        case .unknownDevice: return .unknownDevice
        case .badValue: return .badValue
        }
    }
}

public let builtinDevices: [String: DeviceSpec] = [
    "mouse": DeviceSpec(vid: "0x046D", pid: "0xB042", usagePage: "0xFF43", usage: "0x0202"),
    "keyboard": DeviceSpec(vid: "0x046D", pid: "0xB378", usagePage: "0xFF43", usage: "0x0202"),
]

public func configPath(env: [String: String]) -> String {
    env["LOGITECH_CONFIG"] ?? NSString(string: "~/.config/logitech-switcher/config.json").expandingTildeInPath
}

public func parseHex(_ field: String, _ value: String) throws -> Int {
    let digits = value.lowercased().hasPrefix("0x") ? String(value.dropFirst(2)) : value
    guard let n = Int(digits, radix: 16) else { throw ConfigError.badValue(field: field, value: value) }
    return n
}

func loadConfig(env: [String: String]) throws -> Config? {
    let path = configPath(env: env)
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(Config.self, from: data)
    } catch {
        throw ConfigError.unreadable(path: path, reason: "\(error)")
    }
}

func loadDevices(env: [String: String]) throws -> [String: DeviceSpec] {
    var devices = builtinDevices
    if let file = try loadConfig(env: env)?.devices {
        devices.merge(file) { _, file in file }
    }
    return devices
}

public func switchSettings(env: [String: String] = ProcessInfo.processInfo.environment) throws -> SwitchSettings {
    let config = try loadConfig(env: env)
    let trigger = try config?.trigger.map { UInt16(truncatingIfNeeded: try parseHex("trigger", $0)) } ?? defaultTrigger
    return SwitchSettings(
        hosts: config?.hosts ?? [:],
        target: config?.target,
        reply: config?.timeouts?.reply ?? 1.0,
        confirm: config?.timeouts?.confirm ?? 8.0,
        window: config?.timeouts?.window ?? 20.0,
        notify: config?.notify ?? .all,
        trigger: trigger,
        hostName: config?.hostName ?? Host.current().localizedName ?? "")
}

public func deviceNames(env: [String: String] = ProcessInfo.processInfo.environment) throws -> [String] {
    try loadDevices(env: env).keys.sorted()
}

public func resolveDevice(_ name: String, env: [String: String] = ProcessInfo.processInfo.environment) throws -> ResolvedDevice {
    let devices = try loadDevices(env: env)
    guard var spec = devices[name] else {
        throw ConfigError.unknownDevice(name: name, known: Array(devices.keys))
    }
    spec.vid = env["LOGITECH_VID"] ?? spec.vid
    spec.pid = env["LOGITECH_PID"] ?? spec.pid
    spec.usagePage = env["LOGITECH_USAGE_PAGE"] ?? spec.usagePage
    spec.usage = env["LOGITECH_USAGE"] ?? spec.usage
    return ResolvedDevice(
        vid: try parseHex("vid", spec.vid),
        pid: try parseHex("pid", spec.pid),
        usagePage: try parseHex("usagePage", spec.usagePage),
        usage: try parseHex("usage", spec.usage)
    )
}
