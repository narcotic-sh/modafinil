import Foundation
import IOKit

public enum SystemUserActivity {
    public static func idleSeconds() -> TimeInterval? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString,
            kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber else { return nil }
        return value.doubleValue / 1_000_000_000
    }
}
