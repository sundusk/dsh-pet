import Foundation
import ImageIO
import SwiftUI

enum XiaoyuPlayback: Equatable {
    case loop
    case onceThenHold
}

/// 拖拽时使用原图独立的左右奔跑行。屏幕横坐标增加为向右，减少为向左。
enum XiaoyuDragDirection: Int, CaseIterable {
    case right = 0
    case left = 1

    static let frameCount = 8
    static let frameDuration: TimeInterval = 0.08
    static let movementThreshold: CGFloat = 2

    static func direction(
        forHorizontalDelta delta: CGFloat,
        threshold: CGFloat = movementThreshold
    ) -> XiaoyuDragDirection? {
        guard abs(delta) >= threshold else { return nil }
        return delta > 0 ? .right : .left
    }

    func frameIndex(elapsed: TimeInterval) -> Int {
        Int(max(0, elapsed) / Self.frameDuration) % Self.frameCount
    }
}

/// 小雨专用 8×8 图集的行协议。每格固定 192×208。
enum XiaoyuAnimation: String, CaseIterable {
    case disconnected
    case idle
    case waiting
    case authorizing
    case questioning
    case done
    case failed
    case wave

    static let waveRepeatCount = 2
    /// 以显示刷新率驱动帧切换，避免低频 Timeline 让离散精灵帧出现额外抖动。
    static let renderInterval: TimeInterval = 1.0 / 60.0

    var row: Int {
        switch self {
        case .disconnected: return 0
        case .idle: return 1
        case .waiting: return 2
        case .authorizing: return 3
        case .questioning: return 4
        case .done: return 5
        case .failed: return 6
        case .wave: return 7
        }
    }

    /// 原始分镜各行的角色拍摄尺度并不完全一致。这里以 idle 的脸部与身体比例为基准，
    /// 对整行动画使用同一个最近邻显示系数；禁止逐帧按包围盒填满，否则蹲坐和跳跃会产生缩放跳变。
    var displayScale: CGFloat {
        switch self {
        case .disconnected, .idle, .questioning:
            return 1.0
        case .waiting:
            return 0.97
        case .authorizing:
            return 0.95
        case .done:
            return 1.10
        case .failed:
            return 1.02
        case .wave:
            return 0.96
        }
    }

    var frameDurations: [TimeInterval] {
        switch self {
        case .disconnected:
            return [1.0]
        case .idle:
            // 两个闭眼帧各只停 0.12s，整轮约 4.7s。
            return [0.88, 0.88, 0.12, 0.88, 0.88, 0.12, 0.96]
        case .waiting:
            return Array(repeating: 0.20, count: 6)
        case .authorizing:
            return Array(repeating: 0.24, count: 6)
        case .questioning:
            return Array(repeating: 0.20, count: 6)
        case .done:
            return Array(repeating: 0.12, count: 5)
        case .failed:
            return Array(repeating: 0.16, count: 8)
        case .wave:
            return Array(repeating: 0.14, count: 4)
        }
    }

    var playback: XiaoyuPlayback {
        self == .failed ? .onceThenHold : .loop
    }

    var totalDuration: TimeInterval {
        frameDurations.reduce(0, +)
    }

    static var waveInteractionDuration: TimeInterval {
        wave.totalDuration * Double(waveRepeatCount)
    }

    static func animation(for mood: String) -> XiaoyuAnimation {
        switch mood {
        case "idle": return .idle
        case "waiting", "jumping": return .waiting
        case "authorizing": return .authorizing
        case "questioning": return .questioning
        case "done": return .done
        case "failed": return .failed
        default: return .disconnected
        }
    }

    static func isWaveActive(
        mood: String,
        interactionTriggeredAt: Date?,
        at date: Date
    ) -> Bool {
        guard mood == "idle", let interactionTriggeredAt else { return false }
        let elapsed = date.timeIntervalSince(interactionTriggeredAt)
        return elapsed >= 0 && elapsed < waveInteractionDuration
    }

    func frameIndex(elapsed: TimeInterval, frameCount: Int? = nil) -> Int {
        let count = frameCount ?? self.frameDurations.count
        var frameDurations = Array(self.frameDurations.prefix(count))
        if count > frameDurations.count, let duration = frameDurations.last {
            frameDurations += Array(repeating: duration, count: count - frameDurations.count)
        }
        let totalDuration = frameDurations.reduce(0, +)
        guard !frameDurations.isEmpty else { return 0 }
        let safeElapsed = max(0, elapsed)
        let position: TimeInterval
        switch playback {
        case .loop:
            position = totalDuration > 0
                ? safeElapsed.truncatingRemainder(dividingBy: totalDuration)
                : 0
        case .onceThenHold:
            if safeElapsed >= totalDuration { return frameDurations.count - 1 }
            position = safeElapsed
        }

        var boundary: TimeInterval = 0
        for (index, duration) in frameDurations.enumerated() {
            boundary += duration
            if position < boundary { return index }
        }
        return frameDurations.count - 1
    }
}

enum XiaoyuSpriteAtlasError: Error {
    case missingResource
    case unreadableImage
    case invalidDimensions(width: Int, height: Int)
    case invalidCell(row: Int, column: Int)
}

/// 图集只解码一次，并预先裁切 64 个固定格，避免 TimelineView 每帧重复解码或裁图。
struct XiaoyuSpriteAtlas {
    static let resourceName = "XiaoyuSprites"
    static let columns = 8
    static let rows = 8
    static let cellWidth = 192
    static let cellHeight = 208
    static let pixelWidth = columns * cellWidth
    static let pixelHeight = rows * cellHeight

    private let cells: [[CGImage]]

    init(bundle: Bundle = .main) throws {
        guard let resourceURL = bundle.url(forResource: Self.resourceName, withExtension: "png") else {
            throw XiaoyuSpriteAtlasError.missingResource
        }
        try self.init(resourceURL: resourceURL)
    }

    init(resourceURL: URL) throws {
        cells = try Self.decodeCells(resourceURL: resourceURL, rows: Self.rows)
    }

    static func decodeCells(resourceURL: URL, rows: Int) throws -> [[CGImage]] {
        guard let source = CGImageSourceCreateWithURL(resourceURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw XiaoyuSpriteAtlasError.unreadableImage
        }
        return try decodeCells(image: image, rows: rows)
    }

    static func decodeCells(image: CGImage, rows: Int) throws -> [[CGImage]] {
        let expectedHeight = rows * Self.cellHeight
        guard image.width == Self.pixelWidth, image.height == expectedHeight else {
            throw XiaoyuSpriteAtlasError.invalidDimensions(width: image.width, height: image.height)
        }

        var decodedRows: [[CGImage]] = []
        decodedRows.reserveCapacity(rows)
        for row in 0..<rows {
            var decodedCells: [CGImage] = []
            decodedCells.reserveCapacity(Self.columns)
            for column in 0..<Self.columns {
                let rect = CGRect(
                    x: column * Self.cellWidth,
                    y: row * Self.cellHeight,
                    width: Self.cellWidth,
                    height: Self.cellHeight
                )
                guard let cell = image.cropping(to: rect) else {
                    throw XiaoyuSpriteAtlasError.invalidCell(row: row, column: column)
                }
                decodedCells.append(cell)
            }
            decodedRows.append(decodedCells)
        }
        return decodedRows
    }

    func frame(for animation: XiaoyuAnimation, index: Int) -> CGImage? {
        guard animation.row < cells.count,
              index >= 0,
              index < animation.frameDurations.count,
              index < cells[animation.row].count else { return nil }
        return cells[animation.row][index]
    }
}

/// 原始图集 row 1/2 的无损裁切资源：向右、向左各 8 帧。
struct XiaoyuDragSpriteAtlas {
    static let resourceName = "XiaoyuDragSprites"
    static let rows = 2
    static let pixelWidth = XiaoyuSpriteAtlas.pixelWidth
    static let pixelHeight = rows * XiaoyuSpriteAtlas.cellHeight

    private let cells: [[CGImage]]

    init(bundle: Bundle = .main) throws {
        guard let resourceURL = bundle.url(forResource: Self.resourceName, withExtension: "png") else {
            throw XiaoyuSpriteAtlasError.missingResource
        }
        try self.init(resourceURL: resourceURL)
    }

    init(resourceURL: URL) throws {
        cells = try XiaoyuSpriteAtlas.decodeCells(resourceURL: resourceURL, rows: Self.rows)
    }

    func frame(for direction: XiaoyuDragDirection, index: Int) -> CGImage? {
        guard index >= 0, index < XiaoyuDragDirection.frameCount else { return nil }
        return cells[direction.rawValue][index]
    }
}

struct XiaoyuSpriteView: View {
    var skin: FloatingPetSkin = .xiaoyu
    let mood: String
    let color: Color
    let size: CGFloat
    let glowEnabled: Bool
    let interactionTriggeredAt: Date?
    let dragDirection: XiaoyuDragDirection?
    @ObservedObject private var petLibrary = CustomPetLibrary.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var stateStartedAt = Date()
    @State private var dragStartedAt = Date()

    private static let atlas = try? XiaoyuSpriteAtlas()
    private static let dragAtlas = try? XiaoyuDragSpriteAtlas()
    private static let xinzhizhuAtlas = try? CodexSpriteAtlas()

    private static let jingyuniangAtlas = try? CodexSpriteAtlas(
        resourceName: "JingyuniangSprites", fileExtension: "png", idleFrameCount: 6
    )

    private var codexAtlas: CodexSpriteAtlas? {
        switch skin {
        case .xinzhizhu: return Self.xinzhizhuAtlas
        case .jingyuniang: return Self.jingyuniangAtlas
        case .custom: return petLibrary.atlas(for: skin)
        default: return nil
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: XiaoyuAnimation.renderInterval, paused: reduceMotion)) { timeline in
            let selection = frameSelection(at: reduceMotion ? stateStartedAt : timeline.date)

            ZStack(alignment: .bottom) {
                if glowEnabled {
                    Ellipse()
                        .fill(RadialGradient(
                            stops: [
                                .init(color: color.opacity(0.48), location: 0),
                                .init(color: color.opacity(0.20), location: 0.48),
                                .init(color: color.opacity(0.04), location: 0.78),
                                .init(color: color.opacity(0), location: 1),
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: size * 0.78
                        ))
                        .frame(width: size * 1.55, height: size * 1.55)
                }

                if let frame = selection.frame {
                    Image(decorative: frame, scale: 1, orientation: .up)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: size * CGFloat(XiaoyuSpriteAtlas.cellWidth) / CGFloat(XiaoyuSpriteAtlas.cellHeight), height: size)
                        .scaleEffect(selection.displayScale, anchor: .bottom)
                        .opacity(mood == "disconnected" ? 0.65 : 1)
                } else {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .font(.system(size: size * 0.5))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(
                width: size * (glowEnabled ? 1.55 : 0.95),
                height: size * (glowEnabled ? 1.55 : 1.10),
                alignment: .bottom
            )
        }
        .onChange(of: mood) {
            stateStartedAt = Date()
        }
        .onChange(of: skin) {
            stateStartedAt = Date()
            dragStartedAt = Date()
        }
        .onChange(of: dragDirection) {
            let now = Date()
            dragStartedAt = now
            if dragDirection == nil {
                stateStartedAt = now
            }
        }
    }

    private func frameSelection(at date: Date) -> (frame: CGImage?, displayScale: CGFloat) {
        if let dragDirection {
            let elapsed = date.timeIntervalSince(dragStartedAt)
            if skin != .xiaoyu {
                return (codexAtlas?.dragFrame(for: dragDirection, elapsed: elapsed), 1)
            }
            return (
                Self.dragAtlas?.frame(
                    for: dragDirection,
                    index: dragDirection.frameIndex(elapsed: elapsed)
                ),
                1
            )
        }

        let waveActive = XiaoyuAnimation.isWaveActive(
            mood: mood,
            interactionTriggeredAt: interactionTriggeredAt,
            at: date
        )
        let animation = waveActive ? XiaoyuAnimation.wave : XiaoyuAnimation.animation(for: mood)
        let elapsed = waveActive
            ? date.timeIntervalSince(interactionTriggeredAt ?? date)
            : date.timeIntervalSince(stateStartedAt)
        if skin != .xiaoyu {
            return (codexAtlas?.frame(for: animation, elapsed: elapsed), 1)
        }
        return (
            Self.atlas?.frame(for: animation, index: animation.frameIndex(elapsed: elapsed)),
            animation.displayScale
        )
    }
}
