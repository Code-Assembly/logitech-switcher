import Foundation

public enum HIDPP {
    public static let reportID: UInt8 = 0x11
    public static let reportLength = 20
    public static let maxParams = 16
    public static let errorFeature: UInt8 = 0xFF
    public static let rootIndex: UInt8 = 0x00
    public static let softwareID: UInt8 = 0x05
    public static let deviceIndexCandidates: [UInt8] = [0xFF, 0x00, 0x01]

    public static func normalize(reportID: UInt32, bytes: [UInt8]) -> [UInt8] {
        guard reportID != 0, bytes.count == reportLength - 1 else { return bytes }
        return [UInt8(truncatingIfNeeded: reportID)] + bytes
    }

    public static func errorName(_ code: UInt8) -> String {
        switch code {
        case 0x01: return "unknown"
        case 0x02: return "invalid argument"
        case 0x03: return "out of range"
        case 0x04: return "hardware error"
        case 0x05: return "logitech internal"
        case 0x06: return "invalid feature index"
        case 0x07: return "invalid function id"
        case 0x08: return "busy"
        case 0x09: return "unsupported"
        default: return "code \(code)"
        }
    }
}

public struct Request: Equatable {
    public var deviceIndex: UInt8
    public var featureIndex: UInt8
    public var function: UInt8
    public var softwareID: UInt8
    public var params: [UInt8]

    public init(deviceIndex: UInt8, featureIndex: UInt8, function: UInt8, softwareID: UInt8 = HIDPP.softwareID, params: [UInt8] = []) {
        self.deviceIndex = deviceIndex
        self.featureIndex = featureIndex
        self.function = function
        self.softwareID = softwareID
        self.params = params
    }

    public var header: UInt8 { ((function & 0x0F) << 4) | (softwareID & 0x0F) }

    public func encode() -> [UInt8] {
        var out = [HIDPP.reportID, deviceIndex, featureIndex, header] + params.prefix(HIDPP.maxParams)
        out += repeatElement(0, count: HIDPP.reportLength - out.count)
        return out
    }

    public static func ping(deviceIndex: UInt8, data: UInt8) -> Request {
        Request(deviceIndex: deviceIndex, featureIndex: HIDPP.rootIndex, function: 1, params: [0, 0, data])
    }
}

public struct Reply: Equatable {
    public var deviceIndex: UInt8
    public var featureIndex: UInt8
    public var function: UInt8
    public var softwareID: UInt8
    public var params: [UInt8]
}

public struct ErrorReply: Equatable {
    public var deviceIndex: UInt8
    public var featureIndex: UInt8
    public var function: UInt8
    public var softwareID: UInt8
    public var code: UInt8
}

public enum DecodeError: Error, Equatable {
    case length(Int)
    case reportID(UInt8)
}

public enum Inbound: Equatable {
    case reply(Reply)
    case error(ErrorReply)

    public static func decode(_ bytes: [UInt8]) -> Result<Inbound, DecodeError> {
        guard bytes.count == HIDPP.reportLength else { return .failure(.length(bytes.count)) }
        guard bytes[0] == HIDPP.reportID else { return .failure(.reportID(bytes[0])) }
        if bytes[2] == HIDPP.errorFeature {
            return .success(.error(ErrorReply(
                deviceIndex: bytes[1], featureIndex: bytes[3],
                function: bytes[4] >> 4, softwareID: bytes[4] & 0x0F, code: bytes[5])))
        }
        return .success(.reply(Reply(
            deviceIndex: bytes[1], featureIndex: bytes[2],
            function: bytes[3] >> 4, softwareID: bytes[3] & 0x0F, params: Array(bytes[4...]))))
    }

    public func answers(_ request: Request) -> Bool {
        switch self {
        case let .reply(r):
            return r.featureIndex == request.featureIndex && r.function == request.function && r.softwareID == request.softwareID
        case let .error(e):
            return e.featureIndex == request.featureIndex && e.function == request.function && e.softwareID == request.softwareID
        }
    }
}

public struct Pong: Equatable {
    public var major: UInt8
    public var minor: UInt8
    public var echo: UInt8

    public init?(_ reply: Reply) {
        guard reply.params.count >= 3 else { return nil }
        major = reply.params[0]
        minor = reply.params[1]
        echo = reply.params[2]
    }
}
