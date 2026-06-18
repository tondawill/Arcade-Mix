//
//  Connect4ViewModel.swift
//  Arcade Mix
//
//  Drives one Connect 4 session: mode selection → play → result. Owns the board, whose
//  turn it is, the coin-flip for the opening move, the AI hand-off, and recording the
//  final W/L/D. The human is always red in vs-AI games; in pass-and-play red is Player 1.
//

import SwiftUI
import Combine

@MainActor
final class Connect4ViewModel: ObservableObject {

    enum Phase {
        case modeSelect
        case playing
        case finished
    }

    // MARK: - Published state

    @Published private(set) var phase: Phase = .modeSelect
    @Published private(set) var board = ConnectFourBoard()
    @Published private(set) var currentPlayer: Disc = .red
    @Published private(set) var mode: GameMode?

    /// Which side moved first this game (coin-flip), shown as an opening banner.
    @Published private(set) var firstPlayer: Disc = .red
    /// The most recent drop, used by the view to animate the falling disc.
    @Published private(set) var lastDrop: Cell?

    /// Winner of a finished game, or `nil` for a draw.
    @Published private(set) var winner: Disc?
    @Published private(set) var isDraw = false
    /// Cells forming the winning line, highlighted at game end.
    @Published private(set) var winningCells: Set<Cell> = []

    /// True while the AI computes its move (disables input, shows a hint).
    @Published private(set) var isThinking = false

    /// The human's disc in vs-AI games. (Both sides are human in pass-and-play.)
    let humanDisc: Disc = .red
    private var aiDisc: Disc { humanDisc.opponent }

    /// Bumped each new game so a slow AI task from a previous game is ignored.
    private var gameGeneration = 0

    // MARK: - Derived

    /// Whether the local player may tap a column right now.
    var isHumanTurn: Bool {
        guard phase == .playing, !isThinking else { return false }
        switch mode {
        case .ai: return currentPlayer == humanDisc
        case .friend, .none: return true
        }
    }

    // MARK: - Game lifecycle

    /// Pick a mode (from the mode screen) and start the first game.
    func selectMode(_ mode: GameMode) {
        self.mode = mode
        startGame()
    }

    /// Reset the board and begin a new game in the current mode.
    func startGame() {
        guard mode != nil else { return }
        gameGeneration += 1
        board = ConnectFourBoard()
        winner = nil
        isDraw = false
        winningCells = []
        lastDrop = nil
        isThinking = false
        firstPlayer = Bool.random() ? .red : .yellow
        currentPlayer = firstPlayer
        phase = .playing

        // If the AI won the coin-flip, let it open.
        if case .ai = mode, currentPlayer == aiDisc {
            triggerAIMove()
        }
    }

    /// Play another game in the same mode (Rematch button).
    func rematch() {
        startGame()
    }

    /// Leave the current game and return to the mode picker.
    func exitToModeSelect() {
        gameGeneration += 1
        isThinking = false
        mode = nil
        phase = .modeSelect
    }

    // MARK: - Moves

    /// Handle a human tapping `column`.
    func dropColumn(_ column: Int) {
        guard isHumanTurn, board.canDrop(in: column) else { return }
        performDrop(in: column, disc: currentPlayer)
    }

    /// Place `disc` in `column`, then resolve win/draw and advance the turn (handing off
    /// to the AI if it's next to move).
    private func performDrop(in column: Int, disc: Disc) {
        guard let row = board.drop(disc, in: column) else { return }
        lastDrop = Cell(column: column, row: row)

        if board.isWinningMove(column: column, row: row) {
            winner = disc
            winningCells = Set(board.winningCells() ?? [])
            finish()
            return
        }
        if board.isFull {
            isDraw = true
            finish()
            return
        }

        currentPlayer = disc.opponent
        if case .ai = mode, currentPlayer == aiDisc {
            triggerAIMove()
        }
    }

    /// Ask the AI for a move on a background task, with a short minimum "thinking" beat so
    /// instant replies don't feel jarring. Stale results (from an abandoned game) are dropped.
    private func triggerAIMove() {
        guard case .ai(let difficulty)? = mode else { return }
        let ai = ConnectFourAI(difficulty: difficulty)
        let disc = aiDisc
        let snapshot = board
        let generation = gameGeneration
        isThinking = true

        Task {
            async let move = ai.bestMove(on: snapshot, for: disc)
            try? await Task.sleep(for: .milliseconds(400))
            let column = await move
            guard gameGeneration == generation, phase == .playing else { return }
            isThinking = false
            if let column {
                performDrop(in: column, disc: disc)
            }
        }
    }

    // MARK: - Finish

    private func finish() {
        phase = .finished
        guard let mode else { return }
        ConnectFourStats.shared.record(outcome(for: mode), for: mode)
    }

    /// Map the result to the device owner's perspective (red = human / Player 1).
    private func outcome(for mode: GameMode) -> GameOutcome {
        guard let winner else { return .draw }
        return winner == .red ? .win : .loss
    }
}
