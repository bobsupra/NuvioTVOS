import CoreGraphics
import XCTest
@testable import NuvioTV

@MainActor
final class CardDisintegrationTests: XCTestCase {
    /// A width x height image, `top` color in the upper half and `bottom` in the lower half.
    private func image(width: Int, height: Int, top: (UInt8, UInt8, UInt8, UInt8), bottom: (UInt8, UInt8, UInt8, UInt8)) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            let c = row < height / 2 ? top : bottom
            for column in 0..<width {
                let o = (row * width + column) * 4
                pixels[o] = c.0; pixels[o + 1] = c.1; pixels[o + 2] = c.2; pixels[o + 3] = c.3
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    private let frame = CGRect(x: 0, y: 0, width: 100, height: 60)

    func testOpaqueCardGivesOneParticlePerCell() {
        let card = image(width: 100, height: 60, top: (255, 255, 255, 255), bottom: (255, 255, 255, 255))
        // 5 pt cells: 20 columns x 12 rows.
        XCTAssertEqual(CardDisintegration.particles(from: card, frame: frame).count, 240)
    }

    func testTransparentAreaHasNoParticles() {
        let card = image(width: 100, height: 60, top: (0, 0, 0, 0), bottom: (255, 255, 255, 255))
        let particles = CardDisintegration.particles(from: card, frame: frame)
        XCTAssertEqual(particles.count, 120)
        XCTAssertTrue(particles.allSatisfy { $0.cell.minY >= frame.height / 2 }, "particles came from the transparent top half")
    }

    func testParticlesKeepTheCardUpright() {
        // Opaque only at the top: every particle must sit in the top half of the frame.
        let card = image(width: 100, height: 60, top: (255, 0, 0, 255), bottom: (0, 0, 0, 0))
        let particles = CardDisintegration.particles(from: card, frame: frame)
        XCTAssertFalse(particles.isEmpty)
        XCTAssertTrue(particles.allSatisfy { $0.cell.maxY <= frame.height / 2 + 0.01 }, "the capture was read upside down")
    }

    func testSweepStartsAtTheTopRightCorner() {
        let card = image(width: 100, height: 60, top: (255, 255, 255, 255), bottom: (255, 255, 255, 255))
        let particles = CardDisintegration.particles(from: card, frame: frame)
        XCTAssertTrue(particles.allSatisfy { (0...1).contains($0.start) })
        let topRight = particles.filter { $0.cell.minX >= 80 && $0.cell.maxY <= 15 }
        let bottomLeft = particles.filter { $0.cell.maxX <= 20 && $0.cell.minY >= 45 }
        let average: ([CardDisintegration.Particle]) -> Double = { $0.map(\.start).reduce(0, +) / Double($0.count) }
        XCTAssertLessThan(average(topRight), average(bottomLeft))
    }

    func testParticlesDriftUpAndToTheRight() {
        let card = image(width: 100, height: 60, top: (255, 255, 255, 255), bottom: (255, 255, 255, 255))
        for particle in CardDisintegration.particles(from: card, frame: frame) {
            XCTAssertGreaterThan(particle.direction.dx, 0)
            XCTAssertLessThan(particle.direction.dy, 0)
        }
    }

    func testParticleCountStaysCappedOnALargeCard() {
        // A focused landscape card is about 460 x 260 pt.
        let large = CGRect(x: 0, y: 0, width: 460, height: 260)
        let card = image(width: 460, height: 260, top: (255, 255, 255, 255), bottom: (255, 255, 255, 255))
        let count = CardDisintegration.particles(from: card, frame: large).count
        XCTAssertLessThanOrEqual(count, CardDisintegration.maxParticles)
        XCTAssertGreaterThan(count, CardDisintegration.maxParticles / 2, "too coarse to read as dust")
    }

    func testASecondRemovalDuringTheDissolveDoesNotRemoveTwice() {
        let center = CardDisintegration()
        let card = image(width: 100, height: 60, top: (255, 255, 255, 255), bottom: (255, 255, 255, 255))
        let capture = CardDisintegration.Capture(image: card, frame: CGRect(x: 0, y: 0, width: 100, height: 60), scale: 1)
        var removed = 0
        center.dissolve(contentId: "tt0000002", capture: capture) { removed += 1 }
        center.dissolve(contentId: "tt0000002", capture: capture) { removed += 1 }
        XCTAssertEqual(removed, 0, "removed before the dissolve finished")
        XCTAssertTrue(center.hiddenContentIds.contains("tt0000002"))

        let done = expectation(description: "dissolve finished")
        DispatchQueue.main.asyncAfter(deadline: .now() + CardDisintegration.duration + 0.3) { done.fulfill() }
        wait(for: [done], timeout: CardDisintegration.duration + 2)
        XCTAssertEqual(removed, 1)
        XCTAssertTrue(center.runs.isEmpty)
    }

    func testWithoutAKnownCardFrameTheRemovalRunsAtOnce() {
        // No row reported a frame for this card, so there is nothing to capture.
        var removed = 0
        CardDisintegration.shared.dissolveCard(contentId: "tt0000001") { removed += 1 }
        XCTAssertEqual(removed, 1)
        XCTAssertFalse(CardDisintegration.shared.hiddenContentIds.contains("tt0000001"))
    }

    func testDissolveCardRunsImmediatelyWhenPerishAnimationIsDisabledByDefault() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: SettingsKey.continueWatchingPerishAnimation)
        var removed = 0
        CardDisintegration.shared.setFrame(CGRect(x: 100, y: 100, width: 200, height: 120), for: "tt-disabled")
        CardDisintegration.shared.dissolveCard(contentId: "tt-disabled") { removed += 1 }
        XCTAssertEqual(removed, 1, "removal must run immediately when perish animation is off")
        XCTAssertFalse(CardDisintegration.shared.hiddenContentIds.contains("tt-disabled"))
        CardDisintegration.shared.setFrame(nil, for: "tt-disabled")
    }

    /// The switch saves to the profile's settings, not to the standard
    /// defaults, so a value in the standard defaults alone doesn't count.
    func testPerishAnimationFollowsTheProfileSettings() {
        let suiteName = "CardDisintegrationTests.profile"
        let profile = UserDefaults(suiteName: suiteName)!
        profile.removePersistentDomain(forName: suiteName)
        UserDefaults.standard.set(true, forKey: SettingsKey.continueWatchingPerishAnimation)
        defer {
            profile.removePersistentDomain(forName: suiteName)
            UserDefaults.standard.removeObject(forKey: SettingsKey.continueWatchingPerishAnimation)
        }
        XCTAssertFalse(CardDisintegration.perishAnimationEnabled(in: profile))
        profile.set(true, forKey: SettingsKey.continueWatchingPerishAnimation)
        XCTAssertTrue(CardDisintegration.perishAnimationEnabled(in: profile))
    }

    func testDissolveCardRunsImmediatelyWhenExplicitlySetToFalse() {
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: SettingsKey.continueWatchingPerishAnimation)
        defer { defaults.removeObject(forKey: SettingsKey.continueWatchingPerishAnimation) }
        var removed = 0
        CardDisintegration.shared.setFrame(CGRect(x: 100, y: 100, width: 200, height: 120), for: "tt-explicit-false")
        CardDisintegration.shared.dissolveCard(contentId: "tt-explicit-false") { removed += 1 }
        XCTAssertEqual(removed, 1)
        XCTAssertFalse(CardDisintegration.shared.hiddenContentIds.contains("tt-explicit-false"))
        CardDisintegration.shared.setFrame(nil, for: "tt-explicit-false")
    }
}
