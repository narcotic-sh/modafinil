import Foundation
import IOKit.ps

struct BatteryStatus: Equatable {
    let percentage: Int
    let isOnBatteryPower: Bool
}

final class BatteryMonitor {
    var onStatusChange: ((BatteryStatus?) -> Void)?

    private var runLoopSource: CFRunLoopSource?

    deinit {
        stop()
    }

    func start() throws {
        guard runLoopSource == nil else { return }

        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.publishCurrentStatus()
        }, context)?.takeRetainedValue() else {
            throw MonitorError.notificationSourceUnavailable
        }

        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        publishCurrentStatus()
    }

    func stop() {
        guard let runLoopSource else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        self.runLoopSource = nil
    }

    func currentStatus() -> BatteryStatus? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return nil
        }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue()
                    as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let currentCapacity = description[kIOPSCurrentCapacityKey] as? NSNumber,
                  let maximumCapacity = description[kIOPSMaxCapacityKey] as? NSNumber,
                  maximumCapacity.doubleValue > 0,
                  let powerSourceState = description[kIOPSPowerSourceStateKey] as? String
            else {
                continue
            }

            let percentage = Int(
                (currentCapacity.doubleValue / maximumCapacity.doubleValue * 100).rounded()
            )
            return BatteryStatus(
                percentage: min(100, max(0, percentage)),
                isOnBatteryPower: powerSourceState == kIOPSBatteryPowerValue
            )
        }

        return nil
    }

    private func publishCurrentStatus() {
        onStatusChange?(currentStatus())
    }

    enum MonitorError: LocalizedError {
        case notificationSourceUnavailable

        var errorDescription: String? {
            "Could not monitor the Mac's battery status."
        }
    }
}
