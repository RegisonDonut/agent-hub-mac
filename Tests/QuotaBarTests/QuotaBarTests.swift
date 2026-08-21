import XCTest
import AppKit
@testable import AgentHub

final class AgentHubTests: XCTestCase {
    func testRemainingPercentIsClamped() {
        XCTAssertEqual(QuotaWindow(usedPercent: 47, resetsAt: nil, windowName: "week").remainingPercent, 53)
        XCTAssertEqual(QuotaWindow(usedPercent: 120, resetsAt: nil, windowName: "week").remainingPercent, 0)
        XCTAssertEqual(QuotaWindow(usedPercent: -5, resetsAt: nil, windowName: "week").remainingPercent, 100)
    }

    func testBrandMarksAndStatusImageRender() throws {
        for image in [BrandAssets.openAI(size: 18), StatusBarImage.make(codexRemaining: 52)] {
            let tiff = try XCTUnwrap(image.tiffRepresentation)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
            XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
        }
    }

    func testAccountHistoryPersistsQuotas() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = AccountHistoryRepository(fileURL: directory.appendingPathComponent("accounts.json"))
        let reset = Date(timeIntervalSince1970: 1_700_000_000)
        let records = [AccountRecord(
            provider: .codex,
            email: "person@example.com",
            planName: "pro",
            quotas: [QuotaWindow(usedPercent: 42, resetsAt: reset, windowName: "周额度")],
            lastRefreshedAt: reset,
            isCurrent: false
        )]
        try repository.save(records)
        XCTAssertEqual(repository.load(), records)
    }

    func testHistoricalAccountAvailabilityUsesExhaustedWindowReset() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let reset = now.addingTimeInterval(3_600)
        var account = AccountRecord(
            provider: .codex,
            email: "old@example.com",
            quotas: [QuotaWindow(usedPercent: 100, resetsAt: reset, windowName: "周额度")],
            isCurrent: false
        )
        XCTAssertEqual(account.availability(now: now), .waitingForReset(reset))
        XCTAssertEqual(account.availability(now: reset), .estimatedRefreshed)

        account.quotas[0] = QuotaWindow(usedPercent: 100, resetsAt: nil, windowName: "周额度")
        XCTAssertEqual(account.availability(now: now), .unknown)
    }

    func testCurrentAndHistoricalAvailableStatesAreDistinct() {
        let quota = QuotaWindow(usedPercent: 40, resetsAt: nil, windowName: "周额度")
        var account = AccountRecord(provider: .codex, email: "person@example.com", quotas: [quota], isCurrent: true)
        XCTAssertEqual(account.availability(), .liveAvailable)
        account.isCurrent = false
        XCTAssertEqual(account.availability(), .lastKnownAvailable)
    }

    func testManagedCodexAccountRequiresVerifiedRemainingQuotaToBeAvailable() {
        let base = ManagedCodexAccount(
            id: 1,
            name: "Codex",
            email: "person@example.com",
            planType: "pro",
            status: "active",
            schedulable: true,
            fiveHourUsedPercent: nil,
            weeklyUsedPercent: nil,
            fiveHourResetAt: nil,
            weeklyResetAt: nil,
            usageUpdatedAt: nil
        )
        XCTAssertFalse(base.hasVerifiedQuota)
        XCTAssertFalse(base.isAvailable, "Missing quota must never be treated as zero usage")

        let exhausted = ManagedCodexAccount(
            id: 2,
            name: base.name,
            email: base.email,
            planType: base.planType,
            status: base.status,
            schedulable: base.schedulable,
            fiveHourUsedPercent: nil,
            weeklyUsedPercent: 100,
            fiveHourResetAt: nil,
            weeklyResetAt: Date().addingTimeInterval(3600),
            usageUpdatedAt: Date()
        )
        XCTAssertTrue(exhausted.isQuotaExhausted)
        XCTAssertFalse(exhausted.isAvailable)

        let available = ManagedCodexAccount(
            id: 3,
            name: base.name,
            email: base.email,
            planType: base.planType,
            status: base.status,
            schedulable: base.schedulable,
            fiveHourUsedPercent: nil,
            weeklyUsedPercent: 42,
            fiveHourResetAt: nil,
            weeklyResetAt: Date().addingTimeInterval(3600),
            usageUpdatedAt: Date()
        )
        XCTAssertTrue(available.isAvailable)
    }

    func testManagedCodexAccountsSortByRemainingThenNearestReset() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func account(id: Int, used: Double?, reset: Date?, enabled: Bool = true) -> ManagedCodexAccount {
            ManagedCodexAccount(
                id: id,
                name: "Codex \(id)",
                email: "account\(id)@example.com",
                planType: "pro",
                status: enabled ? "active" : "inactive",
                schedulable: true,
                fiveHourUsedPercent: nil,
                weeklyUsedPercent: used,
                fiveHourResetAt: nil,
                weeklyResetAt: reset,
                usageUpdatedAt: used == nil ? nil : now
            )
        }
        let sorted = [
            account(id: 1, used: 100, reset: now.addingTimeInterval(7_200)),
            account(id: 2, used: 70, reset: now.addingTimeInterval(86_400)),
            account(id: 3, used: 10, reset: now.addingTimeInterval(86_400)),
            account(id: 4, used: 100, reset: now.addingTimeInterval(3_600)),
            account(id: 5, used: nil, reset: nil),
            account(id: 6, used: 0, reset: now, enabled: false)
        ].sorted(by: ManagedCodexAccount.displayOrder)

        XCTAssertEqual(sorted.map(\.id), [3, 2, 4, 1, 5, 6])
    }

    @MainActor
    func testSub2APIStackIsPinnedAndLocalOnly() {
        let compose = Sub2APIServiceManager.composeFile
        XCTAssertEqual(Sub2APIServiceManager.pinnedVersion, "0.1.179")
        XCTAssertTrue(compose.contains("weishaw/sub2api:${SUB2API_VERSION}"))
        XCTAssertTrue(compose.contains("127.0.0.1:${SERVER_PORT}:8080"))
        XCTAssertFalse(compose.contains("0.0.0.0:${SERVER_PORT}:8080"))
        XCTAssertTrue(compose.contains("RUN_MODE: \"${RUN_MODE}\""))
        XCTAssertFalse(compose.contains("5432:5432"))
        XCTAssertFalse(compose.contains("6379:6379"))
        XCTAssertTrue(compose.contains("no-new-privileges:true"))

        let safe = Data(#"{"8080/tcp":[{"HostIp":"127.0.0.1","HostPort":"18080"}]}"#.utf8)
        let exposed = Data(#"{"8080/tcp":[{"HostIp":"0.0.0.0","HostPort":"18080"}]}"#.utf8)
        let unexpectedPort = Data(#"{"8080/tcp":[{"HostIp":"127.0.0.1","HostPort":"8080"}]}"#.utf8)
        XCTAssertTrue(Sub2APIServiceManager.portBindingsAreLoopbackOnly(safe))
        XCTAssertFalse(Sub2APIServiceManager.portBindingsAreLoopbackOnly(exposed))
        XCTAssertFalse(Sub2APIServiceManager.portBindingsAreLoopbackOnly(unexpectedPort))

        let config = """
        model = "gpt-5.6-sol"
        model_provider = "openai"

        [model_providers.example]
        model_provider = "must-not-change"
        """
        let updated = Sub2APIServiceManager.settingTopLevelValue(
            "model_provider",
            to: Sub2APIServiceManager.codexProviderID,
            in: config
        )
        XCTAssertTrue(updated.contains("model_provider = \"agenthub_multiaccount\""))
        XCTAssertTrue(updated.contains("model_provider = \"must-not-change\""))
    }

    @MainActor
    func testCodexOAuthCallbackParsing() throws {
        let callback = try Sub2APIServiceManager.parseOAuthCallback(
            "http://localhost:1455/auth/callback?code=test-code&state=test-state",
            expectedState: "test-state"
        )
        XCTAssertEqual(callback.code, "test-code")
        XCTAssertEqual(callback.state, "test-state")
        XCTAssertThrowsError(try Sub2APIServiceManager.parseOAuthCallback(
            "code=test-code&state=wrong-state",
            expectedState: "test-state"
        ))
    }

    @MainActor
    func testLiveSub2APIAutoAdminSessionWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["AGENTHUB_SUB2API_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set AGENTHUB_SUB2API_LIVE_TESTS=1 to exercise the local Sub2API login")
        }
        let service = Sub2APIServiceManager()
        let originalRoutingState = service.codexRoutingEnabled
        await service.startService()
        XCTAssertTrue(service.state.isRunning)
        let session = try await service.createAdminSession()
        XCTAssertFalse(session.accessToken.isEmpty)
        await service.refreshManagedCodexAccounts(forceQuotaRefresh: true)
        XCTAssertFalse(service.managedCodexAccounts.isEmpty)
        XCTAssertTrue(service.quotaRefreshErrors.isEmpty)
        for account in service.managedCodexAccounts where account.isEnabled {
            XCTAssertTrue(account.hasVerifiedQuota)
            if account.isQuotaExhausted {
                XCTAssertFalse(account.isAvailable)
            }
        }

        await service.beginCodexAccountLogin()
        XCTAssertNotNil(service.oauthLoginFlow)
        service.cancelCodexAccountLogin()
        XCTAssertNil(service.oauthLoginFlow)

        await service.setCodexRoutingEnabled(false)
        XCTAssertFalse(service.codexRoutingEnabled)
        await service.setCodexRoutingEnabled(true)
        XCTAssertTrue(service.codexRoutingEnabled)
        await service.setCodexRoutingEnabled(originalRoutingState)
    }

    func testProcessRunnerPassesEnvironmentOverrides() async throws {
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: [],
            environment: ["AGENTHUB_TEST_PROXY": "socks5h://127.0.0.1:7890"]
        )
        let output = try XCTUnwrap(String(data: result.stdout, encoding: .utf8))
        XCTAssertTrue(output.contains("AGENTHUB_TEST_PROXY=socks5h://127.0.0.1:7890"))
    }

    func testProcessRunnerCancellationReturnsPromptly() async throws {
        let startedAt = Date()
        let task = Task {
            try await ProcessRunner.run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["30"],
                timeout: 60
            )
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
        }
    }

    func testPseudoTerminalRunnerProvidesTTY() async throws {
        let result = try await ProcessRunner.runInPseudoTerminal(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "test -t 0 && test -t 1"],
            timeout: 5
        )
        XCTAssertEqual(result.exitCode, 0)
    }

    func testPseudoTerminalRunnerCanBeCancelled() async throws {
        let task = Task {
            try await ProcessRunner.runInPseudoTerminal(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["30"],
                timeout: 60
            )
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected: cancellation propagates through the hidden PTY wrapper.
        }
    }

    func testPseudoTerminalRunnerAcceptsDelayedInput() async throws {
        let input = ProcessInputController()
        let task = Task {
            try await ProcessRunner.runInPseudoTerminal(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "IFS= read -r value; test \"$value\" = agenthub-test-code"],
                timeout: 5,
                inputController: input
            )
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        try input.sendLine("agenthub-test-code")
        let result = try await task.value
        XCTAssertEqual(result.exitCode, 0)
    }

    func testLiveProvidersWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["AGENTHUB_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set AGENTHUB_LIVE_TESTS=1 to exercise local logins")
        }
        let codex = try await CodexQuotaProvider().fetch()
        if let weekly = codex.weekly {
            XCTAssertTrue((0...100).contains(weekly.remainingPercent))
        }
        XCTAssertFalse(try XCTUnwrap(codex.identity?.email).isEmpty)
    }
}
