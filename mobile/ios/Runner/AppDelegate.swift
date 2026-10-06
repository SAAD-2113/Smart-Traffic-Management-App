import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Hardware mode helpers (same channel as Android's MainActivity). iOS keeps local-network
    // traffic on Wi-Fi by itself, so only keepScreenOn is needed here.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "HardwareModeChannel") {
      let channel = FlutterMethodChannel(
        name: "com.fyp.smart_traffic/hardware", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        switch call.method {
        case "keepScreenOn":
          let on = (call.arguments as? [String: Any])?["on"] as? Bool ?? false
          DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = on }
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
  }
}
