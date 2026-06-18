//
//  ConnectFourBoard.swift
//  Arcade Mix
//
//  Pure value-type model for a Connect 4 game. No UIKit / SpriteKit — just the 7×6
//  grid, move legality, and win/draw detection. Shared by the view model (one live
//  game) and the AI (many hypothetical look-ahead boards), so it stays cheap to copy
//  and offers an O(1)-per-move win check for the search.
//

import Foundation

/// A playing piece. Raw values are stable and used by the AI's scoring.
enum Disc: Int {
    case red = 1
    case yellow = 2

    /// The other player.
    var opponent: Disc { self == .red ? .yellow : .red }
}

/// A single board square, addressed by `column` (0 = left) and `row` (0 = bottom).
struct Cell: Hashable {
    let column: Int
    let row: Int
}

/// A 7-wide, 6-tall Connect 4 board. Bottom row is `row == 0`; pieces fall to the
/// lowest empty square in a column.
struct ConnectFourBoard {
    static let columns = 7
    static let rows = 6

    /// Row-major grid (`row * columns + column`); `nil` is an empty square.
    private(set) var cells: [Disc?]
    /// Number of pieces in each column — the next drop lands at this row.
    private(set) var heights: [Int]
    /// Total pieces placed; the board is full (a draw if no winner) at `columns * rows`.
    private(set) var moveCount = 0

    init() {
        cells = Array(repeating: nil, count: Self.columns * Self.rows)
        heights = Array(repeating: 0, count: Self.columns)
    }

    private func index(column: Int, row: Int) -> Int { row * Self.columns + column }

    /// The piece at a square, or `nil` if empty / out of bounds.
    func disc(column: Int, row: Int) -> Disc? {
        guard column >= 0, column < Self.columns, row >= 0, row < Self.rows else { return nil }
        return cells[index(column: column, row: row)]
    }

    /// Whether a piece can still be dropped into `column`.
    func canDrop(in column: Int) -> Bool {
        column >= 0 && column < Self.columns && heights[column] < Self.rows
    }

    /// Columns that still have room, left to right.
    var availableColumns: [Int] {
        (0..<Self.columns).filter { heights[$0] < Self.rows }
    }

    /// True once every square is filled.
    var isFull: Bool { moveCount == Self.columns * Self.rows }

    /// Drop `disc` into `column`. Returns the row it landed on, or `nil` if the column
    /// is full (no mutation in that case).
    @discardableResult
    mutating func drop(_ disc: Disc, in column: Int) -> Int? {
        guard canDrop(in: column) else { return nil }
        let row = heights[column]
        cells[index(column: column, row: row)] = disc
        heights[column] += 1
        moveCount += 1
        return row
    }

    /// Whether the piece just placed at (`column`, `row`) completes a line of four.
    /// Cheap: only the four directions through that one square are examined, so the AI
    /// can call it after every simulated drop.
    func isWinningMove(column: Int, row: Int) -> Bool {
        guard let disc = disc(column: column, row: row) else { return false }
        // (dx, dy) for horizontal, vertical, and the two diagonals.
        let directions = [(1, 0), (0, 1), (1, 1), (1, -1)]
        for (dx, dy) in directions {
            var count = 1
            count += run(from: column, row, dx: dx, dy: dy, disc: disc)
            count += run(from: column, row, dx: -dx, dy: -dy, disc: disc)
            if count >= 4 { return true }
        }
        return false
    }

    /// Number of consecutive `disc` squares stepping away from (`column`, `row`).
    private func run(from column: Int, _ row: Int, dx: Int, dy: Int, disc: Disc) -> Int {
        var count = 0
        var c = column + dx
        var r = row + dy
        while self.disc(column: c, row: r) == disc {
            count += 1
            c += dx
            r += dy
        }
        return count
    }

    /// The four (or more) cells of a completed line, for highlighting the win. Scans the
    /// whole board, so it's meant to be called once at game end — not inside the search.
    func winningCells() -> [Cell]? {
        let directions = [(1, 0), (0, 1), (1, 1), (1, -1)]
        for row in 0..<Self.rows {
            for column in 0..<Self.columns {
                guard let disc = disc(column: column, row: row) else { continue }
                for (dx, dy) in directions {
                    var line = [Cell(column: column, row: row)]
                    var c = column + dx
                    var r = row + dy
                    while self.disc(column: c, row: r) == disc {
                        line.append(Cell(column: c, row: r))
                        c += dx
                        r += dy
                    }
                    if line.count >= 4 { return line }
                }
            }
        }
        return nil
    }
}
