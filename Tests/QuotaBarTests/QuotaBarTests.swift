import XCTest
import AppKit
@testable import AgentHub

final class AgentHubTests: XCTestCase {
    func testRemainingPercentIsClamped() {
        XCTAssertEqual(QuotaWindow(usedPercent: 47, resetsAt: nil, windowName: "week").remainingPercent, 53)
        XCTAssertEqual(QuotaWindow(usedPercent: 120, resetsAt: nil, windowName: "week").remainingPercent, 0)
        XCTAssertEqual(QuotaWindow(usedPercent: -5, resetsAt: nil, windowName: "week").remainingPercent, 100)
    }

    func testExhaustedClaudeWeekForcesSessionDisplayToZero() {
        var snapshot = QuotaSnapshot.empty
        snapshot.claudeSession = QuotaWindow(usedPercent: 10, resetsAt: nil, windowName: "session")
        snapshot.claudeWeekly = QuotaWindow(usedPercent: 100, resetsAt: Date(timeIntervalSince1970: 123), windowName: "week")
        XCTAssertEqual(snapshot.claudeSessionForDisplay?.remainingPercent, 0)
        XCTAssertEqual(snapshot.claudeSessionForDisplay?.resetsAt, snapshot.claudeWeekly?.resetsAt)
    }

    func testBrandMarksAndStatusImageRender() throws {
        for image in [BrandAssets.openAI(size: 18), BrandAssets.claude(size: 18), StatusBarImage.make(codexRemaining: 52, claudeRemaining: 0)] {
            let tiff = try XCTUnwrap(image.tiffRepresentation)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
            XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
        }
    }

    func testLiveProvidersWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["AGENTHUB_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set AGENTHUB_LIVE_TESTS=1 to exercise local logins")
        }
        let codex = try await CodexQuotaProvider().fetch()
        let claude = try await ClaudeQuotaProvider().fetch()
        XCTAssertTrue((0...100).contains(codex.remainingPercent))
        XCTAssertTrue((0...100).contains(claude.session.remainingPercent))
        XCTAssertTrue((0...100).contains(claude.weekly.remainingPercent))
    }
}
