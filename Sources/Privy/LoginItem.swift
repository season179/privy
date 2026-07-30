import Foundation
import ServiceManagement

enum LoginItem {
    static var isRegistered: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func toggle() {
        do {
            if isRegistered {
                try SMAppService.mainApp.unregister()
                SpikeLog.log("loginItem unregistered")
            } else {
                try SMAppService.mainApp.register()
                SpikeLog.log("loginItem registered status=\(SMAppService.mainApp.status.rawValue)")
            }
        } catch {
            SpikeLog.log("loginItem error: \(error)")
        }
    }
}
