//
//  BrickGrid.swift
//  Arcade Mix
//
//  Pure value-type model for a Brick Breaker layout — no SpriteKit. Owns the
//  row/column matrix, the staged-difficulty generator, the colour-chain flood-fill,
//  and hit resolution. The scene renders this and keeps a parallel map of nodes, so
//  game logic stays testable and separate from drawing (the same split Connect 4 uses
//  with `ConnectFourBoard`). Coordinates are logical and never change while bricks
//  "crunch" down — that's a render-only offset of the container.
//
//  Row 0 is the TOP row; the bottom-most occupied row is the one that threatens the
//  paddle as the layout descends.
//

import Foundation

/// A grid address. `row` 0 = top.
struct BrickCoord: Hashable {
    let row: Int
    let col: Int
}

/// One brick in the matrix.
struct Brick {
    let type: BrickType
    var color: BrickColor          // drives colour-chain matching (and render tint)
    var hitsRemaining: Int
    let maxHits: Int

    /// Titanium is permanent; everything else can be cleared.
    var isBreakable: Bool { type != .titanium }
    /// Only plain `basic` bricks link in the colour-chain reaction.
    var isChainable: Bool { type == .basic }
}

/// Result of a ball striking a slot, for the scene to render.
enum BrickHitOutcome {
    case empty                 // nothing there
    case indestructible        // titanium — ball just bounces
    case damaged(Brick)        // strong brick survived; carries its updated state
    case destroyed(Brick)      // brick removed; carries its data (type/colour for effects + score)
}

struct BrickGrid {

    let columns: Int
    private(set) var rows: Int
    /// `[row][col]`, `nil` = empty slot. Row 0 is the top.
    private(set) var slots: [[Brick?]]

    private init(columns: Int, rows: Int, slots: [[Brick?]]) {
        self.columns = columns
        self.rows = rows
        self.slots = slots
    }

    // MARK: - Access

    /// The brick at a coord, or `nil` if empty / out of bounds (mirrors
    /// `ConnectFourBoard.disc(column:row:)`).
    func brick(row: Int, col: Int) -> Brick? {
        guard row >= 0, row < rows, col >= 0, col < columns else { return nil }
        return slots[row][col]
    }

    func brick(at coord: BrickCoord) -> Brick? { brick(row: coord.row, col: coord.col) }

    /// Every occupied coord (top-to-bottom, left-to-right).
    var occupiedCoords: [BrickCoord] {
        var result: [BrickCoord] = []
        for r in 0..<rows {
            for c in 0..<columns where slots[r][c] != nil {
                result.append(BrickCoord(row: r, col: c))
            }
        }
        return result
    }

    /// True once no breakable brick remains (titanium is ignored, so a wall of titanium
    /// still counts as "cleared" and the level advances).
    var isCleared: Bool {
        !occupiedCoords.contains { slots[$0.row][$0.col]?.isBreakable == true }
    }

    /// The largest row index that still holds a brick (the leading edge of the descent),
    /// or `nil` if empty. Used with the container offset to test the crunch game-over.
    var lowestOccupiedRow: Int? {
        for r in stride(from: rows - 1, through: 0, by: -1) {
            if (0..<columns).contains(where: { slots[r][$0] != nil }) { return r }
        }
        return nil
    }

    // MARK: - Mutation

    mutating func removeBrick(at coord: BrickCoord) {
        guard brick(at: coord) != nil else { return }
        slots[coord.row][coord.col] = nil
    }

    /// Resolve a hit on `coord`: strong bricks lose one hit (and shift colour state);
    /// everything breakable else is destroyed; titanium is unharmed.
    mutating func hit(at coord: BrickCoord) -> BrickHitOutcome {
        guard var b = brick(at: coord) else { return .empty }
        switch b.type {
        case .titanium:
            return .indestructible
        case .strong:
            b.hitsRemaining -= 1
            if b.hitsRemaining <= 0 {
                slots[coord.row][coord.col] = nil
                return .destroyed(b)
            }
            // Shift colour state so progress reads visually.
            b.color = b.color.next
            slots[coord.row][coord.col] = b
            return .damaged(b)
        case .basic, .hazard, .powerup:
            slots[coord.row][coord.col] = nil
            return .destroyed(b)
        }
    }

    // MARK: - Colour-chain flood fill

    /// 4-neighbour flood fill (up/down/left/right) from `start`, collecting every
    /// connected **chainable** brick of the *exact* same colour — including the start.
    /// This is the colour-chain reaction; pass each returned coord to `removeBrick`.
    /// Returns an empty array if the start isn't a chainable brick.
    func floodFillSameColor(from start: BrickCoord) -> [BrickCoord] {
        guard let origin = brick(at: start), origin.isChainable else { return [] }
        let target = origin.color
        var found: [BrickCoord] = []
        var seen: Set<BrickCoord> = []
        var stack: [BrickCoord] = [start]

        while let coord = stack.popLast() {
            guard !seen.contains(coord) else { continue }
            guard let b = brick(at: coord), b.isChainable, b.color == target else { continue }
            seen.insert(coord)
            found.append(coord)
            stack.append(BrickCoord(row: coord.row - 1, col: coord.col))
            stack.append(BrickCoord(row: coord.row + 1, col: coord.col))
            stack.append(BrickCoord(row: coord.row, col: coord.col - 1))
            stack.append(BrickCoord(row: coord.row, col: coord.col + 1))
        }
        return found
    }

    // MARK: - Staged-difficulty generation

    /// Build a fresh layout for the given difficulty using the 3-phase engine.
    /// `difficultyFactor` starts at 0.1 (level 1) and rises 0.1 per cleared level.
    static func generate(difficultyFactor: CGFloat, columns: Int, maxRows: Int) -> BrickGrid {
        let f = difficultyFactor
        let rowCount = min(maxRows, 5 + Int((f - 0.1) * 10))      // 5 rows at lvl 1 → maxRows
        let fill = BrickDifficulty.fillRate(f)
        let strong = BrickDifficulty.strongChance(f)
        let titanium = BrickDifficulty.titaniumChance(f)
        let powerUp = BrickDifficulty.powerUpRate(f)
        let hazard = BrickDifficulty.hazardChance(f)

        var slots = Array(repeating: Array<Brick?>(repeating: nil, count: columns), count: rowCount)
        for r in 0..<rowCount {
            for c in 0..<columns {
                guard CGFloat.random(in: 0...1) < fill else { continue }
                slots[r][c] = makeBrick(strong: strong, titanium: titanium,
                                        powerUp: powerUp, hazard: hazard,
                                        factor: f)
            }
        }
        // Guarantee a non-empty, clearable layout (every breakable brick could, in theory,
        // be all-titanium on a bad roll — seed one basic brick if so).
        var grid = BrickGrid(columns: columns, rows: rowCount, slots: slots)
        if grid.isCleared {
            grid.slots[0][columns / 2] = Brick(type: .basic, color: .allCases.randomElement()!,
                                               hitsRemaining: 1, maxHits: 1)
        }
        return grid
    }

    /// Pick a brick type for one slot. Structural type (titanium / strong / basic) is
    /// rolled first so the armour focus is preserved; a basic slot may then become a
    /// hazard or power-up variant (both 1-hit), governed by the staged rates.
    private static func makeBrick(strong: CGFloat, titanium: CGFloat,
                                  powerUp: CGFloat, hazard: CGFloat,
                                  factor: CGFloat) -> Brick {
        let color = BrickColor.allCases.randomElement()!
        let roll = CGFloat.random(in: 0...1)
        if roll < titanium {
            return Brick(type: .titanium, color: color, hitsRemaining: 1, maxHits: 1)
        }
        if roll < titanium + strong {
            let hits = BrickDifficulty.strongHits(factor)
            return Brick(type: .strong, color: color, hitsRemaining: hits, maxHits: hits)
        }
        // Basic-tier slot: may be a hazard or a power-up dropper.
        let variant = CGFloat.random(in: 0...1)
        if variant < hazard {
            return Brick(type: .hazard, color: .red, hitsRemaining: 1, maxHits: 1)
        }
        if variant < hazard + powerUp {
            return Brick(type: .powerup, color: color, hitsRemaining: 1, maxHits: 1)
        }
        return Brick(type: .basic, color: color, hitsRemaining: 1, maxHits: 1)
    }
}

/// The staged-difficulty curves, isolated so they're easy to read and unit-test.
/// `f` is the `difficultyFactor` (0.1 = level 1, +0.1 per level).
enum BrickDifficulty {
    /// Phase 1 (Density): ramp slot fill from ~0.50 up to the 0.85 ceiling by factor 0.3.
    static func fillRate(_ f: CGFloat) -> CGFloat {
        min(0.85, 0.50 + max(0, f - 0.1) * 1.75)
    }

    /// Phase 2 (Armour): strong bricks stay at 0% through phase 1, then mutate in from 0.4.
    static func strongChance(_ f: CGFloat) -> CGFloat {
        f <= 0.3 ? 0 : min(0.6, (f - 0.3) * 1.0)
    }

    /// Occasional indestructible titanium, introduced alongside the armour phase.
    static func titaniumChance(_ f: CGFloat) -> CGFloat {
        f < 0.4 ? 0 : min(0.15, (f - 0.4) * 0.3)
    }

    /// Strong bricks get tougher once difficulty plateaus.
    static func strongHits(_ f: CGFloat) -> Int { f >= 0.7 ? 3 : 2 }

    /// A small, steady sprinkle of hazard bricks throughout.
    static let hazardChance: CGFloat = 0.08
    static func hazardChance(_ f: CGFloat) -> CGFloat { hazardChance }

    /// Phase 3 (Scarcity): generous 0.70 through phases 1–2, then squeezed by the brief's
    /// exact formula once past factor 0.6.
    static func powerUpRate(_ f: CGFloat) -> CGFloat {
        f <= 0.6 ? 0.70 : max(0.15, 0.70 - (f - 0.6) * 1.5)
    }
}

private extension BrickColor {
    /// Next colour in the cycle — used to show a strong brick's damage state per hit.
    var next: BrickColor {
        let all = BrickColor.allCases
        let i = all.firstIndex(of: self) ?? 0
        return all[(i + 1) % all.count]
    }
}
