import Foundation
import IOKit
import IOKit.hid
import LogiCore

public enum TransportError: Error, CustomStringConvertible {
    case noMatch(String)
    case open(UInt32)
    case send(UInt32)

    public var description: String {
        switch self {
        case let .noMatch(what): return "no device matches \(what), check it is connected to this Mac"
        case let .open(r): return "open failed \(String(format: "0x%08X", r)): \(classifyOpen(r).1)"
        case let .send(r): return "send failed \(String(format: "0x%08X", r))"
        }
    }

    public var exit: Exit {
        switch self {
        case .noMatch: return .noMatch
        case let .open(r): return classifyOpen(r).0
        case .send: return .sendFailed
        }
    }
}

public final class HIDPPDevice {
    private let manager: IOHIDManager
    private let device: IOHIDDevice
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private var inbox: [[UInt8]] = []
    public var onExchange: ((_ tx: [UInt8], _ rx: [UInt8]?) -> Void)?
    public var onReport: (([UInt8]) -> Void)?
    public var onRemoved: (() -> Void)?

    static func matching(_ spec: ResolvedDevice) -> IOHIDManager {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: spec.vid,
            kIOHIDProductIDKey: spec.pid,
            kIOHIDDeviceUsagePageKey: spec.usagePage,
            kIOHIDDeviceUsageKey: spec.usage,
        ] as CFDictionary)
        return manager
    }

    public static func hasAccess() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    // Shows the system Input Monitoring prompt the first time; later calls only report.
    public static func requestAccess() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
            || IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    public static func isPresent(_ spec: ResolvedDevice) -> Bool {
        let found = (IOHIDManagerCopyDevices(matching(spec)) as? Set<IOHIDDevice>) ?? []
        return !found.isEmpty
    }

    public init(_ spec: ResolvedDevice) throws {
        manager = Self.matching(spec)
        let found = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        guard let first = found.first else {
            throw TransportError.noMatch(String(format: "%04X:%04X %04X/%04X", spec.vid, spec.pid, spec.usagePage, spec.usage))
        }
        device = first

        let opened = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard opened == kIOReturnSuccess else { throw TransportError.open(UInt32(bitPattern: opened)) }

        IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, { context, _, _, _, reportID, report, length in
            let me = Unmanaged<HIDPPDevice>.fromOpaque(context!).takeUnretainedValue()
            let bytes = HIDPP.normalize(reportID: reportID, bytes: Array(UnsafeBufferPointer(start: report, count: length)))
            me.onReport?(bytes)
            // A long-lived handle sees every keystroke and mouse move; keep only HID++.
            if bytes.first == HIDPP.reportID { me.inbox = me.inbox.suffix(63) + [bytes] }
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceRegisterRemovalCallback(device, { context, _, _ in
            Unmanaged<HIDPPDevice>.fromOpaque(context!).takeUnretainedValue().onRemoved?()
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }

    deinit {
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        buffer.deallocate()
    }

    public func exchange(_ request: Request, timeout: TimeInterval) throws -> Inbound {
        let out = request.encode()
        let writeStart = CFAbsoluteTimeGetCurrent()
        let sent = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(out[0]), out, out.count)
        logEvent("tx", [
            "bytes": hexString(out), "ioreturn": String(format: "0x%08X", UInt32(bitPattern: sent)),
            "writeMs": Int((CFAbsoluteTimeGetCurrent() - writeStart) * 1000),
        ])
        guard sent == kIOReturnSuccess else { throw TransportError.send(UInt32(bitPattern: sent)) }

        let deadline = CFAbsoluteTimeGetCurrent() + timeout
        while true {
            if let (answer, bytes) = drain(for: request) {
                onExchange?(out, bytes)
                return answer
            }
            let remaining = deadline - CFAbsoluteTimeGetCurrent()
            if remaining <= 0 {
                onExchange?(out, nil)
                throw ExchangeTimeout(seconds: timeout)
            }
            CFRunLoopRunInMode(.defaultMode, min(remaining, 0.05), true)
        }
    }

    private func drain(for request: Request) -> (Inbound, [UInt8])? {
        var answer: (Inbound, [UInt8])?
        for bytes in inbox {
            switch Inbound.decode(bytes) {
            case let .success(message) where answer == nil && message.answers(request):
                logEvent("rx", ["bytes": hexString(bytes)])
                answer = (message, bytes)
            case .success:
                logEvent("rx_ignored", ["bytes": hexString(bytes)])
            case let .failure(reason):
                logEvent("rx_undecodable", ["bytes": hexString(bytes), "reason": "\(reason)"])
            }
        }
        inbox.removeAll()
        return answer
    }
}

// Reports every non-pointer input value from any keyboard or consumer-control
// collection, plus those collections arriving and leaving. Needs Input Monitoring.
public final class KeyWatch {
    public typealias Press = (_ page: UInt32, _ usage: UInt32, _ value: Int, _ product: String) -> Void
    public typealias Presence = (_ product: String, _ arrived: Bool) -> Void
    private let manager: IOHIDManager
    private let onPress: Press
    private let onPresence: Presence

    private static func product(_ device: IOHIDDevice) -> String {
        IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "?"
    }

    public init(onPress: @escaping Press, onPresence: @escaping Presence = { _, _ in }) throws {
        self.onPress = onPress
        self.onPresence = onPresence
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(manager, [
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard],
            [kIOHIDDeviceUsagePageKey: kHIDPage_Consumer, kIOHIDDeviceUsageKey: kHIDUsage_Csmr_ConsumerControl],
        ] as CFArray)
        // Open before registering callbacks: a throwing init frees self, and a
        // callback already registered would then fire into freed memory.
        let opened = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard opened == kIOReturnSuccess else { throw TransportError.open(UInt32(bitPattern: opened)) }
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, sender, value in
            let me = Unmanaged<KeyWatch>.fromOpaque(context!).takeUnretainedValue()
            let element = IOHIDValueGetElement(value)
            let page = IOHIDElementGetUsagePage(element)
            let usage = IOHIDElementGetUsage(element)
            let level = IOHIDValueGetIntegerValue(value)
            let pointer = page == kHIDPage_GenericDesktop && (kHIDUsage_GD_X...kHIDUsage_GD_Wheel).contains(Int(usage))
            guard level != 0, usage < 0xFFFF, !pointer else { return }
            me.onPress(page, usage, level, KeyWatch.product(IOHIDElementGetDevice(element)))
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            Unmanaged<KeyWatch>.fromOpaque(context!).takeUnretainedValue().onPresence(KeyWatch.product(device), true)
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            Unmanaged<KeyWatch>.fromOpaque(context!).takeUnretainedValue().onPresence(KeyWatch.product(device), false)
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }

    deinit {
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }
}

// Arrival and departure of one device's HID++ collection, including any already
// present when created.
public final class Presence {
    private let manager: IOHIDManager
    private let onChange: (Bool) -> Void

    public init(_ spec: ResolvedDevice, onChange: @escaping (Bool) -> Void) {
        manager = HIDPPDevice.matching(spec)
        self.onChange = onChange
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, _ in
            Unmanaged<Presence>.fromOpaque(context!).takeUnretainedValue().onChange(true)
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, _ in
            Unmanaged<Presence>.fromOpaque(context!).takeUnretainedValue().onChange(false)
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }

    deinit {
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }
}
