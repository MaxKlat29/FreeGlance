import CoreGraphics
import XCTest
@testable import FreeGlance

final class IrisLocatorTests: XCTestCase {
    private let width = 200, height = 120
    private let centre = CGPoint(x: 100, y: 60)
    private let eyeWidth: CGFloat = 80

    func testFindsDarkDiscLeftOfCentreAsLookingRight() throws {
        // Image-left is the user's right (unmirrored camera); image-up is looking up.
        let reading = try locate(discAt: CGPoint(x: centre.x - 12, y: centre.y - 6))
        guard case .open(let offset) = reading else { return XCTFail("expected an open eye, got \(String(describing: reading))") }
        XCTAssertEqual(offset.x, 12 / eyeWidth, accuracy: 1 / eyeWidth)
        XCTAssertEqual(offset.y, 6 / eyeWidth, accuracy: 1 / eyeWidth)
    }

    func testFindsDarkDiscRightOfCentreAsLookingLeftAndDown() throws {
        let reading = try locate(discAt: CGPoint(x: centre.x + 15, y: centre.y + 5))
        guard case .open(let offset) = reading else { return XCTFail("expected an open eye, got \(String(describing: reading))") }
        XCTAssertEqual(offset.x, -15 / eyeWidth, accuracy: 1 / eyeWidth)
        XCTAssertEqual(offset.y, -5 / eyeWidth, accuracy: 1 / eyeWidth)
    }

    func testRejectsBlink() throws {
        XCTAssertEqual(try locate(discAt: centre, halfHeight: 4), .closed)
    }

    func testDarkestBinOverPercentileStillReadsOpen() throws {
        // Underexposed eye: more than 30 % of the masked pixels share the minimum luma.
        var pixels = [UInt8](repeating: 120, count: width * height)
        for y in 0..<height { for x in 0..<Int(centre.x) { pixels[y * width + x] = 10 } }
        let polygon = contour(halfHeight: 20)
        let reading = pixels.withUnsafeBufferPointer { buffer in
            IrisLocator.locate(contour: polygon,
                               in: LumaPlane(base: buffer.baseAddress!, width: width, height: height, bytesPerRow: width))
        }
        guard case .open(let offset) = reading else { return XCTFail("expected an open eye, got \(String(describing: reading))") }
        XCTAssertGreaterThan(offset.x, 0)
    }

    func testEyeFrameUsesCornersAndOpening() throws {
        let frame = try XCTUnwrap(IrisLocator.EyeFrame(contour: contour(halfHeight: 20)))
        XCTAssertEqual(frame.width, Double(eyeWidth), accuracy: 1e-9)
        XCTAssertEqual(frame.opening, 0.5, accuracy: 0.01)
        XCTAssertEqual(frame.origin.x, centre.x, accuracy: 1e-9)
        XCTAssertEqual(frame.origin.y, centre.y, accuracy: 1e-9)
    }

    private func locate(discAt disc: CGPoint, halfHeight: CGFloat = 20) throws -> IrisLocator.Reading? {
        var pixels = [UInt8](repeating: 220, count: width * height)
        let radius: CGFloat = 8
        for y in 0..<height {
            for x in 0..<width where hypot(CGFloat(x) + 0.5 - disc.x, CGFloat(y) + 0.5 - disc.y) <= radius {
                pixels[y * width + x] = 30
            }
        }
        let polygon = contour(halfHeight: halfHeight)
        return pixels.withUnsafeBufferPointer { buffer in
            let plane = LumaPlane(base: buffer.baseAddress!, width: width, height: height, bytesPerRow: width)
            return IrisLocator.locate(contour: polygon, in: plane)
        }
    }

    /// Elliptic eye contour, corners at centre.x ± eyeWidth / 2, pixel coordinates.
    private func contour(halfHeight: CGFloat) -> [CGPoint] {
        (0..<16).map { i in
            let angle = CGFloat(i) / 16 * 2 * .pi
            return CGPoint(x: centre.x + eyeWidth / 2 * cos(angle), y: centre.y + halfHeight * sin(angle))
        }
    }
}
