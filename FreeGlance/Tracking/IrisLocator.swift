import CoreGraphics
import Foundation

/// Read-only view of an 8-bit luma plane, rows top to bottom.
struct LumaPlane {
    let base: UnsafePointer<UInt8>
    let width: Int
    let height: Int
    let bytesPerRow: Int

    subscript(x: Int, y: Int) -> UInt8 {
        base[y * bytesPerRow + x]
    }
}

/// Finds the iris inside one eye contour from image pixels instead of Vision's pupil landmark,
/// which follows the contour and barely moves with the eyes.
///
/// Eye frame: origin at the midpoint of the eye corners, unit = eye width (corner distance).
/// `x` + = towards the user's right (the image is unmirrored, so image-left), `y` + = up.
enum IrisLocator {
    enum Reading: Equatable {
        case open(CGPoint)
        case closed
    }

    /// Eye opening (contour height / width) below this counts as a blink.
    static let blinkOpening = 0.12
    /// Pixels up to this percentile of the masked eye pixels form the iris.
    static let darkPercentile = 0.3
    private static let padding = 2

    /// Eye frame spanned by the eye corners of `contour` (pixel coordinates, top-left origin).
    struct EyeFrame {
        let origin: CGPoint
        let axis: CGVector     // unit, points towards image +x
        let normal: CGVector   // unit, points image-up
        let width: Double
        let opening: Double

        init?(contour: [CGPoint]) {
            guard contour.count > 2 else { return nil }
            var a = contour[0], b = contour[1], best = -1.0
            for i in contour.indices {
                for j in contour.indices where j > i {
                    let d = hypot(contour[i].x - contour[j].x, contour[i].y - contour[j].y)
                    if d > best { best = d; a = contour[i]; b = contour[j] }
                }
            }
            guard best > 1 else { return nil }
            if b.x < a.x { swap(&a, &b) }
            let axis = CGVector(dx: (b.x - a.x) / best, dy: (b.y - a.y) / best)
            let normal = CGVector(dx: axis.dy, dy: -axis.dx)
            let origin = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let heights = contour.map { Double(($0.x - origin.x) * normal.dx + ($0.y - origin.y) * normal.dy) }
            self.origin = origin
            self.axis = axis
            self.normal = normal
            self.width = best
            self.opening = ((heights.max() ?? 0) - (heights.min() ?? 0)) / best
        }

        /// `p` (pixel coordinates) in the eye frame, mirrored to the user's view.
        func offset(of p: CGPoint) -> CGPoint {
            let dx = p.x - origin.x, dy = p.y - origin.y
            return CGPoint(x: -Double(dx * axis.dx + dy * axis.dy) / width,
                           y: Double(dx * normal.dx + dy * normal.dy) / width)
        }
    }

    /// Darkness-weighted centroid of the darkest pixels inside `contour`, in the eye frame.
    /// nil when the contour is degenerate or covers no pixels.
    static func locate(contour: [CGPoint], in plane: LumaPlane) -> Reading? {
        guard let frame = EyeFrame(contour: contour) else { return nil }
        guard frame.opening >= blinkOpening else { return .closed }
        guard let centre = darkCentroid(inside: contour, in: plane) else { return nil }
        return .open(frame.offset(of: centre))
    }

    private static func darkCentroid(inside polygon: [CGPoint], in plane: LumaPlane) -> CGPoint? {
        let xs = polygon.map(\.x), ys = polygon.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
        let x0 = max(Int(minX.rounded(.down)) - padding, 0), x1 = min(Int(maxX.rounded(.up)) + padding, plane.width - 1)
        let y0 = max(Int(minY.rounded(.down)) - padding, 0), y1 = min(Int(maxY.rounded(.up)) + padding, plane.height - 1)
        guard x0 < x1, y0 < y1 else { return nil }

        var inside: [(x: Int, y: Int, luma: Int)] = []
        var histogram = [Int](repeating: 0, count: 256)
        for y in y0...y1 {
            for x in x0...x1 where contains(polygon, CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) {
                let luma = Int(plane[x, y])
                inside.append((x, y, luma))
                histogram[luma] += 1
            }
        }
        guard !inside.isEmpty else { return nil }

        let rank = Double(inside.count) * darkPercentile
        var cumulative = 0
        var threshold = 255
        for (value, count) in histogram.enumerated() {
            cumulative += count
            if Double(cumulative) > rank {
                threshold = value
                break
            }
        }

        var sumW = 0.0, sumX = 0.0, sumY = 0.0
        for p in inside where p.luma <= threshold {
            let w = Double(threshold - p.luma + 1)
            sumW += w
            sumX += w * (Double(p.x) + 0.5)
            sumY += w * (Double(p.y) + 0.5)
        }
        return CGPoint(x: sumX / sumW, y: sumY / sumW)
    }

    /// Even-odd ray casting.
    private static func contains(_ polygon: [CGPoint], _ p: CGPoint) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}
