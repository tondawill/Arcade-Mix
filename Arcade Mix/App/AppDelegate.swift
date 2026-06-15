//
//  AppDelegate.swift
//  Arcade Mix
//
//  Minimal UIKit delegate retained ONLY to enforce per-screen orientation locking,
//  which SwiftUI alone cannot express. The app otherwise uses the SwiftUI App
//  lifecycle (see `ArcadeMixApp`).
//

import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {

    /// The orientation mask the app is currently allowed to use.
    ///
    /// Updated by `AppCoordinator` as the user navigates: portrait for the hub /
    /// menus, landscape while playing the AFL game. iOS reads this through
    /// `application(_:supportedInterfaceOrientationsFor:)` below.
    static var orientationLock: UIInterfaceOrientationMask = .portrait

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        Self.orientationLock
    }
}
