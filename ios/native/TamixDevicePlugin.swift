import Capacitor
import Foundation

/// Tamix on iPhone: the `TamixDevice` plugin the web app asks whether it runs
/// on a television (Android TV, Fire TV). An iPhone or iPad never is, so the
/// app keeps its touch interface.
@objc(TamixDevicePlugin)
public class TamixDevicePlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "TamixDevicePlugin"
    public let jsName = "TamixDevice"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "info", returnType: CAPPluginReturnPromise),
    ]

    @objc func info(_ call: CAPPluginCall) {
        call.resolve(["tv": false])
    }
}
