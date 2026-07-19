//
//  AppDelegate.swift
//  NuvioTV
//
//  Pure Swift/SwiftUI tvOS application
//

import UIKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    // Apply in-app language before the first SwiftUI frame is built.
    AppLocaleManager.bootstrap()
    return true
  }

  // MARK: - URL Handling
  func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    // Handle URL schemes: nuvio-tv:// and com.nuvio.app.tv://
    // Add custom URL handling logic here
    return true
  }

  // MARK: - Universal Links
  func application(
    _ application: UIApplication,
    continue userActivity: NSUserActivity,
    restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
  ) -> Bool {
    // Handle universal links
    return true
  }
}
