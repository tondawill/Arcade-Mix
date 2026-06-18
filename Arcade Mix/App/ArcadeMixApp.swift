//
//  ArcadeMixApp.swift
//  Arcade Mix
//
//  SwiftUI App entry point. Owns the shared `AppCoordinator` and `BackendProvider`
//  and injects them into the environment so any screen can navigate or reach the
//  backend without manual plumbing.
//

import SwiftUI

@main
struct ArcadeMixApp: App {

    // Retained only for orientation locking (see AppDelegate).
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var coordinator = AppCoordinator()
    @StateObject private var backend = BackendProvider()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(coordinator)
                .environmentObject(backend)
        }
    }
}

/// Top-level view that gates on auth, then swaps between the hub and the active game
/// based on the coordinator's route. This is the single place that maps a `GameID` to
/// its view.
struct RootView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var backend: BackendProvider
    @State private var didBootstrap = false

    var body: some View {
        Group {
            if backend.currentUser == nil && !backend.isGuest {
                LoginView()
            } else {
                switch coordinator.route {
                case .hub:
                    MainHubView()
                case .startMenu(let id):
                    GameStartMenuView(gameID: id)
                case .game(let id):
                    gameView(for: id)
                }
            }
        }
        .task {
            guard !didBootstrap else { return }
            didBootstrap = true
            await backend.bootstrap()
        }
    }

    @ViewBuilder
    private func gameView(for id: GameID) -> some View {
        switch id {
        case .afl:
            AFLGameView()
        case .rugby:
            RugbyGameView()
        case .connect4:
            Connect4View()
        }
    }
}
