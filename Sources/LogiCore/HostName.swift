import Foundation

public enum HostNameError: Error, CustomStringConvertible {
    case unsupported
    case mismatch(wrote: String, read: String?)

    public var description: String {
        switch self {
        case .unsupported: return "device has no host names (feature 0x1815), nothing to rename"
        case let .mismatch(wrote, read): return "wrote host name '\(wrote)' but read back '\(read ?? "nothing")'"
        }
    }
}

// Cut at a UTF-8 boundary: the device stores bytes, and half a character reads back as garbage.
public func hostNameBytes(_ name: String, capacity: Int) -> [UInt8] {
    var bytes = Array(name.utf8.prefix(capacity))
    while !bytes.isEmpty, String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
    return bytes
}

// setHostFriendlyName (0x1815 fn 4): [slot, offset] + up to 14 bytes per request.
// Zero padding up to the old length clears the tail of a longer previous name.
public func renameRequests(deviceIndex: UInt8, featureIndex: UInt8, slot: Int, bytes: [UInt8], oldLength: Int) -> [Request] {
    let padded = bytes + Array(repeating: 0, count: max(0, oldLength - bytes.count))
    return stride(from: 0, to: max(padded.count, 1), by: 14).map { offset in
        Request(deviceIndex: deviceIndex, featureIndex: featureIndex, function: 4,
                params: [UInt8(slot), UInt8(offset)] + padded[offset..<min(offset + 14, padded.count)])
    }
}

// Returns the name written, or nil when the stored name already matches.
// Only this Mac's slot is ever written: a device accepts changes from its current host.
public func syncHostName(_ name: String, report: DeviceReport, _ exchange: Exchange) throws -> String? {
    guard let feature = report.hostsInfo,
          let mine = report.slots.first(where: { $0.slot == report.currentHost }) else { throw HostNameError.unsupported }
    let bytes = hostNameBytes(name, capacity: mine.capacity ?? 24)
    let wanted = String(decoding: bytes, as: UTF8.self)
    if mine.name == wanted { return nil }
    for request in renameRequests(deviceIndex: report.deviceIndex, featureIndex: feature.index, slot: mine.slot,
                                  bytes: bytes, oldLength: mine.length ?? 0) {
        if case let .error(error) = try exchange(request) {
            throw DiscoveryError.failed(step: "host name write", code: error.code)
        }
    }
    let read = try discoverDevice(exchange).slots.first { $0.slot == report.currentHost }?.name
    guard read == wanted else { throw HostNameError.mismatch(wrote: wanted, read: read) }
    return wanted
}
