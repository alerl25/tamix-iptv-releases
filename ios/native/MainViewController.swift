import Capacitor
import UIKit

/// The app's Capacitor screen with Tamix's own native plugins registered
/// (Main.storyboard points here instead of CAPBridgeViewController).
class MainViewController: CAPBridgeViewController {
    override open func capacitorDidLoad() {
        bridge?.registerPluginInstance(TamixPlayerPlugin())
        bridge?.registerPluginInstance(TamixDevicePlugin())
    }
}
