import UIKit
import XCTest

@MainActor
final class VisualSnapshotScreenTests: HublotUITestCase {
    func testConnectionReference() { assertSnapshot("connection") }
    func testProjectsReference() { assertSnapshot("projects") }
    func testProjectsEmptyReference() { assertSnapshot("projects-empty") }
    func testProjectsErrorReference() { assertSnapshot("projects-error") }
    func testSessionsReference() { assertSnapshot("sessions") }
    func testSessionsEmptyReference() { assertSnapshot("sessions-empty") }
    func testSessionsInstructionsReference() { assertSnapshot("sessions-instructions", settle: 2) }
    func testConversationReference() { assertSnapshot("conversation") }
    func testCodexQuotaReference() { assertSnapshot("codex-quota") }
    func testContextTideReference() { assertSnapshot("context-tide") }
    func testRadiographyReference() { assertSnapshot("radiography") }
    func testRadiographyDenseReference() { assertSnapshot("radiography-dense") }

    private func assertSnapshot(_ scenario: String, settle: TimeInterval = 0.8) {
        launch(scenario, extraArguments: [
            "-UIAccessibilityReduceMotionEnabled", "YES", "-HublotSnapshotMode", "YES",
        ])
        RunLoop.current.run(until: Date().addingTimeInterval(settle))

        let actual = app.screenshot().image
        let bundle = Bundle(for: Self.self)
        let referenceURL = bundle.url(
            forResource: scenario, withExtension: "png", subdirectory: "Snapshots"
        ) ?? bundle.url(forResource: scenario, withExtension: "png")
        guard let referenceURL, let expected = UIImage(contentsOfFile: referenceURL.path) else {
            XCTFail("Reference absente pour \(scenario). Executer Tools/test-local.sh update-snapshots.")
            return
        }

        let difference = Self.difference(actual, expected)
        XCTAssertLessThanOrEqual(
            difference.mean, 2.5,
            "\(scenario): ecart chromatique moyen \(difference.mean)"
        )
        XCTAssertLessThanOrEqual(
            difference.changedRatio, 0.005,
            "\(scenario): \(difference.changedRatio * 100) % des pixels divergent"
        )
    }

    /// Compare en RGBA avec une petite tolerance d'anticrenelage. Les 60
    /// premiers points appartiennent a iOS (heure, reseau, batterie), pas a
    /// Hublot; ils varient meme lorsque l'ecran de l'app est identique.
    private static func difference(_ lhs: UIImage, _ rhs: UIImage) -> (
        mean: Double, changedRatio: Double
    ) {
        guard let right = rgba(rhs),
              let left = rgba(lhs, width: right.width, height: right.height) else {
            return (.infinity, 1)
        }
        let ignoredRows = min(Int(Double(left.height) * 60 / 912), left.height)
        var total = 0
        var changed = 0
        var samples = 0
        for y in stride(from: ignoredRows, to: left.height, by: 2) {
            for x in stride(from: 0, to: left.width, by: 2) {
                let index = (y * left.width + x) * 4
                let delta = (0..<3).reduce(0) {
                    $0 + abs(Int(left.bytes[index + $1]) - Int(right.bytes[index + $1]))
                }
                total += delta
                changed += delta > 36 ? 1 : 0
                samples += 1
            }
        }
        return (Double(total) / Double(max(samples * 3, 1)), Double(changed) / Double(max(samples, 1)))
    }

    private static func rgba(
        _ image: UIImage, width requestedWidth: Int? = nil, height requestedHeight: Int? = nil
    ) -> (bytes: [UInt8], width: Int, height: Int)? {
        guard let cgImage = image.cgImage else { return nil }
        let width = requestedWidth ?? cgImage.width
        let height = requestedHeight ?? cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (bytes, width, height)
    }
}
