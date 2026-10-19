public enum Exit: Int32 {
    case ok = 0
    case usage = 2
    case tccDenied = 10
    case notPrivileged = 11
    case deviceAbsent = 12
    case noMatch = 13
    case openFailed = 14
    case configUnreadable = 15
    case unknownDevice = 16
    case badValue = 17
    case sendFailed = 40
    case timeout = 41
    case deviceError = 42
    case unknownHost = 50
    case unpaired = 51
    case stayed = 52
    case slept = 53
    case stranded = 54
}

public func classifyOpen(_ ioreturn: UInt32) -> (Exit, String) {
    switch ioreturn {
    case 0: return (.ok, "opened")
    case 0xE00002E2: return (.tccDenied, "TCC denial: grant Input Monitoring to this binary")
    case 0xE00002C1: return (.notPrivileged, "TCC passed, caller not privileged: needs root")
    case 0xE00002C0: return (.deviceAbsent, "device absent or asleep")
    default: return (.openFailed, "unexpected IOReturn")
    }
}
