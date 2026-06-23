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
    @State private var showHelp = false

    private var info: GameInfo? { GameInfo.catalog.first { $0.id == gameID } }

    var body: some View {
        ZStack {
            Rectangle()
                .fill((info?.accentColor ?? .accentColor).gradient)
                .ignoresSafeArea()

            // Scale the layout to the available height so it always fits without scrolling,
            // even on short landscape screens (e.g. iPhone SE). Centered in the space.
            GeometryReader { proxy in
                content(scale: max(0.75, min(1, proxy.size.height / 470)))
                    .padding(.horizontal, 40)
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
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
        .overlay(alignment: .topTrailing) {
            Button {
                showHelp = true
            } label: {
                Image(systemName: "questionmark")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .padding(14)
                    .background(.black.opacity(0.18), in: Circle())
            }
            .padding(20)
        }
        .sheet(isPresented: $showHelp) {
            if let info { HowToPlayView(info: info) }
        }
        .task {
            await viewModel.load(gameID: gameID,
                                 service: backend.highScores,
                                 user: backend.currentUser)
        }
    }

    @ViewBuilder
    private func content(scale: CGFloat) -> some View {
        VStack(spacing: 22 * scale) {
            VStack(spacing: 10 * scale) {
                if let info {
                    Image(systemName: info.systemImage)
                        .font(.system(size: 52 * scale, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(info.titleKey)
                        .font(.system(size: 34 * scale, weight: .bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.7)
                }
            }

            HStack(spacing: 16 * scale) {
                scoreCard(title: "StartMenu_YourBest",
                          icon: "person.fill",
                          score: viewModel.personalBest?.score,
                          subtitle: nil,
                          scale: scale)
                scoreCard(title: "StartMenu_TopScore",
                          icon: "trophy.fill",
                          score: viewModel.topScore?.score,
                          subtitle: viewModel.topScore?.displayName,
                          scale: scale)
            }
            .opacity(viewModel.isLoading ? 0.4 : 1)
            .overlay {
                if viewModel.isLoading { ProgressView().tint(.white) }
            }

            VStack(spacing: 12 * scale) {
                Button {
                    coordinator.open(gameID)
                } label: {
                    Text("StartMenu_Start")
                        .font(.system(size: 22 * scale, weight: .bold))
                        .shrinkToFit()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16 * scale)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(info?.accentColor ?? .accentColor)
                .controlSize(.large)

                // Rugby only: a smaller, dimmed shortcut straight into Advanced Mode.
                if gameID == .rugby {
                    Button {
                        coordinator.open(.rugby, rugbyAdvanced: true)
                    } label: {
                        HStack(spacing: 8 * scale) {
                            Label("Rugby_Mode_Advanced", systemImage: "hand.draw.fill")
                                .font(.system(size: 15 * scale, weight: .bold))
                                .shrinkToFit()
                            Text("Rugby_Mode_InProgress")
                                .font(.system(size: 11 * scale, weight: .bold))
                                .padding(.horizontal, 7 * scale)
                                .padding(.vertical, 2 * scale)
                                .background(.white.opacity(0.18), in: Capsule())
                        }
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.vertical, 10 * scale)
                        .frame(maxWidth: .infinity)
                        .background(.black.opacity(0.18), in: Capsule())
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func scoreCard(title: LocalizedStringResource,
                           icon: String,
                           score: Int?,
                           subtitle: String?,
                           scale: CGFloat) -> some View {
        VStack(spacing: 8 * scale) {
            Label { Text(title) } icon: { Image(systemName: icon) }
                .font(.system(size: 15 * scale, weight: .bold))
                .foregroundStyle(.white.opacity(0.95))
                .shrinkToFit()
            if let score {
                Text(verbatim: "\(score)")
                    .font(.system(size: 40 * scale, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .shrinkToFit()
                if let subtitle, !subtitle.isEmpty {
                    Text(verbatim: subtitle)
                        .font(.system(size: 12 * scale))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            } else {
                Text("HighScore_None")
                    .font(.system(size: 20 * scale, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .shrinkToFit()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18 * scale)
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
