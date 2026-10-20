import Foundation

public enum Target: Equatable {
    case slot(Int)
    case alias(String, [String: Int])
    case name(String)
    case next

    public init(_ arg: String?, hosts: [String: [String: Int]]) {
        guard let arg else {
            self = .next
            return
        }
        if let slot = Int(arg) {
            self = .slot(slot)
        } else if let slots = hosts[arg] {
            self = .alias(arg, slots)
        } else if arg == "next" {
            self = .next
        } else {
            self = .name(arg)
        }
    }
}

public enum SwitchError: Error, Equatable, CustomStringConvertible {
    case unknownHost(query: String, known: [String])
    case ambiguousHost(query: String, matches: [String])
    case noSlot(alias: String)
    case outOfRange(slot: Int, count: Int)
    case unpaired(slot: Int)
    case slotsDisagree(current: [Int])
    case noNextHost

    public var description: String {
        switch self {
        case let .unknownHost(query, known):
            return "no paired host named '\(query)', known: \(known.joined(separator: ", "))"
        case let .ambiguousHost(query, matches):
            return "'\(query)' matches \(matches.joined(separator: ", ")), use a slot number or a hosts alias"
        case let .noSlot(alias):
            return "hosts alias '\(alias)' has no slot for this device in config"
        case let .outOfRange(slot, count):
            return "slot \(slot) out of range, device has \(count)"
        case let .unpaired(slot):
            return "slot \(slot) is not paired, pair it with the Easy-Switch key first"
        case let .slotsDisagree(current):
            return "devices put this Mac on different slots (\(current.map(String.init).joined(separator: ", "))), pair each Mac on the same Easy-Switch number on every device"
        case .noNextHost:
            return "no other slot is paired on every device, pair another Mac or pass a slot"
        }
    }

    public var exit: Exit {
        switch self {
        case .unknownHost, .ambiguousHost, .noSlot, .outOfRange, .slotsDisagree, .noNextHost: return .unknownHost
        case .unpaired: return .unpaired
        }
    }
}

public struct Leg: Equatable {
    public var deviceIndex: UInt8
    public var changeHost: Feature
    public var current: Int
    public var slot: Int
    public var hostName: String?
}

public extension Request {
    static func setHost(_ leg: Leg) -> Request {
        Request(deviceIndex: leg.deviceIndex, featureIndex: leg.changeHost.index, function: 1, params: [UInt8(leg.slot)])
    }
}

func fold(_ name: String) -> String {
    name.replacingOccurrences(of: "\u{2019}", with: "'").lowercased()
}

// Devices cut host names at 24 bytes, so a query may be longer than the stored name.
public func matchHost(_ query: String, in slots: [HostSlot]) -> [HostSlot] {
    let q = fold(query)
    let named = slots.compactMap { slot -> (slot: HostSlot, name: String)? in
        guard slot.status != 0, let name = slot.name else { return nil }
        return (slot, fold(name))
    }
    let exact = named.filter { $0.name == q }
    if !exact.isEmpty { return exact.map(\.slot) }
    let truncated = named.filter { q.hasPrefix($0.name) }
    if let longest = truncated.map(\.name.count).max() {
        return truncated.filter { $0.name.count == longest }.map(\.slot)
    }
    return named.filter { $0.name.hasPrefix(q) }.map(\.slot)
}

// Cycles 0-1-2-0 through slots paired on every device. Assumes Easy-Switch
// numbering matches across devices: slot n is the same Mac on each.
public func nextSlot(_ reports: [DeviceReport]) throws -> Int {
    let currents = reports.map(\.currentHost)
    guard let current = currents.first, currents.allSatisfy({ $0 == current }) else {
        throw SwitchError.slotsDisagree(current: currents)
    }
    let count = reports.map(\.hostCount).min() ?? 0
    for step in 1..<max(count, 1) {
        let slot = (current + step) % count
        if reports.allSatisfy({ report in report.slots.first { $0.slot == slot }?.status != 0 }) { return slot }
    }
    throw SwitchError.noNextHost
}

public func plan(_ target: Target, device: String, _ exchange: Exchange) throws -> Leg {
    let report = try discoverDevice(exchange)
    return try plan(target == .next ? .slot(try nextSlot([report])) : target, device: device, report: report)
}

public func plan(_ target: Target, device: String, report: DeviceReport) throws -> Leg {
    let slot: Int
    switch target {
    case let .slot(n):
        slot = n
    case let .alias(alias, slots):
        guard let n = slots[device] else { throw SwitchError.noSlot(alias: alias) }
        slot = n
    case let .name(query):
        let matches = matchHost(query, in: report.slots)
        guard matches.count == 1 else {
            let label = { (s: HostSlot) in "\(s.slot) '\(s.name ?? "")'" }
            if matches.isEmpty {
                throw SwitchError.unknownHost(query: query, known: report.slots.filter { $0.status != 0 && $0.name != nil }.map(label))
            }
            throw SwitchError.ambiguousHost(query: query, matches: matches.map(label))
        }
        slot = matches[0].slot
    case .next:
        return try plan(.slot(try nextSlot([report])), device: device, report: report)
    }
    guard (0..<report.hostCount).contains(slot) else {
        throw SwitchError.outOfRange(slot: slot, count: report.hostCount)
    }
    let entry = report.slots.first { $0.slot == slot }
    if slot != report.currentHost, entry?.status == 0 { throw SwitchError.unpaired(slot: slot) }
    return Leg(deviceIndex: report.deviceIndex, changeHost: report.changeHost,
               current: report.currentHost, slot: slot, hostName: entry?.name)
}

public struct Clock {
    public var now: () -> Date
    public var sleep: (TimeInterval) -> Void

    public init(now: @escaping () -> Date, sleep: @escaping (TimeInterval) -> Void) {
        self.now = now
        self.sleep = sleep
    }

    // Wall time on purpose: the monotonic clock pauses across system sleep, hiding the gap.
    public static let wall = Clock(now: { Date() }, sleep: { Thread.sleep(forTimeInterval: $0) })
}

public struct Backoff {
    public var delays: [TimeInterval]
    public var budget: TimeInterval
    public var sleepGap: TimeInterval
    public var window: TimeInterval

    public init(delays: [TimeInterval] = [0.1, 0.25, 0.5, 1, 2], budget: TimeInterval = 8, sleepGap: TimeInterval = 5, window: TimeInterval = 20) {
        self.delays = delays
        self.budget = budget
        self.sleepGap = sleepGap
        self.window = window
    }
}

public struct Push {
    public var device: String
    public var leg: Leg
    public var exchange: Exchange
    public var isPresent: () -> Bool

    public init(device: String, leg: Leg, exchange: @escaping Exchange, isPresent: @escaping () -> Bool) {
        self.device = device
        self.leg = leg
        self.exchange = exchange
        self.isPresent = isPresent
    }
}

public enum Outcome: Equatable {
    case moved(after: TimeInterval)
    case already
    case stayed(after: TimeInterval)
    case refused(code: UInt8)
    case slept(seconds: TimeInterval)
    case late(after: TimeInterval)
    case skipped

    var succeeded: Bool {
        switch self {
        case .moved, .already: return true
        default: return false
        }
    }
}

public func switchOrder(_ names: [String]) -> [String] {
    names.filter { $0 == "mouse" } + names.filter { $0 != "mouse" }
}

// Later devices only move once every earlier one is confirmed gone, so a mouse
// that will not leave keeps the keyboard here with it. Nothing is sent once
// `window` seconds have passed since `started`: a switch must never land long
// after it was asked for, e.g. when the Mac wakes from sleep mid-run.
public func run(_ pushes: [Push], started: Date, clock: Clock = .wall, backoff: Backoff = Backoff()) -> [Outcome] {
    var outcomes: [Outcome] = []
    for push in pushes {
        outcomes.append(outcomes.allSatisfy(\.succeeded) ? move(push, started, clock, backoff) : .skipped)
    }
    return outcomes
}

func move(_ push: Push, _ started: Date, _ clock: Clock, _ backoff: Backoff) -> Outcome {
    if push.leg.current == push.leg.slot { return .already }
    let since = clock.now().timeIntervalSince(started)
    if since > backoff.window { return .late(after: since) }

    // No reply is normal: the link usually drops before the device answers. Absence decides.
    if case let .error(error)? = try? push.exchange(.setHost(push.leg)) {
        return .refused(code: error.code)
    }

    let start = clock.now()
    var last = start
    for step in 0... {
        let delay = backoff.delays[min(step, backoff.delays.count - 1)]
        clock.sleep(delay)
        let now = clock.now()
        if now.timeIntervalSince(last) - delay > backoff.sleepGap {
            return .slept(seconds: now.timeIntervalSince(last))
        }
        last = now
        let elapsed = now.timeIntervalSince(start)
        if !push.isPresent() { return .moved(after: elapsed) }
        if elapsed >= backoff.budget { return .stayed(after: elapsed) }
    }
    fatalError("unreachable")
}

public func verdict(_ names: [String], _ outcomes: [Outcome]) -> (Exit, String) {
    guard let failed = outcomes.firstIndex(where: { !$0.succeeded }) else { return (.ok, "switched") }
    let name = names[failed]
    let moved = zip(names, outcomes).prefix(failed).filter { if case .moved = $0.1 { return true }; return false }.map(\.0)
    let left = names.suffix(from: failed + 1)

    var code: Exit
    var reason: String
    switch outcomes[failed] {
    case let .stayed(after):
        code = .stayed
        reason = "\(name) still here after \(String(format: "%.1f", after))s"
    case let .refused(error):
        code = .deviceError
        reason = "\(name) refused change host: \(HIDPP.errorName(error))"
    case let .slept(seconds):
        code = .slept
        reason = "Mac slept \(Int(seconds))s while moving \(name), check where it is"
    case let .late(after):
        code = .slept
        reason = "\(name) not sent, \(Int(after))s since the switch was asked for"
    default:
        code = .deviceError
        reason = "\(name): \(outcomes[failed])"
    }
    if !left.isEmpty { reason += ", \(left.joined(separator: " and ")) left here" }
    if !moved.isEmpty {
        code = .stranded
        reason = "\(moved.joined(separator: " and ")) moved but \(reason), use the Easy-Switch keys to recover"
    }
    return (code, reason)
}

public func switchedMessage(_ pushes: [Push], _ outcomes: [Outcome]) -> String {
    let host = pushes.lazy.compactMap(\.leg.hostName).first.map { $0.trimmingCharacters(in: .whitespaces) }
        ?? pushes.first.map { "slot \($0.leg.slot)" } ?? "target"
    let moved = zip(pushes, outcomes).filter { if case .moved = $0.1 { return true }; return false }.map(\.0.device)
    if moved.isEmpty { return "Already on \(host)" }
    let devices = moved.joined(separator: " and ")
    return "\(devices.prefix(1).uppercased() + devices.dropFirst()) moved to \(host)"
}

public func retrying<T>(_ delays: [TimeInterval], sleep: (TimeInterval) -> Void, when shouldRetry: (Error) -> Bool, _ body: () throws -> T) throws -> T {
    for delay in delays {
        do {
            return try body()
        } catch let error where shouldRetry(error) {
            sleep(delay)
        }
    }
    return try body()
}
