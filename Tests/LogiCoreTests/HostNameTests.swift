import XCTest
@testable import LogiCore

final class HostNameTests: XCTestCase {
    func testCutKeepsWholeCharacters() {
        // ’ is 3 bytes; a 24-byte cut through it must drop it entirely.
        XCTAssertEqual(String(decoding: hostNameBytes("Leela\u{2019}s MacBook Pro (2)", capacity: 24), as: UTF8.self),
                       "Leela\u{2019}s MacBook Pro (2")
        XCTAssertEqual(hostNameBytes("abcdefghijklmnopqrstuvw\u{2019}", capacity: 24).count, 23)
        XCTAssertEqual(hostNameBytes("Planet Express", capacity: 24).count, 14)
    }

    func testRenameChunksAndPadsOverOldTail() {
        let requests = renameRequests(deviceIndex: 0xFF, featureIndex: 0x0B, slot: 1,
                                      bytes: Array("Planet Express".utf8), oldLength: 24)
        XCTAssertEqual(requests.map(\.function), [4, 4])
        XCTAssertEqual(requests[0].params.prefix(2), [1, 0])
        XCTAssertEqual(requests[1].params.prefix(2), [1, 14])
        XCTAssertEqual(requests.flatMap { $0.params.dropFirst(2) }, Array("Planet Express".utf8) + Array(repeating: 0, count: 10))
        XCTAssertTrue(requests.allSatisfy { $0.params.count <= HIDPP.maxParams })
    }

    func testMatchingNameWritesNothing() throws {
        let report = DeviceReport(
            deviceIndex: 0xFF, protocolVersion: "4.5", changeHost: Feature(index: 10, type: 0, version: 1),
            hostCount: 2, currentHost: 1, changeHostRaw: "", hostsInfo: Feature(index: 11, type: 0, version: 2),
            capabilitiesRaw: nil,
            slots: [HostSlot(slot: 0, status: 1, bus: 4, name: "Other", raw: [:]),
                    HostSlot(slot: 1, status: 1, bus: 4, name: "Planet Express", raw: [:], length: 14, capacity: 24)],
            notes: [])
        XCTAssertNil(try syncHostName("Planet Express", report: report) { _ in
            XCTFail("no request expected")
            throw ExchangeTimeout(seconds: 0)
        })
    }
}
