import XCTest
@testable import LogiCore

final class ControlsTests: XCTestCase {
    func testCidInfoDecodesFlagsAndNamesEasySwitch() throws {
        let control = try XCTUnwrap(Control([0x00, 0xD1, 0x00, 0xAE, 0x24, 0x01, 0x00, 0x00, 0x04, 0, 0, 0, 0, 0, 0, 0]))
        XCTAssertEqual(control.cid, 0x00D1)
        XCTAssertEqual(control.traits, ["hotkey", "divertable", "analyticsKeyEvents"])
        XCTAssertEqual(control.json["name"] as? String, "Easy-Switch 1")
        XCTAssertEqual(control.raw, "00d100ae2401000004")
    }

    func testShortCidInfoIsDropped() {
        XCTAssertNil(Control([0x00, 0xD1]))
    }
}

final class AnalyticsRequestTests: XCTestCase {
    func testSetAnalyticsTouchesOnlyAnalyticsBits() {
        let on = Request.setAnalytics(deviceIndex: 0xFF, featureIndex: 9, cid: 0x00D2, on: true)
        XCTAssertEqual(hexString(on.encode()), "11ff093500d2000000030000000000000000000000".dropLast(2).description)
        let off = Request.setAnalytics(deviceIndex: 0xFF, featureIndex: 9, cid: 0x00D2, on: false)
        XCTAssertEqual(off.params, [0x00, 0xD2, 0x00, 0x00, 0x00, 0x02])
    }

    func testAnalyticsEventsSkipPadding() {
        let events = analyticsEvents([0x00, 0xD1, 0x01, 0x00, 0x0A, 0x00] + Array(repeating: 0, count: 10))
        XCTAssertEqual(events.map(\.cid), [0x00D1, 0x000A])
        XCTAssertEqual(events.map(\.event), [1, 0])
    }

    func testScrollLockPressFromRecordedReports() {
        let press = Array<UInt8>([0x11, 0xFF, 0x09, 0x20, 0x00, 0xEA, 0x01]) + Array(repeating: 0, count: 13)
        let release = Array<UInt8>([0x11, 0xFF, 0x09, 0x20, 0x00, 0xEA, 0x00]) + Array(repeating: 0, count: 13)
        let reply = Array<UInt8>([0x11, 0xFF, 0x09, 0x35, 0x00, 0xEA, 0x00, 0x00, 0x00, 0x03]) + Array(repeating: 0, count: 10)
        XCTAssertTrue(isPress(press, featureIndex: 9, cid: 0x00EA))
        XCTAssertFalse(isPress(release, featureIndex: 9, cid: 0x00EA))
        XCTAssertFalse(isPress(reply, featureIndex: 9, cid: 0x00EA))
        XCTAssertFalse(isPress(press, featureIndex: 9, cid: 0x00D1))
        XCTAssertFalse(isPress(press, featureIndex: 10, cid: 0x00EA))
    }
}
