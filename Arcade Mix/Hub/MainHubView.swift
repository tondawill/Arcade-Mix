//
//  MainHubView.swift
//  Arcade Mix
//
//  The portrait landing screen: a grid of game tiles driven entirely by
//  `GameInfo.catalog`, each showing its top high score. Tapping an available game asks
//  the coordinator to open it; "Coming Soon" games are not tappable.
//

import SwiftUI

struct MainHubView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var backend: BackendProvider
    @StateObject private var viewModel = HubViewModel()

    private let columns = [GridItem(.flexible(), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(GameInfo.catalog) { game in
                        Button {
                            // Connect 4 owns its own mode-picker, so it skips the
                            // score-based start menu and opens directly.
                            if game.id == .connect4 {
                                coordinator.open(game.id)
                            } else {
                                coordinator.showStartMenu(game.id)
                            }
                        } label: {
                            GameTileView(game: game, topScore: viewModel.topScores[game.id])
                        }
                        .buttonStyle(.plain)
                        .disabled(game.status == .comingSoon)
                    }
                }
                .padding(20)
            }
            .navigationTitle(Text("Hub_Title"))
            .background(Color(.systemGroupedBackground))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if let name = backend.currentUser?.leaderboardName {
                            Text(verbatim: name)
                            Button(role: .destructive) {
                                Task { await backend.signOut() }
                            } label: {
                                Label("Auth_SignOut", systemImage: "rectangle.portrait.and.arrow.right")
                            }
                        } else {
                            // Guest: offer a way back to the sign-in screen (e.g. once online).
                            Button {
                                Task { await backend.signOut() }
                            } label: {
                                Label("Auth_SignIn", systemImage: "person.crop.circle.badge.plus")
                            }
                        }
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                }
            }
            .refreshable { await viewModel.loadTopScores(using: backend.highScores) }
            .task {
                // A guest who has since reconnected gets sent back to sign-in.
                backend.promptSignInIfPending()
                await viewModel.loadTopScores(using: backend.highScores)
            }
        }
    }
}

#Preview {
    MainHubView()
        .environmentObject(AppCoordinator())
        .environmentObject(BackendProvider())
}
