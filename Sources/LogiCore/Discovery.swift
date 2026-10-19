import Foundation

public struct ExchangeTimeout: Error, CustomStringConvertible {
    public let seconds: TimeInterval
    public init(seconds: TimeInterval) { self.seconds = seconds }
    public var description: String { "no reply within \(seconds)s" }
}

public enum DiscoveryError: Error, CustomStringConvertible {
    case noAnswer
    case failed(step: String, code: UInt8)

    public var description: String {
        switch self {
        case .noAnswer:
            return "device did not answer on indexes \(HIDPP.deviceIndexCandidates.map { String(format: "0x%02X", $0) }.joined(separator: ", ")), wake it and retry"
        case let .failed(step, code):
            return "\(step) failed: \(HIDPP.errorName(code))"
        }
    }

    public var exit: Exit {
        switch self {
        case .noAnswer: return .timeout
        case .failed: return .deviceError
        }
    }
}

public typealias Exchange = (Request) throws -> Inbound

public enum FeatureID {
    public static let changeHost: UInt16 = 0x1814
    public static let hostsInfo: UInt16 = 0x1815
}

public struct Feature: Equatable {
    public let index: UInt8
    public let type: UInt8
    public let version: UInt8
}

public extension Request {
    static func getFeature(deviceIndex: UInt8, id: UInt16) -> Request {
        Request(deviceIndex: deviceIndex, featureIndex: HIDPP.rootIndex, function: 0, params: [UInt8(id >> 8), UInt8(id & 0xFF)])
    }
}

public struct HostSlot: Equatable {
    public var slot: Int
    public var status: UInt8?
    public var bus: UInt8?
    public var name: String?
    public var raw: [String: String]
    public var length: Int? = nil
    public var capacity: Int? = nil
}

public struct DeviceReport: Equatable {
    public var deviceIndex: UInt8
    public var protocolVersion: String
    public var changeHost: Feature
    public var hostCount: Int
    public var currentHost: Int
    public var changeHostRaw: String
    public var hostsInfo: Feature?
    public var capabilitiesRaw: String?
    public var slots: [HostSlot]
    public var notes: [String]

    public func json(name: String) -> [String: Any] {
        func feature(_ f: Feature?) -> Any {
            guard let f else { return NSNull() }
            return ["index": Int(f.index), "type": Int(f.type), "version": Int(f.version)]
        }
        return [
            "device": name,
            "deviceIndex": String(format: "0x%02X", deviceIndex),
            "protocol": protocolVersion,
            "changeHost": ["feature": feature(changeHost), "count": hostCount, "current": currentHost, "raw": changeHostRaw],
            "hostsInfo": [
                "feature": feature(hostsInfo),
                "capabilitiesRaw": capabilitiesRaw as Any,
                "slots": slots.map { slot in
                    [
                        "slot": slot.slot,
                        "status": slot.status.map { Int($0) } as Any,
                        "paired": slot.status.map { $0 != 0 } as Any,
                        "bus": slot.bus.map { Int($0) } as Any,
                        "name": slot.name as Any,
                        "raw": slot.raw,
                    ] as [String: Any]
                },
            ],
            "notes": notes,
        ]
    }
}

enum Probe {
    case reply([UInt8])
    case error(UInt8)
    case timeout
}

func probe(_ request: Request, _ exchange: Exchange) throws -> Probe {
    do {
        switch try exchange(request) {
        case let .reply(reply): return .reply(reply.params)
        case let .error(error): return .error(error.code)
        }
    } catch is ExchangeTimeout {
        return .timeout
    }
}

public func findDeviceIndex(_ exchange: Exchange) throws -> (index: UInt8, answer: Inbound)? {
    for index in HIDPP.deviceIndexCandidates {
        do {
            return (index, try exchange(.ping(deviceIndex: index, data: 0xA5)))
        } catch is ExchangeTimeout {
            continue
        }
    }
    return nil
}

func lookup(_ id: UInt16, _ index: UInt8, _ exchange: Exchange) throws -> Feature? {
    guard case let .reply(reply) = try exchange(.getFeature(deviceIndex: index, id: id)),
          reply.params.count >= 3, reply.params[0] != 0 else { return nil }
    return Feature(index: reply.params[0], type: reply.params[1], version: reply.params[2])
}

func required(_ step: String, _ request: Request, _ exchange: Exchange) throws -> [UInt8] {
    switch try exchange(request) {
    case let .reply(reply): return reply.params
    case let .error(error): throw DiscoveryError.failed(step: step, code: error.code)
    }
}

func readName(slot: Int, length: Int, feature: Feature, index: UInt8, _ exchange: Exchange) throws -> (String?, String) {
    var bytes: [UInt8] = []
    var raws: [String] = []
    var offset = 0
    while offset < max(length, 1), offset < 64 {
        let request = Request(deviceIndex: index, featureIndex: feature.index, function: 3, params: [UInt8(slot), UInt8(offset)])
        guard case let .reply(p) = try probe(request, exchange) else { break }
        raws.append(hexString(p))
        let chunk = Array(p.dropFirst(2))
        let text = chunk.prefix { $0 != 0 }
        bytes += text
        if text.count < chunk.count || chunk.isEmpty { break }
        offset += chunk.count
    }
    let name = bytes.isEmpty ? nil : String(decoding: bytes.prefix(length > 0 ? length : bytes.count), as: UTF8.self)
    return (name, raws.joined(separator: ","))
}

public func discoverDevice(_ exchange: Exchange) throws -> DeviceReport {
    guard let found = try findDeviceIndex(exchange) else { throw DiscoveryError.noAnswer }
    let index = found.index
    var notes: [String] = []

    var version = "unknown"
    if case let .reply(reply) = found.answer, let pong = Pong(reply) { version = "\(pong.major).\(pong.minor)" }

    guard let change = try lookup(FeatureID.changeHost, index, exchange) else {
        throw DiscoveryError.failed(step: "feature 0x1814 (change host) lookup", code: 0x09)
    }
    let info = try required("change host info", Request(deviceIndex: index, featureIndex: change.index, function: 0), exchange)
    guard info.count >= 2 else { throw DiscoveryError.failed(step: "change host info", code: 0x01) }
    let count = Int(info[0])
    let current = Int(info[1])

    var report = DeviceReport(
        deviceIndex: index, protocolVersion: version, changeHost: change,
        hostCount: count, currentHost: current, changeHostRaw: hexString(info),
        hostsInfo: nil, capabilitiesRaw: nil, slots: [], notes: notes)

    guard let hosts = try lookup(FeatureID.hostsInfo, index, exchange) else {
        notes.append("feature 0x1815 (hosts info) absent: no host names, use slot numbers")
        report.slots = (0..<count).map { HostSlot(slot: $0, status: nil, bus: nil, name: nil, raw: [:]) }
        report.notes = notes
        return report
    }
    report.hostsInfo = hosts

    if case let .reply(p) = try probe(Request(deviceIndex: index, featureIndex: hosts.index, function: 0), exchange) {
        report.capabilitiesRaw = hexString(p)
    }

    for slot in 0..<count {
        var entry = HostSlot(slot: slot, status: nil, bus: nil, name: nil, raw: [:])
        switch try probe(Request(deviceIndex: index, featureIndex: hosts.index, function: 1, params: [UInt8(slot)]), exchange) {
        case let .reply(p) where p.count >= 5:
            entry.raw["info"] = hexString(p)
            entry.status = p[1]
            entry.bus = p[2]
            let length = Int(p[4])
            entry.length = length
            entry.capacity = p.count > 5 ? Int(p[5]) : nil
            if length > 0 {
                let (name, raw) = try readName(slot: slot, length: length, feature: hosts, index: index, exchange)
                entry.name = name
                entry.raw["name"] = raw
            }
        case let .reply(p):
            entry.raw["info"] = hexString(p)
            notes.append("slot \(slot): host info reply too short")
        case let .error(code):
            notes.append("slot \(slot): host info \(HIDPP.errorName(code))")
        case .timeout:
            notes.append("slot \(slot): host info timed out")
        }
        report.slots.append(entry)
    }
    report.notes = notes
    return report
}
