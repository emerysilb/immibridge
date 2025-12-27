import Foundation
import IOKit.ps

enum PowerManager {
    /// Returns true if the Mac is connected to AC power, false if on battery
    static func isOnACPower() -> Bool {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as [CFTypeRef]

        for source in sources {
            if let info = IOPSGetPowerSourceDescription(snapshot, source).takeUnretainedValue() as? [String: Any] {
                if let powerSource = info[kIOPSPowerSourceStateKey as String] as? String {
                    // "AC Power" means plugged in, "Battery Power" means on battery
                    return powerSource == kIOPSACPowerValue as String
                }
            }
        }

        // Default to true (assume AC power) if we can't determine
        return true
    }

    /// Returns the current battery level as a percentage (0-100), or nil if not available
    static func batteryLevel() -> Int? {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as [CFTypeRef]

        for source in sources {
            if let info = IOPSGetPowerSourceDescription(snapshot, source).takeUnretainedValue() as? [String: Any] {
                if let capacity = info[kIOPSCurrentCapacityKey as String] as? Int {
                    return capacity
                }
            }
        }

        return nil
    }
}
