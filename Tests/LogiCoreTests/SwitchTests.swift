import XCTest
@testable import LogiCore

// Replays discovery traffic recorded from the real keyboard and mouse. Both sit on
// slot 1; slot 0 is paired on both; slot 2 is paired on the mouse only.
private final class Bench {
    var tables: [String: [String: String]] = [:]
    var setReplies: [String: Inbound] = [:]
    var leavesAfter: [String: Int] = [:]
    var sleepOnSend: (device: String, seconds: TimeInterval)?
    var silent: Set<String> = []
    var sent: [String] = []
    var now = Date(timeIntervalSince1970: 1_700_000_000)
    let delays: [TimeInterval] = [0.25, 0.5, 1, 2]
    private var pendingSleep: TimeInterval = 0
    private var polls: [String: Int] = [:]

    init() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/mx-keys-s-master-4.jsonl")
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            let entry = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            if let rx = entry["rx"] as? String {
                tables[entry["device"] as! String, default: [:]][entry["tx"] as! String] = rx
            }
        }
    }

    lazy var clock = Clock(now: { self.now }, sleep: { seconds in
        self.now += seconds + self.pendingSleep
        self.pendingSleep = 0
    })

    func exchange(_ device: String) -> Exchange {
        { request in
            if self.silent.contains(device) { throw ExchangeTimeout(seconds: 1) }
            let tx = hexString(request.encode())
            if let rx = self.tables[device]?[tx] {
                return try Inbound.decode(Array(hex: rx)).get()
            }
            self.sent.append(device)
            if self.sleepOnSend?.device == device { self.pendingSleep = self.sleepOnSend!.seconds }
            if let reply = self.setReplies[device] { return reply }
            throw ExchangeTimeout(seconds: 1)
        }
    }

    func isPresent(_ device: String) -> Bool {
        guard sent.contains(device) else { return true }
        polls[device, default: 0] += 1
        return polls[device]! < leavesAfter[device, default: .max]
    }

    func pushes(_ target: Target, _ devices: [String] = ["mouse", "keyboard"]) throws -> [Push] {
        try devices.map { device in
            let exchange = self.exchange(device)
            return Push(device: device, leg: try plan(target, device: device, exchange), exchange: exchange,
                        isPresent: { self.isPresent(device) })
        }
    }

    func run(_ target: Target) throws -> [Outcome] {
        let pushes = try pushes(target)
        return LogiCore.run(pushes, started: now, clock: clock, backoff: Backoff(delays: delays))
    }
}

private extension Array where Element == UInt8 {
    init(hex: String) {
        var bytes: [UInt8] = []
        var rest = Substring(hex)
        while !rest.isEmpty {
            bytes.append(UInt8(rest.prefix(2), radix: 16)!)
            rest = rest.dropFirst(2)
        }
        self = bytes
    }
}

final class SwitchTests: XCTestCase {
    let names = ["mouse", "keyboard"]

    func testHappyPathMovesMouseThenKeyboard() throws {
        let bench = try Bench()
        bench.leavesAfter = ["mouse": 2, "keyboard": 1]
        let outcomes = try bench.run(.slot(0))
        XCTAssertEqual(outcomes, [.moved(after: 0.75), .moved(after: 0.25)])
        XCTAssertEqual(bench.sent, ["mouse", "keyboard"])
        XCTAssertEqual(verdict(names, outcomes).0, .ok)
    }

    func testSetHostEncodesResolvedIndexAndSlot() throws {
        let bench = try Bench()
        let mouse = try plan(.slot(0), device: "mouse", bench.exchange("mouse"))
        let keyboard = try plan(.slot(0), device: "keyboard", bench.exchange("keyboard"))
        XCTAssertEqual(hexString(Request.setHost(mouse).encode()), "11ff0e1500" + String(repeating: "00", count: 15))
        XCTAssertEqual(hexString(Request.setHost(keyboard).encode()), "11ff0a1500" + String(repeating: "00", count: 15))
    }

    func testMouseNeverLeavesKeepsKeyboardHere() throws {
        let bench = try Bench()
        let outcomes = try bench.run(.slot(0))
        XCTAssertEqual(outcomes, [.stayed(after: 9.75), .skipped])
        XCTAssertEqual(bench.sent, ["mouse"])
        let (code, reason) = verdict(names, outcomes)
        XCTAssertEqual(code, .stayed)
        XCTAssertEqual(reason, "mouse still here after 9.8s, keyboard left here")
    }

    func testSetHostReplyIsAcceptedLikeNoReply() throws {
        let bench = try Bench()
        let ack = Inbound.reply(Reply(deviceIndex: 0xFF, featureIndex: 14, function: 1, softwareID: 5, params: []))
        bench.setReplies = ["mouse": ack]
        bench.leavesAfter = ["mouse": 1, "keyboard": 1]
        XCTAssertEqual(try bench.run(.slot(0)), [.moved(after: 0.25), .moved(after: 0.25)])
    }

    func testReplyTimeoutDuringPlanningMovesNothing() throws {
        let bench = try Bench()
        bench.silent = ["keyboard"]
        XCTAssertThrowsError(try bench.pushes(.slot(0))) {
            XCTAssertEqual(($0 as? DiscoveryError)?.exit, .timeout)
        }
        XCTAssertTrue(bench.sent.isEmpty)
    }

    func testSleepMidPushStopsBeforeKeyboard() throws {
        let bench = try Bench()
        bench.leavesAfter = ["mouse": 1, "keyboard": 1]
        bench.sleepOnSend = ("mouse", 3600)
        let outcomes = try bench.run(.slot(0))
        XCTAssertEqual(outcomes, [.slept(seconds: 3600.25), .skipped])
        XCTAssertEqual(bench.sent, ["mouse"])
        XCTAssertEqual(verdict(names, outcomes).0, .slept)
    }

    func testSleepDuringPlanningSendsNothing() throws {
        let bench = try Bench()
        bench.leavesAfter = ["mouse": 1, "keyboard": 1]
        let started = bench.now
        let pushes = try bench.pushes(.slot(0))
        bench.now += 3600
        let outcomes = LogiCore.run(pushes, started: started, clock: bench.clock, backoff: Backoff(delays: bench.delays))
        XCTAssertEqual(outcomes, [.late(after: 3600), .skipped])
        XCTAssertTrue(bench.sent.isEmpty)
        let (code, reason) = verdict(names, outcomes)
        XCTAssertEqual(code, .slept)
        XCTAssertEqual(reason, "mouse not sent, 3600s since the switch was asked for, keyboard left here")
    }

    func testKeyboardNotSentOutsideWindow() throws {
        let bench = try Bench()
        bench.leavesAfter = ["mouse": 5, "keyboard": 1]
        let outcomes = LogiCore.run(try bench.pushes(.slot(0)), started: bench.now, clock: bench.clock, backoff: Backoff(delays: bench.delays, window: 5))
        XCTAssertEqual(outcomes, [.moved(after: 5.75), .late(after: 5.75)])
        XCTAssertEqual(bench.sent, ["mouse"])
        XCTAssertEqual(verdict(names, outcomes).0, .stranded)
    }

    func testSwitchedMessageNamesHostAndMovedDevices() throws {
        let bench = try Bench()
        let pushes = try bench.pushes(.name("Nibbler Book Pro"))
        XCTAssertEqual(switchedMessage(pushes, [.moved(after: 1), .moved(after: 1)]), "Mouse and keyboard moved to Nibbler Book Pro")
        XCTAssertEqual(switchedMessage(pushes, [.already, .moved(after: 1)]), "Keyboard moved to Nibbler Book Pro")
        XCTAssertEqual(switchedMessage(try bench.pushes(.slot(1)), [.already, .already]), "Already on Leela\u{2019}s MacBook Pro (2")
    }

    func testErrorReplyRefusesAndKeepsKeyboard() throws {
        let bench = try Bench()
        bench.setReplies = ["mouse": .error(ErrorReply(deviceIndex: 0xFF, featureIndex: 14, function: 1, softwareID: 5, code: 0x02))]
        let outcomes = try bench.run(.slot(0))
        XCTAssertEqual(outcomes, [.refused(code: 0x02), .skipped])
        let (code, reason) = verdict(names, outcomes)
        XCTAssertEqual(code, .deviceError)
        XCTAssertEqual(reason, "mouse refused change host: invalid argument, keyboard left here")
    }

    func testAlreadyOnTargetSendsNothing() throws {
        let bench = try Bench()
        let outcomes = try bench.run(.slot(1))
        XCTAssertEqual(outcomes, [.already, .already])
        XCTAssertTrue(bench.sent.isEmpty)
        XCTAssertEqual(verdict(names, outcomes).0, .ok)
    }

    func testKeyboardStuckAfterMouseMovedIsStranded() throws {
        let bench = try Bench()
        bench.leavesAfter = ["mouse": 1]
        let outcomes = try bench.run(.slot(0))
        XCTAssertEqual(outcomes, [.moved(after: 0.25), .stayed(after: 9.75)])
        let (code, reason) = verdict(names, outcomes)
        XCTAssertEqual(code, .stranded)
        XCTAssertEqual(reason, "mouse moved but keyboard still here after 9.8s, use the Easy-Switch keys to recover")
    }

    func testNamesResolvePerDevice() throws {
        let bench = try Bench()
        for device in names {
            XCTAssertEqual(try plan(.name("Nibbler Book Pro"), device: device, bench.exchange(device)).slot, 0)
            XCTAssertEqual(try plan(.name("Leela's MacBook Pro (2)"), device: device, bench.exchange(device)).slot, 1)
        }
        XCTAssertEqual(try plan(.name("leela's macbook"), device: "keyboard", bench.exchange("keyboard")).slot, 1)
        XCTAssertThrowsError(try plan(.name("leela's macbook"), device: "mouse", bench.exchange("mouse"))) {
            guard case SwitchError.ambiguousHost = $0 else { return XCTFail("wrong error \($0)") }
        }
        XCTAssertThrowsError(try plan(.name("Mac Mini"), device: "mouse", bench.exchange("mouse"))) {
            XCTAssertEqual(($0 as? SwitchError)?.exit, .unknownHost)
        }
    }

    func testUnpairedAndOutOfRangeSlotsAreRefusedBeforeSending() throws {
        let bench = try Bench()
        XCTAssertNoThrow(try plan(.slot(2), device: "mouse", bench.exchange("mouse")))
        XCTAssertThrowsError(try plan(.slot(2), device: "keyboard", bench.exchange("keyboard"))) {
            XCTAssertEqual($0 as? SwitchError, .unpaired(slot: 2))
        }
        XCTAssertThrowsError(try plan(.slot(3), device: "mouse", bench.exchange("mouse"))) {
            XCTAssertEqual($0 as? SwitchError, .outOfRange(slot: 3, count: 3))
        }
        XCTAssertTrue(bench.sent.isEmpty)
    }

    func testAliasNeedsSlotForEachDevice() throws {
        let bench = try Bench()
        let target = Target.alias("work", ["mouse": 0])
        XCTAssertEqual(try plan(target, device: "mouse", bench.exchange("mouse")).slot, 0)
        XCTAssertThrowsError(try plan(target, device: "keyboard", bench.exchange("keyboard"))) {
            XCTAssertEqual($0 as? SwitchError, .noSlot(alias: "work"))
        }
    }

    func testNextSkipsSlotsNotPairedOnEveryDevice() throws {
        let bench = try Bench()
        let keyboard = try discoverDevice(bench.exchange("keyboard"))
        let mouse = try discoverDevice(bench.exchange("mouse"))
        // Slot 2 is paired on the mouse only, so from slot 1 the cycle wraps to 0.
        XCTAssertEqual(try nextSlot([mouse, keyboard]), 0)
        XCTAssertEqual(try nextSlot([mouse]), 2)
        XCTAssertEqual(try plan(.next, device: "keyboard", bench.exchange("keyboard")).slot, 0)
    }

    func testNextCyclesThroughThreeHosts() throws {
        let bench = try Bench()
        var keyboard = try discoverDevice(bench.exchange("keyboard"))
        var mouse = try discoverDevice(bench.exchange("mouse"))
        keyboard.slots[2].status = 1
        var visited: [Int] = []
        for _ in 0..<4 {
            let slot = try nextSlot([mouse, keyboard])
            visited.append(slot)
            mouse.currentHost = slot
            keyboard.currentHost = slot
        }
        XCTAssertEqual(visited, [2, 0, 1, 2])
    }

    func testNextNeedsMatchingSlotsAndAnotherHost() throws {
        let bench = try Bench()
        var keyboard = try discoverDevice(bench.exchange("keyboard"))
        let mouse = try discoverDevice(bench.exchange("mouse"))
        keyboard.currentHost = 0
        XCTAssertThrowsError(try nextSlot([mouse, keyboard])) {
            XCTAssertEqual($0 as? SwitchError, .slotsDisagree(current: [1, 0]))
        }
        keyboard.currentHost = 1
        keyboard.slots[0].status = 0
        XCTAssertThrowsError(try nextSlot([mouse, keyboard])) {
            XCTAssertEqual($0 as? SwitchError, .noNextHost)
        }
    }

    func testTargetParsing() {
        let hosts = ["work": ["mouse": 0, "keyboard": 0]]
        XCTAssertEqual(Target("0", hosts: hosts), .slot(0))
        XCTAssertEqual(Target("work", hosts: hosts), .alias("work", ["mouse": 0, "keyboard": 0]))
        XCTAssertEqual(Target("Nibbler Book Pro", hosts: hosts), .name("Nibbler Book Pro"))
        XCTAssertEqual(Target(nil, hosts: hosts), .next)
        XCTAssertEqual(Target("next", hosts: hosts), .next)
    }

    func testSwitchOrderPutsMouseFirst() {
        XCTAssertEqual(switchOrder(["keyboard", "mouse"]), ["mouse", "keyboard"])
        XCTAssertEqual(switchOrder(["keyboard"]), ["keyboard"])
    }

    func testRetryingStopsOnSuccessAndOnOtherErrors() throws {
        struct Absent: Error {}
        struct Broken: Error {}
        var attempts = 0
        var slept: [TimeInterval] = []
        let value = try retrying([0.25, 0.5, 1], sleep: { slept.append($0) }, when: { $0 is Absent }) { () throws -> Int in
            attempts += 1
            if attempts < 3 { throw Absent() }
            return 7
        }
        XCTAssertEqual(value, 7)
        XCTAssertEqual(slept, [0.25, 0.5])

        attempts = 0
        XCTAssertThrowsError(try retrying([0.25], sleep: { _ in }, when: { $0 is Absent }) { () throws -> Int in
            attempts += 1
            throw Broken()
        })
        XCTAssertEqual(attempts, 1)
    }

    func testSettingsReadHostsTargetAndTimeouts() throws {
        let path = NSTemporaryDirectory() + "logitech-switcher-\(UUID().uuidString).json"
        try Data(#"{"hosts":{"work":{"mouse":0,"keyboard":0}},"target":"work","timeouts":{"confirm":10},"notify":"failures"}"#.utf8)
            .write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let settings = try switchSettings(env: ["LOGITECH_CONFIG": path])
        XCTAssertEqual(settings.target, "work")
        XCTAssertEqual(settings.hosts["work"], ["mouse": 0, "keyboard": 0])
        XCTAssertEqual(settings.reply, 1.0)
        XCTAssertEqual(settings.confirm, 10)
        XCTAssertEqual(settings.window, 20)
        XCTAssertEqual(settings.notify, .failures)
        XCTAssertEqual(settings.trigger, 0x00EA)
        XCTAssertEqual(try deviceNames(env: ["LOGITECH_CONFIG": path]), ["keyboard", "mouse"])
    }
}
