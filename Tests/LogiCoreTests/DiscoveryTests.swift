import XCTest
@testable import LogiCore

private struct FakeDevice {
    var answersAt: Set<UInt8> = [0xFF]
    var changeHostIndex: UInt8? = 9
    var hostsInfoIndex: UInt8? = 10
    var hosts: [(status: UInt8, name: String)] = [(1, "Planet Express"), (1, "Nimbus"), (0, "")]
    var current: UInt8 = 1
    var failHostInfoSlot: Int?

    func exchange(_ request: Request) throws -> Inbound {
        guard answersAt.contains(request.deviceIndex) else { throw ExchangeTimeout(seconds: 1) }
        func reply(_ params: [UInt8]) -> Inbound {
            .reply(Reply(deviceIndex: request.deviceIndex, featureIndex: request.featureIndex,
                         function: request.function, softwareID: request.softwareID,
                         params: params + Array(repeating: 0, count: 16 - params.count)))
        }
        func failure(_ code: UInt8) -> Inbound {
            .error(ErrorReply(deviceIndex: request.deviceIndex, featureIndex: request.featureIndex,
                              function: request.function, softwareID: request.softwareID, code: code))
        }

        if request.featureIndex == HIDPP.rootIndex {
            if request.function == 1 { return reply([4, 5, request.params[2]]) }
            let id = UInt16(request.params[0]) << 8 | UInt16(request.params[1])
            let index = id == FeatureID.changeHost ? changeHostIndex : hostsInfoIndex
            return reply([index ?? 0, 0, 1])
        }
        if request.featureIndex == changeHostIndex { return reply([UInt8(hosts.count), current]) }
        if request.featureIndex == hostsInfoIndex {
            switch request.function {
            case 0: return reply([0x0F, 0, UInt8(hosts.count), current])
            case 1:
                let slot = Int(request.params[0])
                if slot == failHostInfoSlot { return failure(0x02) }
                let host = hosts[slot]
                return reply([UInt8(slot), host.status, 2, 0, UInt8(host.name.utf8.count), 32])
            case 3:
                let slot = Int(request.params[0])
                let offset = Int(request.params[1])
                let bytes = Array(hosts[slot].name.utf8.dropFirst(offset).prefix(14))
                return reply([UInt8(slot), UInt8(offset)] + bytes)
            default: return failure(0x07)
            }
        }
        return failure(0x06)
    }
}

final class DiscoveryTests: XCTestCase {
    func testFullDiscoveryReadsSlotsAndNames() throws {
        let report = try discoverDevice(FakeDevice().exchange)
        XCTAssertEqual(report.deviceIndex, 0xFF)
        XCTAssertEqual(report.protocolVersion, "4.5")
        XCTAssertEqual(report.hostCount, 3)
        XCTAssertEqual(report.currentHost, 1)
        XCTAssertEqual(report.changeHost.index, 9)
        XCTAssertEqual(report.slots.map { $0.name }, ["Planet Express", "Nimbus", nil])
        XCTAssertEqual(report.slots.map { $0.status }, [1, 1, 0])
        XCTAssertTrue(report.notes.isEmpty)
    }

    func testLongNameSpansChunks() throws {
        var device = FakeDevice()
        device.hosts = [(1, "Leela's MacBook Pro 16")]
        device.current = 0
        let report = try discoverDevice(device.exchange)
        XCTAssertEqual(report.slots.first?.name, "Leela's MacBook Pro 16")
    }

    func testMissingHostsInfoFallsBackToSlots() throws {
        var device = FakeDevice()
        device.hostsInfoIndex = nil
        let report = try discoverDevice(device.exchange)
        XCTAssertNil(report.hostsInfo)
        XCTAssertEqual(report.slots.count, 3)
        XCTAssertTrue(report.slots.allSatisfy { $0.name == nil })
        XCTAssertEqual(report.notes.count, 1)
    }

    func testMissingChangeHostIsAnError() {
        var device = FakeDevice()
        device.changeHostIndex = nil
        XCTAssertThrowsError(try discoverDevice(device.exchange)) {
            guard case DiscoveryError.failed = $0 else { return XCTFail("wrong error \($0)") }
        }
    }

    func testDeviceIndexIsDiscovered() throws {
        var device = FakeDevice()
        device.answersAt = [0x01]
        XCTAssertEqual(try discoverDevice(device.exchange).deviceIndex, 0x01)
    }

    func testSilentDeviceFailsWithNoAnswer() {
        var device = FakeDevice()
        device.answersAt = []
        XCTAssertThrowsError(try discoverDevice(device.exchange)) {
            guard case DiscoveryError.noAnswer = $0 else { return XCTFail("wrong error \($0)") }
        }
    }

    func testHostInfoErrorBecomesNoteAndKeepsOtherSlots() throws {
        var device = FakeDevice()
        device.failHostInfoSlot = 0
        let report = try discoverDevice(device.exchange)
        XCTAssertEqual(report.slots.map { $0.name }, [nil, "Nimbus", nil])
        XCTAssertEqual(report.notes.count, 1)
        XCTAssertTrue(report.notes[0].contains("slot 0"))
    }

    func testJSONIsSerializable() throws {
        let report = try discoverDevice(FakeDevice().exchange)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: report.json(name: "mouse")))
    }
}
