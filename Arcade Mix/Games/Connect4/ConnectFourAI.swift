//
//  ConnectFourAI.swift
//  Arcade Mix
//
//  The computer opponent. Four strengths: Easy plays a fast win/block + biased-random
//  policy; Medium/Hard/Impossible run negamax with alpha-beta pruning at increasing
//  depth. `bestMove` hops onto a detached task so the (potentially deep) search never
//  blocks the main actor / UI.
//

import Foundation

/// AI strength, chosen on the Connect 4 mode screen. `rawValue` is stable for storing
/// per-difficulty stats.
enum Difficulty: String, CaseIterable, Identifiable {
    case easy
    case medium
    case hard
    case impossible

    var id: String { rawValue }

    /// Max look-ahead depth for the minimax tiers. `easy` ignores this (it uses the
    /// heuristic policy instead). Impossible's cap is high because iterative deepening
    /// stops it on the clock (`timeBudget`), not the depth, so it never stalls.
    var searchDepth: Int {
        switch self {
        case .easy: return 0
        case .medium: return 4
        case .hard: return 6
        case .impossible: return 14
        }
    }

    /// Wall-clock budget for the search. The lower tiers finish their fixed depth long
    /// before this; Impossible is bounded by it so a move always lands within ~1s.
    var timeBudget: TimeInterval {
        switch self {
        case .easy: return 0
        case .medium, .hard: return 5      // generous — their shallow depth completes first
        case .impossible: return 0.8
        }
    }
}

/// Stateless move chooser for a given difficulty.
struct ConnectFourAI {
    let difficulty: Difficulty

    /// Columns explored center-out: better moves first, which sharpens alpha-beta pruning.
    private static let searchOrder = [3, 2, 4, 1, 5, 0, 6]

    private static let winScore = 1_000_000

    /// Choose a column for `disc`. Runs the search off the main actor.
    func bestMove(on board: ConnectFourBoard, for disc: Disc) async -> Int? {
        let difficulty = self.difficulty
        return await Task.detached(priority: .userInitiated) {
            Self.computeMove(on: board, for: disc, difficulty: difficulty)
        }.value
    }

    // MARK: - Move selection

    private static func computeMove(on board: ConnectFourBoard,
                                    for disc: Disc,
                                    difficulty: Difficulty) -> Int? {
        let columns = board.availableColumns
        guard !columns.isEmpty else { return nil }

        // Always grab an immediate win, and always block the opponent's immediate win —
        // true at every difficulty so the AI never misses a one-move tactic.
        if let win = immediateWin(on: board, for: disc) { return win }
        if let block = immediateWin(on: board, for: disc.opponent) { return block }

        if difficulty == .easy {
            return easyMove(among: columns, on: board, for: disc)
        }
        let deadline = Date().addingTimeInterval(difficulty.timeBudget)
        return searchMove(on: board, for: disc, maxDepth: difficulty.searchDepth, deadline: deadline)
    }

    /// A column where `disc` wins outright this move, if one exists.
    private static func immediateWin(on board: ConnectFourBoard, for disc: Disc) -> Int? {
        for column in board.availableColumns {
            var next = board
            if let row = next.drop(disc, in: column), next.isWinningMove(column: column, row: row) {
                return column
            }
        }
        return nil
    }

    /// Easy: avoid handing the opponent a win, then prefer central columns at random.
    private static func easyMove(among columns: [Int],
                                 on board: ConnectFourBoard,
                                 for disc: Disc) -> Int? {
        // Drop any move that would let the opponent win on their reply, when alternatives exist.
        let safe = columns.filter { column in
            var next = board
            next.drop(disc, in: column)
            return immediateWin(on: next, for: disc.opponent) == nil
        }
        let pool = safe.isEmpty ? columns : safe

        // Weight toward the centre (closer to column 3 = heavier) for slightly smarter feel.
        var bag: [Int] = []
        for column in pool {
            let weight = 4 - abs(column - 3)   // 4 at centre … 1 at the edges
            bag.append(contentsOf: repeatElement(column, count: max(1, weight)))
        }
        return bag.randomElement()
    }

    // MARK: - Minimax (iterative deepening + negamax + alpha-beta)

    /// Carries the time deadline through the recursion. The node counter keeps the (slightly
    /// costly) clock check to roughly once every few thousand nodes.
    private final class SearchContext {
        let deadline: Date
        var nodes = 0
        var timedOut = false
        init(deadline: Date) { self.deadline = deadline }

        func checkTime() {
            nodes += 1
            if nodes & 0x7FF == 0, Date() >= deadline { timedOut = true }
        }
    }

    /// Iterative deepening up to `maxDepth`, bounded by `deadline`: search depth 1, 2, 3 …
    /// and keep the best move from the deepest *completed* depth. A timed-out iteration is
    /// discarded, so the AI always returns within the budget instead of stalling.
    private static func searchMove(on board: ConnectFourBoard, for disc: Disc,
                                   maxDepth: Int, deadline: Date) -> Int? {
        // Fallback so there's always a move (depth-1 below normally replaces it instantly).
        var best = board.availableColumns.min(by: { abs($0 - 3) < abs($1 - 3) })
        let ctx = SearchContext(deadline: deadline)

        for depth in 1...maxDepth {
            let column = rootSearch(board, for: disc, depth: depth, ctx: ctx)
            if ctx.timedOut { break }             // incomplete — keep the previous depth's move
            if let column { best = column }
            if Date() >= deadline { break }
        }
        return best
    }

    /// Best column for `disc` at a fixed `depth`.
    private static func rootSearch(_ board: ConnectFourBoard, for disc: Disc,
                                   depth: Int, ctx: SearchContext) -> Int? {
        var bestColumn: Int?
        var bestScore = Int.min
        var alpha = Int.min + 1
        let beta = Int.max - 1

        for column in searchOrder where board.canDrop(in: column) {
            var next = board
            let row = next.drop(disc, in: column)!
            let score: Int
            if next.isWinningMove(column: column, row: row) {
                score = winScore + depth          // immediate win — can't be beaten
            } else {
                score = -negamax(next, depth: depth - 1, alpha: -beta, beta: -alpha, disc: disc.opponent, ctx: ctx)
            }
            if ctx.timedOut { break }
            if score > bestScore {
                bestScore = score
                bestColumn = column
            }
            alpha = max(alpha, score)
        }
        return bestColumn
    }

    /// Negamax value of `board` with `disc` to move, scored from `disc`'s perspective.
    private static func negamax(_ board: ConnectFourBoard,
                                depth: Int,
                                alpha: Int,
                                beta: Int,
                                disc: Disc,
                                ctx: SearchContext) -> Int {
        ctx.checkTime()
        if ctx.timedOut { return 0 }
        if board.isFull { return 0 }              // draw
        if depth == 0 { return heuristic(board, for: disc) }

        var alpha = alpha
        var value = Int.min + 1
        for column in searchOrder where board.canDrop(in: column) {
            var next = board
            let row = next.drop(disc, in: column)!
            let score: Int
            if next.isWinningMove(column: column, row: row) {
                score = winScore + depth          // prefer faster wins (deeper depth left)
            } else {
                score = -negamax(next, depth: depth - 1, alpha: -beta, beta: -alpha, disc: disc.opponent, ctx: ctx)
            }
            if ctx.timedOut { return value }
            value = max(value, score)
            alpha = max(alpha, value)
            if alpha >= beta { break }            // alpha-beta cutoff
        }
        return value
    }

    // MARK: - Heuristic evaluation

    /// Positional score of a non-terminal board from `player`'s point of view: positive is
    /// good for `player`. Sums every length-4 window plus a centre-column bonus.
    private static func heuristic(_ board: ConnectFourBoard, for player: Disc) -> Int {
        let cols = ConnectFourBoard.columns
        let rows = ConnectFourBoard.rows
        var score = 0

        // Centre control is worth a small steady bonus.
        let centre = cols / 2
        for row in 0..<rows {
            if board.disc(column: centre, row: row) == player { score += 3 }
            else if board.disc(column: centre, row: row) == player.opponent { score -= 3 }
        }

        let directions = [(1, 0), (0, 1), (1, 1), (1, -1)]
        for row in 0..<rows {
            for col in 0..<cols {
                for (dx, dy) in directions {
                    let endCol = col + 3 * dx
                    let endRow = row + 3 * dy
                    guard endCol >= 0, endCol < cols, endRow >= 0, endRow < rows else { continue }
                    score += windowScore(board, startCol: col, startRow: row, dx: dx, dy: dy, player: player)
                }
            }
        }
        return score
    }

    /// Score a single 4-cell window. Windows mixing both colours are dead (0).
    private static func windowScore(_ board: ConnectFourBoard,
                                    startCol: Int, startRow: Int,
                                    dx: Int, dy: Int,
                                    player: Disc) -> Int {
        var own = 0, opp = 0, empty = 0
        for step in 0..<4 {
            let cell = board.disc(column: startCol + step * dx, row: startRow + step * dy)
            switch cell {
            case player: own += 1
            case .some: opp += 1
            case nil: empty += 1
            }
        }
        if own > 0 && opp > 0 { return 0 }
        if own == 3, empty == 1 { return 5 }
        if own == 2, empty == 2 { return 2 }
        if opp == 3, empty == 1 { return -4 }
        if opp == 2, empty == 2 { return -2 }
        return 0
    }
}
