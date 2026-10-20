import Foundation
import IOKit
import IOKit.hid
import LogiCore

func fail(_ code: Exit, _ reason: String) -> Never {
    FileHandle.standardError.write(Data("spike: \(reason)\n".utf8))
    exit(code.rawValue)
}

let name = CommandLine.arguments.dropFirst().first ?? "mouse"
let spec: ResolvedDevice
do {
    spec = try resolveDevice(name)
} catch let error as ConfigError {
    fail(error.exit, error.description)
}

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, [
    kIOHIDVendorIDKey: spec.vid,
    kIOHIDProductIDKey: spec.pid,
    kIOHIDDeviceUsagePageKey: spec.usagePage,
    kIOHIDDeviceUsageKey: spec.usage,
] as CFDictionary)

let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
guard let device = devices.first else {
    fail(.noMatch, String(format: "'%@' no device matches %04X:%04X %04X/%04X", name, spec.vid, spec.pid, spec.usagePage, spec.usage))
}

let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
let (code, reason) = classifyOpen(UInt32(bitPattern: result))
emitJSON([
    "name": name,
    "matched": devices.count,
    "product": IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "",
    "pid": String(format: "0x%04X", spec.pid),
    "uid": getuid(),
    "ioreturn": String(format: "0x%08X", UInt32(bitPattern: result)),
    "result": reason,
])
if result == kIOReturnSuccess { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
exit(code.rawValue)
