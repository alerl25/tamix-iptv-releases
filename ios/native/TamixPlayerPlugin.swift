import Capacitor
import Foundation
import UIKit

/// Tamix IPTV on iPhone: the `TamixPlayer` Capacitor plugin, the same contract
/// as the Android one (libs/ui/playback/.../native-player.types.ts): `play`
/// opens a full-screen VLC player, `stop` closes it, and the events `started`,
/// `time`, `ended`, `error` and `closed` report back to the web app.
@objc(TamixPlayerPlugin)
public class TamixPlayerPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "TamixPlayerPlugin"
    public let jsName = "TamixPlayer"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "play", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stop", returnType: CAPPluginReturnPromise),
    ]

    private weak var current: TamixPlayerViewController?

    @objc func play(_ call: CAPPluginCall) {
        guard let address = call.getString("url"), let url = URL(string: address) else {
            call.reject("Missing stream address")
            return
        }
        var headers: [String: String] = [:]
        if let object = call.getObject("headers") {
            for (key, value) in object {
                if let text = value as? String { headers[key] = text }
            }
        }
        let request = TamixPlayRequest(
            url: url,
            title: call.getString("title") ?? "",
            userAgent: call.getString("userAgent"),
            headers: headers,
            startMs: Int64(call.getDouble("startMs") ?? 0),
            isLive: call.getBool("isLive") ?? false
        )
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.bridge?.viewController != nil else {
                call.reject("No view to present the player")
                return
            }
            // Never present over a player that is still closing: wait until the
            // old one is off screen.
            let present: () -> Void = { [weak self] in
                guard let self = self, let host = self.bridge?.viewController else {
                    call.reject("No view to present the player")
                    return
                }
                let player = TamixPlayerViewController(request: request) { [weak self] event, data in
                    self?.notifyListeners(event, data: data)
                }
                player.modalPresentationStyle = .fullScreen
                self.current = player
                host.present(player, animated: true) { call.resolve() }
            }
            if let old = self.current {
                old.close(reason: "stopped")
                old.whenDismissed(present)
            } else {
                present()
            }
        }
    }

    @objc func stop(_ call: CAPPluginCall) {
        DispatchQueue.main.async { [weak self] in
            self?.current?.close(reason: "stopped")
            call.resolve()
        }
    }
}

/// What the web asks to play.
struct TamixPlayRequest {
    let url: URL
    let title: String
    let userAgent: String?
    let headers: [String: String]
    let startMs: Int64
    let isLive: Bool
}
