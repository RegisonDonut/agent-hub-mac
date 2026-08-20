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

    func testSubscriptionWarningThresholds() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar(identifier: .gregorian)
        func record(days: Int) -> AccountRecord {
            AccountRecord(
                provider: .codex,
                email: "person@example.com",
                subscriptionExpiresAt: calendar.date(byAdding: .day, value: days, to: now)
            )
        }
        XCTAssertEqual(record(days: 8).subscriptionWarning(now: now), .none)
        XCTAssertEqual(record(days: 7).subscriptionWarning(now: now), .soon)
        XCTAssertEqual(record(days: 3).subscriptionWarning(now: now), .urgent)
        XCTAssertEqual(record(days: -1).subscriptionWarning(now: now), .urgent)
    }

    func testAccountHistoryPersistsQuotasAndExpiration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = AccountHistoryRepository(fileURL: directory.appendingPathComponent("accounts.json"))
        let expiration = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = Date(timeIntervalSince1970: 1_700_000_000)
        let records = [AccountRecord(
            provider: .claudeCode,
            email: "person@example.com",
            planName: "pro",
            subscriptionExpiresAt: expiration,
            quotas: [QuotaWindow(usedPercent: 42, resetsAt: reset, windowName: "周额度")],
            lastRefreshedAt: reset,
            isCurrent: false
        )]
        try repository.save(records)
        XCTAssertEqual(repository.load(), records)
    }

    func testLiveProvidersWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["AGENTHUB_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set AGENTHUB_LIVE_TESTS=1 to exercise local logins")
        }
        let codex = try await CodexQuotaProvider().fetch()
        let claude = try await ClaudeQuotaProvider().fetch()
        if let weekly = codex.weekly {
            XCTAssertTrue((0...100).contains(weekly.remainingPercent))
        }
        XCTAssertTrue((0...100).contains(claude.session.remainingPercent))
        XCTAssertTrue((0...100).contains(claude.weekly.remainingPercent))
        XCTAssertFalse(try XCTUnwrap(codex.identity?.email).isEmpty)
        XCTAssertFalse(try XCTUnwrap(claude.identity?.email).isEmpty)
    }
}
