//
//  SnakeViewModel.swift
//  Arcade Mix
//
//  Pure-SwiftUI Snake with difficulty tiers and a progression ladder. Foundation-only game
//  logic driving an ObservableObject — the View renders `snake`, `food`, `walls`, and
//  `score`, and feeds steering back in. The player picks a starting difficulty (Easy /
//  Medium / Hard); filling the whole grid completes the level and advances up a shared
//  ladder (Easy → Medium → Hard → Hard+ → …) with a bigger grid, more walls, and a steeper
//  speed ramp each step. The snake resets to its starting length each level, but the score
//  carries over and is always saved under the difficulty the player started on.
//  Colours / SF Symbols live in the View, mirroring the Connect 4 model/View split.
//

import Foundation
import Combine

/// The difficulty a player starts on. `rawValue` is the leaderboard key ("easy"/"medium"/
/// "hard"); progression beyond Hard climbs into procedural "Hard+" levels but scores stay
/// filed under the starting difficulty.
enum SnakeDifficulty: String, CaseIterable, Identifiable {
    case easy, medium, hard

    var id: String { rawValue }

    var titleKey: LocalizedStringResource {
        switch self {
        case .easy:   return "Snake_Difficulty_Easy"
        case .medium: return "Snake_Difficulty_Medium"
        case .hard:   return "Snake_Difficulty_Hard"
        }
    }

    /// Where this difficulty sits on the shared stage ladder.
    var entryStage: Int {
        switch self {
        case .easy:   return 0
        case .medium: return 1
        case .hard:   return 2
        }
    }
}

@MainActor
final class SnakeViewModel: ObservableObject {

    /// A grid cell. Origin is top-left: x grows right, y grows down.
    struct Point: Equatable {
        let x: Int
        let y: Int
    }

    enum Direction {
        case up, down, left, right

        /// The step this direction adds to the head each tick.
        var delta: Point {
            switch self {
            case .up:    return Point(x: 0, y: -1)
            case .down:  return Point(x: 0, y: 1)
            case .left:  return Point(x: -1, y: 0)
            case .right: return Point(x: 1, y: 0)
            }
        }

        var opposite: Direction {
            switch self {
            case .up:    return .down
            case .down:  return .up
            case .left:  return .right
            case .right: return .left
            }
        }
    }

    // MARK: - Level configuration

    /// The tuning for a single level of the ladder.
    struct LevelConfig {
        let columns: Int
        let rows: Int
        let startLength: Int
        let baseInterval: TimeInterval   // slow & relaxed at the start of a level
        let minInterval: TimeInterval    // fastest the snake ever moves
        let decrement: TimeInterval      // shaved off per extra segment — steeper = harder
        let initialWallPieces: Int       // straight wall segments placed at level start
        let growsWalls: Bool             // Hard+: a new wall spawns every few fruit
    }

    /// Builds the config for a ladder stage. Stage 0 = Easy, 1 = Medium, 2 = Hard, and each
    /// stage ≥ 3 is a procedural "Hard+n": bigger grid, more starting walls, steeper ramp.
    static func levelConfig(forStage stage: Int) -> LevelConfig {
        switch stage {
        case 0:  // Easy — small board, no walls, very gentle ramp.
            return LevelConfig(columns: 11, rows: 15, startLength: 3,
                               baseInterval: 0.34, minInterval: 0.12, decrement: 0.003,
                               initialWallPieces: 0, growsWalls: false)
        case 1:  // Medium — the classic board with a scattering of static walls.
            return LevelConfig(columns: 15, rows: 21, startLength: 3,
                               baseInterval: 0.34, minInterval: 0.11, decrement: 0.006,
                               initialWallPieces: 8, growsWalls: false)
        case 2:  // Hard — larger board, fewer starting walls that grow into a maze.
            return LevelConfig(columns: 19, rows: 25, startLength: 3,
                               baseInterval: 0.34, minInterval: 0.10, decrement: 0.009,
                               initialWallPieces: 3, growsWalls: true)
        default: // Hard+n — keep scaling up.
            let n = stage - 2
            return LevelConfig(columns: 19 + 2 * n, rows: 25 + 2 * n, startLength: 3,
                               baseInterval: 0.34, minInterval: 0.09, decrement: 0.009 + 0.002 * Double(n),
                               initialWallPieces: 3 + n, growsWalls: true)
        }
    }

    // MARK: - Published state

    /// Current board size (varies per level, so no longer a compile-time constant).
    @Published private(set) var columns = 11
    @Published private(set) var rows = 15

    @Published private(set) var snake: [Point] = []   // head first
    @Published private(set) var direction: Direction = .up
    @Published private(set) var food = Point(x: 0, y: 0)
    @Published private(set) var walls: [Point] = []
    @Published private(set) var score = 0
    @Published private(set) var isGameOver = false
    @Published private(set) var isLevelComplete = false
    @Published private(set) var isPaused = false

    /// Hidden debug mode (toggled from the difficulty-select screen). When on, the board
    /// auto-feeds every second, food grows the snake by 5, and the speed never ramps — a
    /// fast way to test level progression. It never touches the score or the leaderboard.
    @Published private(set) var isDebug = false

    /// The difficulty the run started on — the key every score for this run is saved under.
    private(set) var startingDifficulty: SnakeDifficulty = .easy
    /// Current position on the shared stage ladder.
    private(set) var stage = 0

    /// A short label for the current level: "Easy", "Medium", "Hard", "Hard+", …
    var levelLabel: String { Self.label(forStage: stage) }

    /// The label for the level reached after completing this one.
    var nextLevelLabel: String { Self.label(forStage: stage + 1) }

    static func label(forStage stage: Int) -> String {
        switch stage {
        case 0:  return String(localized: SnakeDifficulty.easy.titleKey)
        case 1:  return String(localized: SnakeDifficulty.medium.titleKey)
        default:
            let base = String(localized: SnakeDifficulty.hard.titleKey)
            return base + String(repeating: "+", count: max(0, stage - 2))
        }
    }

    // MARK: - Tuning / internal state

    private let pointsPerFood = 10
    private var config = SnakeViewModel.levelConfig(forStage: 0)
    private var wallSet: Set<CellKey> = []
    private var fruitEaten = 0
    private var nextWallAt = 0

    /// Segments still owed to the snake from recent feeding (grows one cell per tick until
    /// spent). Lets a single pellet grow the snake by more than one — 5 in debug mode.
    private var growthRemaining = 0
    private var growthPerFood: Int { isDebug ? 5 : 1 }
    /// Debug-only timer that auto-feeds the snake once a second.
    private var debugTask: Task<Void, Never>?

    /// The next direction to apply — buffered so a mid-tick input can't reverse the snake
    /// into itself, and only one turn is honoured per tick.
    private var pendingDirection: Direction = .up
    private var loopTask: Task<Void, Never>?

    /// Current tick length: slower when short, easing toward `minInterval` as it grows.
    /// Debug mode pins it to the level's base speed so the ramp never kicks in.
    private var currentInterval: TimeInterval {
        if isDebug { return config.baseInterval }
        return max(config.minInterval, config.baseInterval - Double(snake.count - config.startLength) * config.decrement)
    }

    // MARK: - Lifecycle

    /// Start a fresh run at the given difficulty. Safe to call again to restart.
    /// `debug` enables the hidden progression-testing mode for the whole run.
    func beginGame(difficulty: SnakeDifficulty, debug: Bool = false) {
        stop()
        isDebug = debug
        startingDifficulty = difficulty
        stage = difficulty.entryStage
        score = 0
        isGameOver = false
        setupLevel()
        runLoop()
    }

    /// Advance to the next level after filling the grid — bigger board, more walls, faster.
    /// The score carries over; the snake resets to its starting length.
    func advanceLevel() {
        guard isLevelComplete else { return }
        stop()
        stage += 1
        setupLevel()
        runLoop()
    }

    /// Restart the run from the starting difficulty's first level, score reset. Keeps the
    /// current debug mode so a retry stays in the same mode.
    func restart() {
        beginGame(difficulty: startingDifficulty, debug: isDebug)
    }

    /// Cancel the tick loop (on disappear, game over, level complete, or before a restart).
    func stop() {
        loopTask?.cancel()
        loopTask = nil
        debugTask?.cancel()
        debugTask = nil
    }

    /// Freeze the game: cancel the tick loop but keep all state so `resume()` can pick up
    /// exactly where it left off.
    func pause() {
        guard !isGameOver, !isLevelComplete, !isPaused else { return }
        isPaused = true
        loopTask?.cancel()
        loopTask = nil
        debugTask?.cancel()
        debugTask = nil
    }

    /// Resume ticking after a pause, without resetting the board.
    func resume() {
        guard isPaused, !isGameOver, !isLevelComplete else { return }
        isPaused = false
        runLoop()
    }

    private func runLoop() {
        loopTask = Task { [weak self] in await self?.run() }
        if isDebug {
            debugTask = Task { [weak self] in await self?.runDebugFeed() }
        }
    }

    deinit {
        loopTask?.cancel()
        debugTask?.cancel()
    }

    /// Build the current level: size the board, centre the snake, place walls, drop the
    /// first pellet. Leaves `score` untouched so it accumulates across levels.
    private func setupLevel() {
        config = Self.levelConfig(forStage: stage)
        columns = config.columns
        rows = config.rows

        // Centre the snake, stacked vertically, heading up into open space.
        let midX = columns / 2
        let midY = rows / 2
        snake = (0..<config.startLength).map { Point(x: midX, y: midY + $0) }
        direction = .up
        pendingDirection = .up

        generateInitialWalls()
        fruitEaten = 0
        nextWallAt = Int.random(in: 3...5)
        growthRemaining = 0
        isLevelComplete = false
        isPaused = false
        _ = spawnFood()
    }

    private func run() async {
        while !isGameOver && !isLevelComplete {
            try? await Task.sleep(for: .seconds(currentInterval))
            if Task.isCancelled { return }
            step()
        }
    }

    /// Debug mode: once a second, respawn the pellet and grow the snake — a hands-off way
    /// to march toward filling the grid and exercising level progression.
    private func runDebugFeed() async {
        while !isGameOver && !isLevelComplete {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return }
            autoFeed()
        }
    }

    private func autoFeed() {
        guard isDebug, !isGameOver, !isLevelComplete, !isPaused else { return }
        growthRemaining += growthPerFood
        if !spawnFood() { levelComplete() }   // no free cell left → grid filled
    }

    // MARK: - Input

    /// Queue a turn for the next tick, ignoring a 180° reversal into the snake's neck.
    func setDirection(_ new: Direction) {
        guard !isGameOver, !isLevelComplete, !isPaused else { return }
        if new == direction.opposite { return }
        pendingDirection = new
    }

    // MARK: - Simulation

    private func step() {
        direction = pendingDirection

        guard let head = snake.first else { return }
        let next = Point(x: head.x + direction.delta.x, y: head.y + direction.delta.y)

        // Boundary collision.
        if next.x < 0 || next.x >= columns || next.y < 0 || next.y >= rows {
            gameOver()
            return
        }

        // Wall collision.
        if wallSet.contains(CellKey(next)) {
            gameOver()
            return
        }

        let ate = next == food
        // Self collision. The tail cell frees up this tick unless we're growing (eating or
        // still owed growth), so it's fair game only when the tail will move on.
        let growing = ate || growthRemaining > 0
        let body = growing ? snake : snake.dropLast()
        if body.contains(next) {
            gameOver()
            return
        }

        snake.insert(next, at: 0)
        if ate {
            if !isDebug { score += pointsPerFood }   // debug never touches the score
            // This tick already added one segment; owe the rest of the pellet's growth.
            growthRemaining += growthPerFood - 1
            // Fill the whole grid → level complete; otherwise drop the next pellet, then
            // (on Hard+) grow the maze near neither the new food nor the head.
            if !spawnFood() {
                levelComplete()
                return
            }
            if config.growsWalls {
                fruitEaten += 1
                if fruitEaten >= nextWallAt {
                    if let piece = makeWallPiece(headBuffer: 3, avoidFood: food, snakeClearance: 0) {
                        addWall(piece)
                    }
                    nextWallAt = fruitEaten + Int.random(in: 3...5)
                }
            }
        } else if growthRemaining > 0 {
            growthRemaining -= 1   // consume owed growth: keep the tail this tick
        } else {
            snake.removeLast()
        }
    }

    private func gameOver() {
        isGameOver = true
        stop()
    }

    private func levelComplete() {
        isLevelComplete = true
        stop()
    }

    /// Place the pellet on a random free cell, keeping clear of walls where possible.
    /// Returns `false` only when no free cell remains — i.e. the snake has filled the grid.
    @discardableResult
    private func spawnFood() -> Bool {
        var occupied = Set(snake.map { CellKey($0) })
        occupied.formUnion(wallSet)

        var free: [Point] = []
        for y in 0..<rows {
            for x in 0..<columns {
                let p = Point(x: x, y: y)
                if !occupied.contains(CellKey(p)) { free.append(p) }
            }
        }
        guard !free.isEmpty else { return false }   // board full = level complete

        // Prefer cells more than 3 away from any wall ("no food within 3 of walls");
        // fall back to any free cell once the maze leaves no buffered spot.
        let buffered = free.filter { p in !walls.contains(where: { chebyshev($0, p) <= 3 }) }
        food = (buffered.isEmpty ? free : buffered).randomElement()!
        return true
    }

    // MARK: - Walls

    /// Place the level's starting walls, giving the freshly-centred snake room to move.
    private func generateInitialWalls() {
        walls = []
        wallSet = []
        guard config.initialWallPieces > 0 else { return }
        for _ in 0..<config.initialWallPieces {
            if let piece = makeWallPiece(headBuffer: nil, avoidFood: nil, snakeClearance: 2) {
                addWall(piece)
            }
        }
    }

    private func addWall(_ cells: [Point]) {
        walls.append(contentsOf: cells)
        for c in cells { wallSet.insert(CellKey(c)) }
    }

    /// Try to build one straight wall segment (length 1–3, horizontal or vertical) that
    /// clears the snake, existing walls, and the given buffers. Returns `nil` if no valid
    /// placement is found within a bounded number of attempts (board too crowded).
    /// - Parameters:
    ///   - headBuffer: reject cells within this Chebyshev distance of the head (nil = skip).
    ///   - avoidFood: reject cells within 3 of this cell (nil = skip).
    ///   - snakeClearance: reject cells within this Chebyshev distance of any snake segment.
    private func makeWallPiece(headBuffer: Int?, avoidFood: Point?, snakeClearance: Int) -> [Point]? {
        for _ in 0..<40 {
            let length = Int.random(in: 1...3)
            let horizontal = Bool.random()
            let ox = Int.random(in: 0..<columns)
            let oy = Int.random(in: 0..<rows)

            var cells: [Point] = []
            for i in 0..<length {
                cells.append(horizontal ? Point(x: ox + i, y: oy) : Point(x: ox, y: oy + i))
            }

            // In bounds.
            if cells.contains(where: { $0.x < 0 || $0.x >= columns || $0.y < 0 || $0.y >= rows }) { continue }
            // No overlap with existing walls.
            if cells.contains(where: { wallSet.contains(CellKey($0)) }) { continue }
            // Snake clearance.
            if cells.contains(where: { c in snake.contains(where: { chebyshev($0, c) <= snakeClearance }) }) { continue }
            // Head buffer.
            if let headBuffer, let head = snake.first,
               cells.contains(where: { chebyshev($0, head) <= headBuffer }) { continue }
            // Food buffer.
            if let avoidFood, cells.contains(where: { chebyshev($0, avoidFood) <= 3 }) { continue }

            return cells
        }
        return nil
    }

    /// Chebyshev (king-move) distance — a cell is "within 3 squares" when this is ≤ 3.
    private func chebyshev(_ a: Point, _ b: Point) -> Int {
        max(abs(a.x - b.x), abs(a.y - b.y))
    }

    /// Hashable key for occupancy lookups (Point stays a plain Equatable value type).
    private struct CellKey: Hashable {
        let x, y: Int
        init(_ p: Point) { x = p.x; y = p.y }
    }
}
