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
                            coordinator.open(game.id)
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
                        }
                        Button(role: .destructive) {
                            Task { await backend.signOut() }
                        } label: {
                            Label("Auth_SignOut", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                }
            }
            .refreshable { await viewModel.loadTopScores(using: backend.highScores) }
            .task { await viewModel.loadTopScores(using: backend.highScores) }
        }
    }
}

#Preview {
    MainHubView()
        .environmentObject(AppCoordinator())
        .environmentObject(BackendProvider())
}
