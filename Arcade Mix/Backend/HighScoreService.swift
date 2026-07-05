//
//  HighScoreService.swift
//  Arcade Mix
//
//  Global high-score abstraction. Swap `LocalHighScoreService` for the Supabase-backed
//  implementation without changing callers.
//

import Foundation

protocol HighScoreService: AnyObject {
    /// Submit a score for a game and return the stored entry. `difficulty` scopes the score
    /// to a mode (e.g. Snake's "easy"); pass `nil` for single-mode games.
    @discardableResult
    func submit(score: Int, for gameID: GameID, difficulty: String?, user: AppUser) async throws -> HighScore

    /// Fetch the top scores for a game, highest first. When `difficulty` is non-nil the
    /// results are scoped to that mode; when `nil` they span every difficulty.
    func topScores(for gameID: GameID, difficulty: String?, limit: Int) async throws -> [HighScore]

    /// The given user's own best score for a game, if any. `difficulty` scopes as above.
    func personalBest(for gameID: GameID, difficulty: String?, userID: String) async throws -> HighScore?
}

// Convenience overloads that default `difficulty` to `nil`, so single-mode callers stay
// unchanged. (Swift forbids default argument values on protocol requirements themselves.)
extension HighScoreService {
    @discardableResult
    func submit(score: Int, for gameID: GameID, user: AppUser) async throws -> HighScore {
        try await submit(score: score, for: gameID, difficulty: nil, user: user)
    }

    func topScores(for gameID: GameID, limit: Int) async throws -> [HighScore] {
        try await topScores(for: gameID, difficulty: nil, limit: limit)
    }

    func personalBest(for gameID: GameID, userID: String) async throws -> HighScore? {
        try await personalBest(for: gameID, difficulty: nil, userID: userID)
    }

    /// Convenience: the single best score for a game, optionally scoped to a difficulty.
    /// With `difficulty: nil` this is the best across all modes (used by the hub tile).
    func topScore(for gameID: GameID, difficulty: String? = nil) async throws -> HighScore? {
        try await topScores(for: gameID, difficulty: difficulty, limit: 1).first
    }
}

/// On-device leaderboard persisted to `UserDefaults`, used until Supabase is configured.
/// Lets the hub show real, persistent high scores with no backend.
final class LocalHighScoreService: HighScoreService {
    private let defaultsKey = "arcademix.local.highScores"

    func submit(score: Int, for gameID: GameID, difficulty: String?, user: AppUser) async throws -> HighScore {
        let entry = HighScore(
            gameID: gameID.rawValue,
            userID: user.id,
            displayName: user.leaderboardName,
            score: score,
            createdAt: Date(),
            difficulty: difficulty
        )
        var all = load()
        all.append(entry)
        save(all)
        return entry
    }

    func topScores(for gameID: GameID, difficulty: String?, limit: Int) async throws -> [HighScore] {
        load()
            .filter { $0.gameID == gameID.rawValue && (difficulty == nil || $0.difficulty == difficulty) }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }

    func personalBest(for gameID: GameID, difficulty: String?, userID: String) async throws -> HighScore? {
        load()
            .filter { $0.gameID == gameID.rawValue && $0.userID == userID && (difficulty == nil || $0.difficulty == difficulty) }
            .max { $0.score < $1.score }
    }

    // MARK: - Persistence

    private func load() -> [HighScore] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return [] }
        return (try? JSONDecoder.highScore.decode([HighScore].self, from: data)) ?? []
    }

    private func save(_ scores: [HighScore]) {
        if let data = try? JSONEncoder.highScore.encode(scores) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

// Shared coders that handle the `Date` <-> ISO8601 representation consistently.
extension JSONEncoder {
    static var highScore: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    static var highScore: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
