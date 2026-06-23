//
//  AppCoordinator.swift
//  Arcade Mix
//
//  Central navigation + presentation state for the multi-game hub. The root view
//  (`RootView`) observes `route` and swaps between the hub and the active game.
//  Adding a new game later means: add a `GameID` case, a `GameInfo` catalog entry,
//  and a branch in `RootView` — no other navigation plumbing.
//

import SwiftUI
import Combine

@MainActor
final class AppCoordinator: ObservableObject {

    /// Where the app currently is. Drives `RootView`'s top-level switch.
    enum AppRoute: Equatable {
        case hub
        case startMenu(GameID)
        case game(GameID)
    }

    @Published private(set) var route: AppRoute = .hub

    /// Launch variant chosen on the Start Menu: Rugby's Advanced Mode. Set by `open` and
    /// read by `RugbyGameView` when it starts the match; reset to `false` on every open.
    @Published private(set) var rugbyAdvanced = false

    /// Show a game's pre-play Start Menu, rotating to that game's orientation so the
    /// player can reorient before any action begins.
    func showStartMenu(_ game: GameID) {
        route = .startMenu(game)
        applyOrientation(for: route)
    }

    /// Open a game, locking orientation to whatever that game requires. `rugbyAdvanced`
    /// launches Rugby straight into Advanced Mode (ignored by other games).
    func open(_ game: GameID, rugbyAdvanced: Bool = false) {
        self.rugbyAdvanced = rugbyAdvanced
        route = .game(game)
        applyOrientation(for: route)
    }

    /// Return to the portrait hub from any game.
    func returnToHub() {
        route = .hub
        applyOrientation(for: route)
    }

    // MARK: - Orientation

    /// Each route declares the orientation it wants; menus are portrait, the AFL
    /// game is landscape. We both (a) set the allowed mask the `AppDelegate`
    /// reports to iOS and (b) actively rotate the window to match.
    private func applyOrientation(for route: AppRoute) {
        let mask: UIInterfaceOrientationMask
        let preferred: UIInterfaceOrientationMask

        switch route {
        case .game(.afl), .startMenu(.afl), .game(.rugby), .startMenu(.rugby):
            mask = .landscape
            preferred = .landscapeRight
        case .hub, .game(.connect4), .startMenu(.connect4):
            mask = .portrait
            preferred = .portrait
        }

        AppDelegate.orientationLock = mask
        requestRotation(to: preferred)
    }

    private func requestRotation(to mask: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return }

        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
        // Nudge UIKit to re-evaluate `supportedInterfaceOrientationsFor`.
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}
