//
//  HubViewModel.swift
//  Arcade Mix
//
//  Loads the top high score for each game so the hub tiles can display it.
//

import SwiftUI
import Combine

@MainActor
final class HubViewModel: ObservableObject {
    /// Top score per game (nil entry = loaded, none yet; missing key = not loaded).
    @Published private(set) var topScores: [GameID: HighScore] = [:]
    @Published private(set) var isLoading = false

    func loadTopScores(using service: HighScoreService) async {
        isLoading = true
        defer { isLoading = false }

        var result: [GameID: HighScore] = [:]
        for game in GameID.allCases {
            if let best = try? await service.topScore(for: game) {
                result[game] = best
            }
        }
        topScores = result
    }
}
