import XCTest
@testable import LogiCore

final class HIDPPTests: XCTestCase {
    func testPingEncodesLongReport() {
        let bytes = Request.ping(deviceIndex: 0xFF, data: 0xA5).encode()
        XCTAssertEqual(bytes.count, 20)
        XCTAssertEqual(Array(bytes.prefix(7)), [0x11, 0xFF, 0x00, 0x15, 0x00, 0x00, 0xA5])
        XCTAssertTrue(bytes.dropFirst(7).allSatisfy { $0 == 0 })
    }

    func testFunctionAndSoftwareIDShareByteThree() {
        let request = Request(deviceIndex: 0xFF, featureIndex: 0x09, function: 0x0B, softwareID: 0x03)
        XCTAssertEqual(request.encode()[3], 0xB3)
    }

    func testOversizedParamsAreTruncated() {
        let request = Request(deviceIndex: 0xFF, featureIndex: 0, function: 0, params: Array(repeating: 1, count: 30))
        XCTAssertEqual(request.encode().count, 20)
    }

    func testDecodesPongReply() throws {
        let raw: [UInt8] = [0x11, 0xFF, 0x00, 0x15, 0x04, 0x02, 0xA5] + Array(repeating: 0, count: 13)
        guard case let .success(.reply(reply)) = Inbound.decode(raw) else { return XCTFail("not a reply") }
        XCTAssertEqual(reply.softwareID, 5)
        XCTAssertEqual(reply.function, 1)
        let pong = try XCTUnwrap(Pong(reply))
        XCTAssertEqual([pong.major, pong.minor, pong.echo], [4, 2, 0xA5])
    }

    func testDecodesErrorReply() {
        let raw: [UInt8] = [0x11, 0xFF, 0xFF, 0x00, 0x15, 0x09] + Array(repeating: 0, count: 14)
        guard case let .success(.error(error)) = Inbound.decode(raw) else { return XCTFail("not an error") }
        XCTAssertEqual(error.code, 0x09)
        XCTAssertEqual(error.featureIndex, 0x00)
        XCTAssertEqual(error.function, 1)
        XCTAssertEqual(error.softwareID, 5)
        XCTAssertEqual(HIDPP.errorName(error.code), "unsupported")
    }

    func testRejectsBadLengthAndReportID() {
        XCTAssertEqual(Inbound.decode([0x11, 0xFF]), .failure(.length(2)))
        XCTAssertEqual(Inbound.decode([0x10] + Array(repeating: 0, count: 19)), .failure(.reportID(0x10)))
    }

    func testReplyWithOtherSoftwareIDIsNotAnAnswer() throws {
        let request = Request.ping(deviceIndex: 0xFF, data: 1)
        let other: [UInt8] = [0x11, 0xFF, 0x00, 0x13, 0x04, 0x02, 0x01] + Array(repeating: 0, count: 13)
        let decoded = try Inbound.decode(other).get()
        XCTAssertFalse(decoded.answers(request))
    }

    func testErrorAnswersOnlyTheRequestItNames() throws {
        let request = Request.ping(deviceIndex: 0xFF, data: 1)
        let mine = try Inbound.decode([0x11, 0xFF, 0xFF, 0x00, 0x15, 0x02] + Array(repeating: 0, count: 14)).get()
        let theirs = try Inbound.decode([0x11, 0xFF, 0xFF, 0x07, 0x15, 0x02] + Array(repeating: 0, count: 14)).get()
        XCTAssertTrue(mine.answers(request))
        XCTAssertFalse(theirs.answers(request))
    }

    func testNormalizePrependsMissingReportID() {
        let stripped = Array(repeating: UInt8(0), count: 19)
        XCTAssertEqual(HIDPP.normalize(reportID: 0x11, bytes: stripped).first, 0x11)
        let whole = [0x11] + stripped
        XCTAssertEqual(HIDPP.normalize(reportID: 0x11, bytes: whole), whole)
    }

    func testOpenClassification() {
        XCTAssertEqual(classifyOpen(0xE00002E2).0, .tccDenied)
        XCTAssertEqual(classifyOpen(0xE00002C1).0, .notPrivileged)
        XCTAssertEqual(classifyOpen(0xE00002C0).0, .deviceAbsent)
        XCTAssertEqual(classifyOpen(0).0, .ok)
        XCTAssertEqual(classifyOpen(0xDEADBEEF).0, .openFailed)
    }

    func testEnvOverridesConfigAndRejectsBadHex() throws {
        let device = try resolveDevice("mouse", env: ["LOGITECH_CONFIG": "/nonexistent", "LOGITECH_PID": "0xB999"])
        XCTAssertEqual(device.pid, 0xB999)
        XCTAssertThrowsError(try resolveDevice("mouse", env: ["LOGITECH_CONFIG": "/nonexistent", "LOGITECH_PID": "zz"]))
    }
}
