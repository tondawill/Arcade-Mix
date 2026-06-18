//
//  ConnectFourStats.swift
//  Arcade Mix
//
//  Local, on-device win/loss/draw record for Connect 4. Kept per mode (each AI
//  difficulty and pass-and-play) so we can show breakdowns later, while the hub tile
//  shows the combined total. Persisted as JSON in `UserDefaults` — no backend; Connect 4
//  is offline-only in this phase.
//

import Foundation

/// How a Connect 4 game is being played. Drives the AI (if any) and the stats bucket.
enum GameMode: Equatable, Hashable {
    case ai(Difficulty)
    /// Local pass-and-play between two people on one device.
    case friend

    /// Stable key for persistence (e.g. "ai_hard", "friend").
    var storageKey: String {
        switch self {
        case .ai(let difficulty): return "ai_\(difficulty.rawValue)"
        case .friend: return "friend"
        }
    }
}

/// Result of a finished game, from the device owner's perspective. In pass-and-play the
/// owner is treated as Player 1 (the side that chose "vs Friend"); the coin-flip only
/// decides who moves first, not which seat is Player 1.
enum GameOutcome {
    case win
    case loss
    case draw
}

/// A win/loss/draw tally.
struct ConnectFourRecord: Codable, Equatable {
    var wins = 0
    var losses = 0
    var draws = 0

    var total: Int { wins + losses + draws }

    static func + (lhs: ConnectFourRecord, rhs: ConnectFourRecord) -> ConnectFourRecord {
        ConnectFourRecord(wins: lhs.wins + rhs.wins,
                          losses: lhs.losses + rhs.losses,
                          draws: lhs.draws + rhs.draws)
    }
}

/// Singleton store for the local Connect 4 record. Reads are cheap (the tile pulls a
/// fresh combined record each time the hub renders); writes persist immediately.
final class ConnectFourStats {
    static let shared = ConnectFourStats()

    private let defaultsKey = "connect4.records.v1"
    private let defaults: UserDefaults
    private var records: [String: ConnectFourRecord]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([String: ConnectFourRecord].self, from: data) {
            records = decoded
        } else {
            records = [:]
        }
    }

    /// The record for a single mode.
    func record(for mode: GameMode) -> ConnectFourRecord {
        records[mode.storageKey] ?? ConnectFourRecord()
    }

    /// Every mode's records summed — what the hub tile displays.
    func combinedRecord() -> ConnectFourRecord {
        records.values.reduce(ConnectFourRecord()) { $0 + $1 }
    }

    /// Apply a finished game's outcome to its mode and persist.
    func record(_ outcome: GameOutcome, for mode: GameMode) {
        var record = records[mode.storageKey] ?? ConnectFourRecord()
        switch outcome {
        case .win: record.wins += 1
        case .loss: record.losses += 1
        case .draw: record.draws += 1
        }
        records[mode.storageKey] = record
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: defaultsKey)
        }
    }
}
