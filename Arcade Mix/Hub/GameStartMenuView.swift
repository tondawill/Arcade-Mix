//
//  GameStartMenuView.swift
//  Arcade Mix
//
//  Landscape pre-play screen shown when a game is selected from the hub. Gives the
//  player a moment to reorient the device and see their personal best alongside the
//  all-time top score before a big Start button drops them into the match.
//

import SwiftUI
import Combine

struct GameStartMenuView: View {
    let gameID: GameID

    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var backend: BackendProvider
    @StateObject private var viewModel = GameStartMenuViewModel()

    private var info: GameInfo? { GameInfo.catalog.first { $0.id == gameID } }

    var body: some View {
        ZStack {
            Rectangle()
                .fill((info?.accentColor ?? .accentColor).gradient)
                .ignoresSafeArea()

            content
                .padding(.horizontal, 40)
                .frame(maxWidth: 720)
        }
        .statusBarHidden()
        .overlay(alignment: .topLeading) {
            Button {
                coordinator.returnToHub()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .padding(14)
                    .background(.black.opacity(0.18), in: Circle())
            }
            .padding(20)
        }
        .task {
            await viewModel.load(gameID: gameID,
                                 service: backend.highScores,
                                 user: backend.currentUser)
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 28) {
            VStack(spacing: 12) {
                if let info {
                    Image(systemName: info.systemImage)
                        .font(.system(size: 56, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(info.titleKey)
                        .font(.largeTitle.bold())
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                }
            }

            HStack(spacing: 16) {
                scoreCard(title: "StartMenu_YourBest",
                          icon: "person.fill",
                          score: viewModel.personalBest?.score,
                          subtitle: nil)
                scoreCard(title: "StartMenu_TopScore",
                          icon: "trophy.fill",
                          score: viewModel.topScore?.score,
                          subtitle: viewModel.topScore?.displayName)
            }
            .opacity(viewModel.isLoading ? 0.4 : 1)
            .overlay {
                if viewModel.isLoading { ProgressView().tint(.white) }
            }

            Button {
                coordinator.open(gameID)
            } label: {
                Text("StartMenu_Start")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .foregroundStyle(info?.accentColor ?? .accentColor)
            .controlSize(.large)
        }
    }

    @ViewBuilder
    private func scoreCard(title: LocalizedStringResource,
                           icon: String,
                           score: Int?,
                           subtitle: String?) -> some View {
        VStack(spacing: 8) {
            Label { Text(title) } icon: { Image(systemName: icon) }
                .font(.subheadline.bold())
                .foregroundStyle(.white.opacity(0.95))
            if let score {
                Text(verbatim: "\(score)")
                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                if let subtitle, !subtitle.isEmpty {
                    Text(verbatim: subtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
            } else {
                Text("HighScore_None")
                    .font(.title3.bold())
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

@MainActor
final class GameStartMenuViewModel: ObservableObject {
    @Published private(set) var personalBest: HighScore?
    @Published private(set) var topScore: HighScore?
    @Published private(set) var isLoading = false

    func load(gameID: GameID, service: HighScoreService, user: AppUser?) async {
        isLoading = true
        defer { isLoading = false }
        topScore = try? await service.topScore(for: gameID)
        if let user {
            personalBest = try? await service.personalBest(for: gameID, userID: user.id)
        }
    }
}
