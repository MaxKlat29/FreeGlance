import CoreGraphics
import Foundation

/// Smooth-pursuit calibration path: a serpentine (boustrophedon) through a display, rows joined by
/// semicircles so the direction never changes abruptly. Parametrized by distance travelled in points.
struct PursuitPath: Sendable, Equatable {
    static let inset: CGFloat = 0.06

    private enum Segment: Sendable, Equatable {
        case line(from: CGPoint, to: CGPoint)
        /// Angles in radians; a negative sweep runs clockwise.
        case arc(centre: CGPoint, radius: Double, start: Double, sweep: Double)

        var length: Double {
            switch self {
            case let .line(from, to): hypot(Double(to.x - from.x), Double(to.y - from.y))
            case let .arc(_, radius, _, sweep): radius * abs(sweep)
            }
        }

        func point(at distance: Double) -> CGPoint {
            switch self {
            case let .line(from, to):
                let length = self.length
                let t = length > 0 ? distance / length : 0
                return CGPoint(x: Double(from.x) + t * Double(to.x - from.x), y: Double(from.y) + t * Double(to.y - from.y))
            case let .arc(centre, radius, start, sweep):
                let angle = start + (sweep < 0 ? -1 : 1) * distance / radius
                return CGPoint(x: Double(centre.x) + radius * cos(angle), y: Double(centre.y) + radius * sin(angle))
            }
        }
    }

    private let segments: [Segment]
    let length: Double

    var start: CGPoint { point(atDistance: 0) }

    /// `rows` horizontal rows from the top to the bottom of the 6-94 % box of `frame` (AppKit
    /// coordinates, y up). The first row starts at the box's left edge, turns touch the side edges.
    /// Tall displays get extra rows, so that two turns always fit into one row's width.
    static func serpentine(in frame: CGRect, rows: Int) -> PursuitPath {
        let box = frame.insetBy(dx: frame.width * inset, dy: frame.height * inset)
        let rows = max(rows, 2, Int((2 * box.height / max(box.width, 1)).rounded(.up)) + 1)
        let spacing = Double(box.height) / Double(rows - 1)
        let radius = spacing / 2
        let left = Double(box.minX), right = Double(box.maxX)
        var segments: [Segment] = []

        for row in 0..<rows {
            let y = Double(box.maxY) - Double(row) * spacing
            let rightward = row.isMultiple(of: 2)
            let startX = row == 0 ? left : (rightward ? left + radius : right - radius)
            let endX = row == rows - 1 ? (rightward ? right : left) : (rightward ? right - radius : left + radius)
            segments.append(.line(from: CGPoint(x: startX, y: y), to: CGPoint(x: endX, y: y)))
            guard row < rows - 1 else { break }
            // Semicircle down to the next row: clockwise on the right edge, counter-clockwise on the left.
            segments.append(.arc(centre: CGPoint(x: endX, y: y - radius), radius: radius,
                                 start: .pi / 2, sweep: rightward ? -.pi : .pi))
        }
        return PursuitPath(segments: segments)
    }

    private init(segments: [Segment]) {
        self.segments = segments
        length = segments.reduce(0) { $0 + $1.length }
    }

    /// Point after travelling `distance` points along the path, clamped to its ends.
    func point(atDistance distance: Double) -> CGPoint {
        var remaining = max(0, distance)
        for segment in segments {
            let length = segment.length
            if remaining <= length { return segment.point(at: remaining) }
            remaining -= length
        }
        guard let last = segments.last else { return .zero }
        return last.point(at: last.length)
    }
}
