import XCTest
import AppKit
import Security
@testable import AgentHub
@testable import AgentHubTOTPKit

private final class InMemorySecretStore: TOTPSecretStore {
    var values: [String: Data] = [:]
    var readCount = 0
    func save(secret: Data, for id: String) throws { values[id] = secret }
    func readSecret(for id: String, reason: String) throws -> Data {
        readCount += 1
        guard let value = values[id] else { throw TOTPError.entryNotFound }
        return value
    }
    func deleteSecret(for id: String) throws { values.removeValue(forKey: id) }
}

private final class RecordingUserPresenceAuthorizer: UserPresenceAuthorizer {
    var reasons: [String] = []
    var error: Error?

    func authorize(reason: String) throws {
        reasons.append(reason)
        if let error { throw error }
    }
}

final class AgentHubTests: XCTestCase {
    func testKeychainStoreAuthorizesBeforeReadingUnrestrictedItem() throws {
        let service = "com.regisondonut.AgentHub.test.\(UUID().uuidString)"
        let account = "entry"
        let value = Data("secret".utf8)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: value
        ]
        XCTAssertEqual(SecItemAdd(item as CFDictionary, nil), errSecSuccess)
        defer {
            _ = SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ] as CFDictionary)
        }

        let authorizer = RecordingUserPresenceAuthorizer()
        let store = KeychainTOTPSecretStore(service: service, authorizer: authorizer)
        XCTAssertEqual(try store.readSecret(for: account, reason: "read test"), value)
        XCTAssertEqual(authorizer.reasons, ["read test"])
    }

    func testRFC6238TOTPVector() throws {
        let secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
        XCTAssertEqual(try TOTPGenerator.code(secret: secret, at: Date(timeIntervalSince1970: 59), digits: 8), "94287082")
        XCTAssertEqual(try TOTPGenerator.code(secret: secret, at: Date(timeIntervalSince1970: 59), digits: 6), "287082")
    }

    func testVaultPersistsMetadataWithoutSecretAndReadsThroughSecretStore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let metadataURL = directory.appendingPathComponent("totp-entries.json")
        let secrets = InMemorySecretStore()
        let vault = TOTPVault(metadataURL: metadataURL, secretStore: secrets)
        let entry = try vault.add(issuer: "AWS", account: "admin", secret: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
        let raw = try String(contentsOf: metadataURL)
        XCTAssertFalse(raw.contains("GEZDGNBVGY3TQOJQ"))
        let attributes = try FileManager.default.attributesOfItem(atPath: metadataURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try vault.code(for: entry.id, at: Date(timeIntervalSince1970: 59)), "287082")
        XCTAssertEqual(secrets.readCount, 1)
        XCTAssertThrowsError(try vault.add(issuer: "AWS", account: "admin", secret: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")) { error in
            XCTAssertEqual(error as? TOTPError, .duplicateEntry)
        }
    }

    func testVaultImportsOtpauthURI() throws {
        let secrets = InMemorySecretStore()
        let vault = TOTPVault(metadataURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), secretStore: secrets)
        let entry = try vault.add(otpauthURI: "otpauth://totp/AWS:admin%40example.com?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&issuer=AWS")
        XCTAssertEqual(entry.issuer, "AWS")
        XCTAssertEqual(entry.account, "admin@example.com")
    }

    func testRemainingPercentIsClamped() {
        XCTAssertEqual(QuotaWindow(usedPercent: 47, resetsAt: nil, windowName: "week").remainingPercent, 53)
        XCTAssertEqual(QuotaWindow(usedPercent: 120, resetsAt: nil, windowName: "week").remainingPercent, 0)
        XCTAssertEqual(QuotaWindow(usedPercent: -5, resetsAt: nil, windowName: "week").remainingPercent, 100)
    }

    func testBrandMarksAndStatusImageRender() throws {
        for image in [
            BrandAssets.openAI(size: 18),
            StatusBarImage.make(codexRemaining: 52),
            StatusBarImage.make(codexRemaining: 600)
        ] {
            let tiff = try XCTUnwrap(image.tiffRepresentation)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
            XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
        }
        XCTAssertEqual(StatusBarImage.displayText(for: 553), "553%")
        XCTAssertEqual(StatusBarImage.fillFraction(for: 553), 1)
        XCTAssertEqual(StatusBarImage.fillFraction(for: 42), 0.42, accuracy: 0.001)
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

    func testManagedCodexPoolRemainingAddsAllVerifiedEnabledAccounts() {
        let now = Date()
        func account(id: Int, remaining: Double?, enabled: Bool = true, schedulable: Bool = true) -> ManagedCodexAccount {
            ManagedCodexAccount(
                id: id,
                name: "Codex \(id)",
                email: "account\(id)@example.com",
                planType: "pro",
                status: enabled ? "active" : "inactive",
                schedulable: schedulable,
                fiveHourUsedPercent: nil,
                weeklyUsedPercent: remaining.map { 100 - $0 },
                fiveHourResetAt: nil,
                weeklyResetAt: now.addingTimeInterval(3_600),
                usageUpdatedAt: remaining == nil ? nil : now
            )
        }

        XCTAssertEqual(ManagedCodexAccount.poolTotalRemainingPercent([
            account(id: 1, remaining: 60),
            account(id: 2, remaining: 80)
        ]), 140)
        XCTAssertEqual(ManagedCodexAccount.poolTotalRemainingPercent([
            account(id: 1, remaining: 60),
            account(id: 2, remaining: 0),
            account(id: 3, remaining: 90, enabled: false),
            account(id: 4, remaining: 90, schedulable: false)
        ]), 150, "Temporary scheduler state must not erase verified quota")
        XCTAssertEqual(ManagedCodexAccount.poolTotalRemainingPercent([
            account(id: 1, remaining: 0),
            account(id: 2, remaining: 0)
        ]), 0)
        XCTAssertNil(ManagedCodexAccount.poolTotalRemainingPercent([
            account(id: 1, remaining: nil)
        ]))
    }

    func testManagedAccountKeepsStableQuotaWhileRefreshStarts() {
        let checkedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let previous = ManagedCodexAccount(
            id: 7,
            name: "person@example.com",
            email: "person@example.com",
            planType: "pro",
            status: "active",
            schedulable: true,
            fiveHourUsedPercent: 20,
            weeklyUsedPercent: 35,
            fiveHourResetAt: checkedAt.addingTimeInterval(3_600),
            weeklyResetAt: checkedAt.addingTimeInterval(86_400),
            usageUpdatedAt: checkedAt
        )
        let transient = ManagedCodexAccount(
            id: 7,
            name: previous.name,
            email: previous.email,
            planType: nil,
            status: "active",
            schedulable: false,
            fiveHourUsedPercent: nil,
            weeklyUsedPercent: nil,
            fiveHourResetAt: nil,
            weeklyResetAt: nil,
            usageUpdatedAt: nil
        )

        let displayed = transient.preservingStableRefreshState(from: previous)
        XCTAssertEqual(displayed.planType, "pro")
        XCTAssertEqual(displayed.weeklyUsedPercent, 35)
        XCTAssertEqual(displayed.usageUpdatedAt, checkedAt)
        XCTAssertTrue(displayed.schedulable)
        XCTAssertTrue(displayed.isAvailable)
    }

    @MainActor
    func testExpiredQuotaTokenRefreshesCredentialsThenRetriesQuota() async throws {
        var quotaRequests = 0
        var credentialRefreshes = 0

        try await Sub2APIServiceManager.refreshQuotaRecoveringExpiredCredentials(
            retryDelays: [0],
            quotaRequest: {
                quotaRequests += 1
                if quotaRequests == 1 {
                    throw Sub2APIRequestError(
                        httpStatus: 401,
                        serverCode: 401,
                        reason: "OPENAI_QUOTA_UPSTREAM_ERROR",
                        message: "Provided authentication token is expired (token_expired)"
                    )
                }
            },
            credentialRefresh: {
                credentialRefreshes += 1
            }
        )

        XCTAssertEqual(quotaRequests, 2)
        XCTAssertEqual(credentialRefreshes, 1)
    }

    @MainActor
    func testSuccessfulQuotaRequestDoesNotRefreshCredentials() async throws {
        var quotaRequests = 0
        var credentialRefreshes = 0

        try await Sub2APIServiceManager.refreshQuotaRecoveringExpiredCredentials(
            retryDelays: [0],
            quotaRequest: { quotaRequests += 1 },
            credentialRefresh: { credentialRefreshes += 1 }
        )

        XCTAssertEqual(quotaRequests, 1)
        XCTAssertEqual(credentialRefreshes, 0)
    }

    @MainActor
    func testFailedCredentialRefreshRequestsReauthorization() async {
        do {
            try await Sub2APIServiceManager.refreshQuotaRecoveringExpiredCredentials(
                retryDelays: [0],
                quotaRequest: {
                    throw Sub2APIRequestError(
                        httpStatus: 401,
                        serverCode: 401,
                        reason: "OPENAI_QUOTA_UPSTREAM_ERROR",
                        message: "token_expired"
                    )
                },
                credentialRefresh: {
                    throw Sub2APIRequestError(
                        httpStatus: 401,
                        serverCode: 401,
                        reason: "invalid_grant",
                        message: "refresh token expired"
                    )
                }
            )
            XCTFail("Expected reauthorization error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "登录凭据已过期，请重新授权此账号")
        }
    }

    @MainActor
    func testEmailNormalizationPreventsDuplicateAccounts() {
        XCTAssertEqual(
            Sub2APIServiceManager.normalizedEmail("  Regison.ZZZ@Outlook.COM\n"),
            "regison.zzz@outlook.com"
        )
    }

    @MainActor
    func testManagedQuotaSnapshotParsesFreshWeeklySubscription() throws {
        let snapshot = try XCTUnwrap(Sub2APIServiceManager.parseManagedQuotaSnapshot([
            "email": "regison.zzz@outlook.com",
            "plan_type": "pro",
            "rate_limit": [
                "allowed": true,
                "primary_window": [
                    "used_percent": 0,
                    "limit_window_seconds": 604_800,
                    "reset_at": 1_788_031_714
                ]
            ],
            "fetched_at": 1_787_426_913
        ]))

        XCTAssertEqual(snapshot.email, "regison.zzz@outlook.com")
        XCTAssertEqual(snapshot.planType, "pro")
        XCTAssertEqual(snapshot.weeklyUsedPercent, 0)
        XCTAssertTrue(snapshot.isWeeklyQuotaAvailable)
        XCTAssertNil(snapshot.fiveHourUsedPercent)
        XCTAssertEqual(snapshot.weeklyResetAt, Date(timeIntervalSince1970: 1_788_031_714))
    }

    @MainActor
    func testRecoveredWeeklyQuotaClearsStaleRuntimeLimit() {
        let staleAccount = ManagedCodexAccount(
            id: 3,
            name: "account@example.com",
            email: "account@example.com",
            planType: "pro",
            status: "active",
            schedulable: true,
            fiveHourUsedPercent: 0,
            weeklyUsedPercent: 100,
            fiveHourResetAt: nil,
            weeklyResetAt: Date().addingTimeInterval(3600),
            usageUpdatedAt: Date().addingTimeInterval(-3600)
        )
        let refreshed = ManagedCodexQuotaSnapshot(
            email: staleAccount.email,
            planType: "pro",
            fiveHourUsedPercent: nil,
            weeklyUsedPercent: 1,
            fiveHourResetAt: nil,
            weeklyResetAt: Date().addingTimeInterval(7 * 24 * 3600),
            fetchedAt: Date()
        )

        XCTAssertTrue(Sub2APIServiceManager.shouldRecoverRuntimeState(
            previous: staleAccount,
            refreshed: refreshed
        ))

        let stillExhausted = ManagedCodexQuotaSnapshot(
            email: staleAccount.email,
            planType: "pro",
            fiveHourUsedPercent: nil,
            weeklyUsedPercent: 100,
            fiveHourResetAt: nil,
            weeklyResetAt: refreshed.weeklyResetAt,
            fetchedAt: Date()
        )
        XCTAssertFalse(Sub2APIServiceManager.shouldRecoverRuntimeState(
            previous: staleAccount,
            refreshed: stillExhausted
        ))
    }

    func testConcurrentWorkSessionsAccumulateIndependently() throws {
        let calendar = try shanghaiCalendar()
        let start = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 24, hour: 0
        )))
        let now = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: start))
        let intervals = [
            WorkInterval(threadID: "session-a", start: start, end: now),
            WorkInterval(threadID: "session-b", start: start, end: now)
        ]

        let snapshot = WorkDurationCalculator.makeSnapshot(
            intervals: intervals,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(snapshot.last24Hours, 48 * 3_600, accuracy: 0.001)
        XCTAssertEqual(snapshot.last7Days, 48 * 3_600, accuracy: 0.001)
        XCTAssertEqual(snapshot.calendarDays.first(where: { $0.date == start })?.duration, 48 * 3_600)
    }

    func testCrossMidnightWorkIsSplitByLocalCalendarDay() throws {
        let calendar = try shanghaiCalendar()
        let start = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 24, hour: 23
        )))
        let end = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 25, hour: 2
        )))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 25, hour: 3
        )))

        let snapshot = WorkDurationCalculator.makeSnapshot(
            intervals: [WorkInterval(threadID: "overnight", start: start, end: end)],
            now: now,
            calendar: calendar
        )
        let firstDay = calendar.startOfDay(for: start)
        let secondDay = calendar.startOfDay(for: end)

        XCTAssertEqual(snapshot.calendarDays.first(where: { $0.date == firstDay })?.duration, 3_600)
        XCTAssertEqual(snapshot.calendarDays.first(where: { $0.date == secondDay })?.duration, 2 * 3_600)
        XCTAssertEqual(snapshot.last24Hours, 3 * 3_600, accuracy: 0.001)
    }

    func testOverlappingTurnsInOneSessionAreNotDoubleCounted() {
        let start = Date(timeIntervalSince1970: 1_787_500_000)
        let intervals = [
            WorkInterval(threadID: "same-session", start: start, end: start.addingTimeInterval(3_600)),
            WorkInterval(
                threadID: "same-session",
                start: start.addingTimeInterval(1_800),
                end: start.addingTimeInterval(5_400)
            )
        ]

        let merged = WorkDurationCalculator.mergeWithinThreads(intervals)

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].end.timeIntervalSince(merged[0].start), 5_400, accuracy: 0.001)
    }

    func testQuotaUsageSummaryAddsPositiveDeltasAcrossReset() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let samples = [
            quotaSample(used: 20, at: now.addingTimeInterval(-4 * 3_600)),
            quotaSample(used: 35, at: now.addingTimeInterval(-3 * 3_600)),
            quotaSample(used: 4, at: now.addingTimeInterval(-2 * 3_600)),
            quotaSample(used: 12, at: now.addingTimeInterval(-3_600))
        ]

        let summary = QuotaUsageCalculator.summary(
            samples: samples,
            duration: 24 * 3_600,
            now: now
        )

        XCTAssertEqual(summary.usedPercent, 27)
        XCTAssertEqual(summary.coveredDuration, 4 * 3_600, accuracy: 0.001)
        XCTAssertFalse(summary.hasFullCoverage)
    }

    func testQuotaUsageSummaryUsesSampleBeforeWindowAsBaseline() {
        let now = Date(timeIntervalSince1970: 3_000_000)
        let samples = [
            quotaSample(used: 10, at: now.addingTimeInterval(-25 * 3_600)),
            quotaSample(used: 18, at: now.addingTimeInterval(-20 * 3_600)),
            quotaSample(used: 25, at: now.addingTimeInterval(-2 * 3_600))
        ]

        let summary = QuotaUsageCalculator.summary(
            samples: samples,
            duration: 24 * 3_600,
            now: now
        )

        XCTAssertEqual(summary.usedPercent, 15)
        XCTAssertTrue(summary.hasFullCoverage)
    }

    func testQuotaUsageBucketsUseFourHourLocalBoundaries() throws {
        let calendar = try shanghaiCalendar()
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 27, hour: 10
        )))
        let samples = [
            quotaSample(used: 10, at: now.addingTimeInterval(-10 * 3_600)),
            quotaSample(used: 13, at: now.addingTimeInterval(-7 * 3_600)),
            quotaSample(used: 20, at: now.addingTimeInterval(-3 * 3_600))
        ]

        let buckets = QuotaUsageCalculator.buckets(
            samples: samples,
            granularity: .fourHourly,
            now: now,
            calendar: calendar
        )
        let usedBuckets = buckets.filter { $0.usedPercent > 0 }

        XCTAssertEqual(usedBuckets.map(\.usedPercent), [3, 7])
        XCTAssertEqual(calendar.component(.hour, from: usedBuckets[0].start), 0)
        XCTAssertEqual(calendar.component(.hour, from: usedBuckets[1].start), 4)
        XCTAssertEqual(
            calendar.component(.day, from: usedBuckets[1].start),
            calendar.component(.day, from: now)
        )
    }

    func testQuotaUsageBucketsUseLocalWeekBoundaries() throws {
        let calendar = try shanghaiCalendar()
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 27, hour: 10
        )))
        let samples = [
            quotaSample(used: 10, at: try XCTUnwrap(calendar.date(from: DateComponents(
                year: 2026, month: 8, day: 17, hour: 9
            )))),
            quotaSample(used: 14, at: try XCTUnwrap(calendar.date(from: DateComponents(
                year: 2026, month: 8, day: 18, hour: 9
            )))),
            quotaSample(used: 20, at: try XCTUnwrap(calendar.date(from: DateComponents(
                year: 2026, month: 8, day: 24, hour: 9
            ))))
        ]

        let buckets = QuotaUsageCalculator.buckets(
            samples: samples,
            granularity: .weekly,
            now: now,
            calendar: calendar
        )
        let usedBuckets = buckets.filter { $0.usedPercent > 0 }

        XCTAssertEqual(usedBuckets.map(\.usedPercent), [4, 6])
        XCTAssertEqual(usedBuckets.map { calendar.component(.weekday, from: $0.start) }, [2, 2])
        XCTAssertEqual(usedBuckets.map { calendar.component(.day, from: $0.start) }, [17, 24])
    }

    @MainActor
    func testQuotaUsageHistoryPersistsOneSamplePerRefresh() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repository = QuotaUsageHistoryRepository(
            fileURL: directory.appendingPathComponent("quota-history.json")
        )
        let store = QuotaUsageStore(repository: repository)
        let recordedAt = Date(timeIntervalSince1970: 4_000_000)
        let account = ManagedCodexAccount(
            id: 7,
            name: "account@example.com",
            email: "account@example.com",
            planType: "pro",
            status: "active",
            schedulable: true,
            fiveHourUsedPercent: 12,
            weeklyUsedPercent: 34,
            fiveHourResetAt: nil,
            weeklyResetAt: recordedAt.addingTimeInterval(7 * 24 * 3_600),
            usageUpdatedAt: recordedAt
        )

        store.record([account], now: recordedAt)
        store.record([account], now: recordedAt)

        XCTAssertEqual(store.samples.count, 1)
        XCTAssertEqual(repository.load().first?.usedPercent, 34)
        XCTAssertEqual(store.accounts.first?.email, "account@example.com")
    }

    @MainActor
    func testQuotaUsageAggregateAddsEveryAccount() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repository = QuotaUsageHistoryRepository(
            fileURL: directory.appendingPathComponent("quota-history.json")
        )
        let now = Date(timeIntervalSince1970: 5_000_000)
        let samples = [
            QuotaUsageSample(
                accountID: 1,
                email: "one@example.com",
                usedPercent: 10,
                resetAt: nil,
                recordedAt: now.addingTimeInterval(-2 * 3_600)
            ),
            QuotaUsageSample(
                accountID: 1,
                email: "one@example.com",
                usedPercent: 18,
                resetAt: nil,
                recordedAt: now.addingTimeInterval(-3_600)
            ),
            QuotaUsageSample(
                accountID: 2,
                email: "two@example.com",
                usedPercent: 30,
                resetAt: nil,
                recordedAt: now.addingTimeInterval(-2 * 3_600)
            ),
            QuotaUsageSample(
                accountID: 2,
                email: "two@example.com",
                usedPercent: 35,
                resetAt: nil,
                recordedAt: now.addingTimeInterval(-3_600)
            )
        ]
        try repository.save(samples)
        let store = QuotaUsageStore(repository: repository)

        let summary = store.aggregateSummary(duration: 24 * 3_600, now: now)
        let buckets = store.aggregateBuckets(granularity: .hourly, now: now)

        XCTAssertEqual(summary.usedPercent, 13)
        XCTAssertEqual(summary.coveredAccounts, 2)
        XCTAssertEqual(summary.totalAccounts, 2)
        XCTAssertEqual(buckets.reduce(0) { $0 + $1.usedPercent }, 13)
    }

    private func quotaSample(used: Double, at date: Date) -> QuotaUsageSample {
        QuotaUsageSample(
            accountID: 1,
            email: "account@example.com",
            usedPercent: used,
            resetAt: nil,
            recordedAt: date
        )
    }

    @MainActor
    func testWorkDashboardRefreshesHourly() {
        XCTAssertEqual(WorkDurationStore.refreshInterval, 3_600)
    }

    @MainActor
    func testLiveWorkHistoryWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["AGENTHUB_WORK_HISTORY_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set AGENTHUB_WORK_HISTORY_LIVE_TESTS=1 to read local Codex work history")
        }
        let store = WorkDurationStore()
        await store.refresh()

        XCTAssertNil(store.errorMessage)
        XCTAssertNotNil(store.snapshot.updatedAt)
        XCTAssertEqual(store.snapshot.calendarDays.count, 371)
        XCTAssertGreaterThan(store.snapshot.last24Hours, 0)
        XCTAssertGreaterThanOrEqual(store.snapshot.last7Days, store.snapshot.last24Hours)
    }

    private func shanghaiCalendar() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        return calendar
    }

    @MainActor
    func testSub2APIStackIsPinnedAndLocalOnly() {
        let compose = Sub2APIServiceManager.composeFile
        XCTAssertEqual(Sub2APIServiceManager.pinnedVersion, "0.1.179")
        XCTAssertEqual(Sub2APIServiceManager.managedQuotaRefreshInterval, 300)
        XCTAssertEqual(
            Sub2APIServiceManager.resilientSchedulerSettings["openai_advanced_scheduler_enabled"] as? Bool,
            true
        )
        XCTAssertEqual(
            Sub2APIServiceManager.resilientSchedulerSettings["openai_advanced_scheduler_sticky_weighted_enabled"] as? Bool,
            true
        )
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
        for account in service.managedCodexAccounts where account.isEnabled {
            XCTAssertTrue(account.hasVerifiedQuota)
            if service.quotaRefreshErrors[account.id] != nil {
                XCTAssertNotNil(ManagedCodexAccount.poolTotalRemainingPercent([account]))
            }
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
