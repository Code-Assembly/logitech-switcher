import Foundation

public extension FeatureID {
    static let reprogControls: UInt16 = 0x1B04
}

public let hostSwitchControls: [UInt16: String] = [0x00D1: "Easy-Switch 1", 0x00D2: "Easy-Switch 2", 0x00D3: "Easy-Switch 3"]

public struct Control: Equatable {
    public var cid: UInt16
    public var tid: UInt16
    public var flags: UInt8
    public var position: UInt8
    public var group: UInt8
    public var groupMask: UInt8
    public var extra: UInt8
    public var raw: String

    init?(_ p: [UInt8]) {
        guard p.count >= 9 else { return nil }
        cid = UInt16(p[0]) << 8 | UInt16(p[1])
        tid = UInt16(p[2]) << 8 | UInt16(p[3])
        flags = p[4]
        position = p[5]
        group = p[6]
        groupMask = p[7]
        extra = p[8]
        raw = hexString(Array(p.prefix(9)))
    }

    public var traits: [String] {
        let named: [(UInt8, UInt8, String)] = [
            (flags, 0x01, "mouse"), (flags, 0x02, "fkey"), (flags, 0x04, "hotkey"), (flags, 0x08, "fnToggle"),
            (flags, 0x10, "reprogHint"), (flags, 0x20, "divertable"), (flags, 0x40, "persistDivertable"),
            (flags, 0x80, "virtual"), (extra, 0x01, "rawXY"), (extra, 0x02, "forceRawXY"),
            (extra, 0x04, "analyticsKeyEvents"), (extra, 0x08, "rawWheel"),
        ]
        return named.filter { $0.0 & $0.1 != 0 }.map(\.2)
    }

    public var json: [String: Any] {
        [
            "cid": String(format: "0x%04X", cid), "tid": String(format: "0x%04X", tid),
            "name": hostSwitchControls[cid] as Any, "traits": traits, "raw": raw,
        ]
    }
}

// Read only: getCount and getCidInfo. Never sends setCidReporting.
public func readControls(_ exchange: Exchange) throws -> (feature: Feature?, controls: [Control]) {
    guard let found = try findDeviceIndex(exchange) else { throw DiscoveryError.noAnswer }
    guard let feature = try lookup(FeatureID.reprogControls, found.index, exchange) else { return (nil, []) }
    let count = try required("controls count", Request(deviceIndex: found.index, featureIndex: feature.index, function: 0), exchange)
    var controls: [Control] = []
    for i in 0..<Int(count.first ?? 0) {
        let info = try required("control \(i) info", Request(deviceIndex: found.index, featureIndex: feature.index, function: 1, params: [UInt8(i)]), exchange)
        if let control = Control(info) { controls.append(control) }
    }
    return (feature, controls)
}

public extension Request {
    // setCidReporting with every divert/persist/rawXY valid bit clear and remap 0,
    // so only the analytics bit changes. Easy-Switch keys keep switching.
    static func setAnalytics(deviceIndex: UInt8, featureIndex: UInt8, cid: UInt16, on: Bool) -> Request {
        Request(deviceIndex: deviceIndex, featureIndex: featureIndex, function: 3,
                params: [UInt8(cid >> 8), UInt8(cid & 0xFF), 0x00, 0x00, 0x00, on ? 0x03 : 0x02])
    }
}

public func controlLabel(_ cid: UInt16) -> String {
    hostSwitchControls[cid].map { "\($0) (0x\(String(format: "%04X", cid)))" } ?? String(format: "0x%04X", cid)
}

// Turns analytics reporting on or off for every control that supports it.
public func setAnalytics(_ on: Bool, _ exchange: Exchange) throws -> (featureIndex: UInt8?, lines: [String]) {
    let (feature, controls) = try readControls(exchange)
    guard let feature, let found = try findDeviceIndex(exchange) else { return (nil, ["feature 0x1B04 absent"]) }
    let lines = try controls.filter { $0.extra & 0x04 != 0 }.map { control in
        let request = Request.setAnalytics(deviceIndex: found.index, featureIndex: feature.index, cid: control.cid, on: on)
        switch try exchange(request) {
        case .reply: return "\(controlLabel(control.cid)) analytics \(on ? "on" : "off")"
        case let .error(error): return "\(controlLabel(control.cid)) analytics refused: \(HIDPP.errorName(error.code))"
        }
    }
    return (feature.index, lines)
}

// Analytics events carry (cid, event) triples; trailing zero triples are padding.
public func analyticsEvents(_ params: [UInt8]) -> [(cid: UInt16, event: UInt8)] {
    stride(from: 0, to: params.count - 2, by: 3).compactMap { i in
        let cid = UInt16(params[i]) << 8 | UInt16(params[i + 1])
        return cid == 0 ? nil : (cid, params[i + 2])
    }
}

// Scroll Lock on the MX Keys S. It sends no key report on a Mac, only analytics.
public let defaultTrigger: UInt16 = 0x00EA

public func armTrigger(_ cid: UInt16, _ exchange: Exchange) throws -> UInt8 {
    guard let found = try findDeviceIndex(exchange) else { throw DiscoveryError.noAnswer }
    guard let feature = try lookup(FeatureID.reprogControls, found.index, exchange) else {
        throw DiscoveryError.failed(step: "feature 0x1B04 (reprogrammable controls) lookup", code: 0x09)
    }
    let request = Request.setAnalytics(deviceIndex: found.index, featureIndex: feature.index, cid: cid, on: true)
    if case let .error(error) = try exchange(request) {
        throw DiscoveryError.failed(step: "analytics on for control \(controlLabel(cid))", code: error.code)
    }
    return feature.index
}

// Analytics notifications arrive as function 2 with software ID 0; event 1 is key down.
public func isPress(_ bytes: [UInt8], featureIndex: UInt8, cid: UInt16) -> Bool {
    guard bytes.count > 4, bytes[0] == HIDPP.reportID, bytes[2] == featureIndex, bytes[3] == 0x20 else { return false }
    return analyticsEvents(Array(bytes[4...])).contains { $0.cid == cid && $0.event == 1 }
}
