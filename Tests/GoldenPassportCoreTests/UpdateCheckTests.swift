import Foundation
import Testing
@testable import GoldenPassportCore

struct AppVersionTests {
    @Test func parsesTagsAndBundleVersions() {
        #expect(AppVersion("v0.3.0")?.description == "0.3.0")
        #expect(AppVersion("0.2")?.description == "0.2.0")
        #expect(AppVersion("1.0.0-beta.2")?.prerelease == "beta.2")
        for invalid in ["", "v", "abc", "1..2", "1.2.3.4", "1.-1", "1.0-"] {
            #expect(AppVersion(invalid) == nil, "\(invalid)")
        }
    }

    @Test func ordersNumericallyWithPrereleasesFirst() throws {
        let ascending = try ["0.1.7", "0.2.0-beta.2", "0.2.0-beta.10", "0.2.0", "0.2.1", "0.10.0", "1.0.0"]
            .map { try #require(AppVersion($0)) }
        for (lower, higher) in zip(ascending, ascending.dropFirst()) {
            #expect(lower < higher, "\(lower) < \(higher)")
            #expect(!(higher < lower))
        }
        #expect(AppVersion("1.0") == AppVersion("v1.0.0"))
    }

    @Test func betaPackagesAddTheirLabel() {
        #expect(AppVersion(bundleInfo: ["CFBundleShortVersionString": "0.2.0", "GPPrerelease": "beta.3"])?.description == "0.2.0-beta.3")
        #expect(AppVersion(bundleInfo: ["CFBundleShortVersionString": "0.2.0"])?.description == "0.2.0")
        #expect(AppVersion(bundleInfo: ["CFBundleShortVersionString": "0.2.0", "GPPrerelease": ""])?.description == "0.2.0")
        #expect(AppVersion(bundleInfo: [:]) == nil)
    }
}

struct UpdateCheckerTests {
    static let latestURL = URL(string: "https://api.example/releases/latest")!
    static let compatURL = URL(string: "https://download.example/compat.json")!

    static func release(_ tag: String, compatAsset: Bool = true) -> Data {
        let assets = compatAsset ? #"[{"name":"compat.json","browser_download_url":"\#(compatURL)"}]"# : "[]"
        return Data(#"""
            {"tag_name":"\#(tag)","html_url":"https://github.com/o/r/releases/tag/\#(tag)","prerelease":false,"assets":\#(assets)}
            """#.utf8)
    }

    /// A checker whose network answers each URL from `responses` and fails for any other URL.
    static func checker(current: String, _ responses: [URL: (status: Int, body: String)]) throws -> UpdateChecker {
        try UpdateChecker(currentVersion: #require(AppVersion(current)), latestReleaseURL: latestURL) { url in
            guard let response = responses[url] else { throw URLError(.cannotConnectToHost) }
            let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: nil, headerFields: nil)!
            return (Data(response.body.utf8), http)
        }
    }

    static func latest(_ tag: String, compat: String?) -> [URL: (status: Int, body: String)] {
        var responses = [latestURL: (status: 200, body: String(decoding: release(tag, compatAsset: compat != nil), as: UTF8.self))]
        if let compat { responses[compatURL] = (200, compat) }
        return responses
    }

    @Test func noReleaseYetIsUpToDate() async throws {
        let checker = try Self.checker(current: "0.2.0", [Self.latestURL: (404, #"{"message":"Not Found"}"#)])
        #expect(try await checker.check() == .upToDate)
    }

    @Test(arguments: ["v0.2.0", "v0.1.7"])
    func sameOrOlderReleaseIsUpToDate(tag: String) async throws {
        let checker = try Self.checker(current: "0.2.0", Self.latest(tag, compat: #"{"dataFormat":1}"#))
        #expect(try await checker.check() == .upToDate)
    }

    @Test func betaIsOfferedTheReleaseItLeadsUpTo() async throws {
        let checker = try Self.checker(current: "0.2.0-beta.3", Self.latest("v0.2.0", compat: #"{"dataFormat":1}"#))
        guard case .available(let update) = try await checker.check() else {
            Issue.record("expected an update")
            return
        }
        #expect(update.version == "0.2.0")
    }

    @Test func newerReleaseInTheSameFormatHasNoNotices() async throws {
        let checker = try Self.checker(current: "0.2.0", Self.latest("v0.2.1", compat: #"{"dataFormat":1,"minUpgradeFrom":null}"#))
        let expected = AvailableUpdate(version: "0.2.1",
                                       releasePage: URL(string: "https://github.com/o/r/releases/tag/v0.2.1")!,
                                       notices: [])
        #expect(try await checker.check() == .available(expected))
    }

    @Test func warnsAboutFormatChangesAndStepUpgrades() async throws {
        let checker = try Self.checker(current: "0.2.0", Self.latest("v0.4.0", compat: #"{"dataFormat":2,"minUpgradeFrom":"0.3.0","note":"ignored"}"#))
        guard case .available(let update) = try await checker.check() else {
            Issue.record("expected an update")
            return
        }
        #expect(update.notices == [
            .dataFormatChange,
            .upgradeFirst(version: "0.3.0", releasePage: URL(string: "https://github.com/o/r/releases/tag/v0.3.0")!),
        ])
    }

    @Test func versionsFromMinUpgradeFromOnNeedNoStep() async throws {
        let checker = try Self.checker(current: "0.3.0", Self.latest("v0.4.0", compat: #"{"dataFormat":1,"minUpgradeFrom":"0.3.0"}"#))
        guard case .available(let update) = try await checker.check() else {
            Issue.record("expected an update")
            return
        }
        #expect(update.notices.isEmpty)
    }

    /// No compat.json, a failed download, bad JSON, no dataFormat, or an unreadable minimum.
    @Test(arguments: [nil, "not json", #"{"minUpgradeFrom":null}"#, #"{"dataFormat":"2"}"#, #"{"dataFormat":1,"minUpgradeFrom":"soon"}"#])
    func unknownCompatibilityIsFlagged(compat: String?) async throws {
        let checker = try Self.checker(current: "0.2.0", Self.latest("v0.2.1", compat: compat))
        guard case .available(let update) = try await checker.check() else {
            Issue.record("expected an update")
            return
        }
        #expect(update.notices == [.compatibilityUnknown])
    }

    @Test func failedCompatDownloadIsFlagged() async throws {
        var responses = Self.latest("v0.2.1", compat: "{}")
        responses[Self.compatURL] = (status: 404, body: "Not Found")
        let checker = try Self.checker(current: "0.2.0", responses)
        guard case .available(let update) = try await checker.check() else {
            Issue.record("expected an update")
            return
        }
        #expect(update.notices == [.compatibilityUnknown])
    }

    @Test func reportsErrors() async throws {
        let failures: [(responses: [URL: (status: Int, body: String)], error: UpdateCheckError)] = [
            ([Self.latestURL: (status: 403, body: "rate limited")], .httpStatus(403)),
            ([Self.latestURL: (status: 200, body: "<html>")], .unreadableResponse),
            (Self.latest("nightly", compat: nil), .unrecognizedVersion("nightly")),
        ]
        for failure in failures {
            let checker = try Self.checker(current: "0.2.0", failure.responses)
            await #expect(throws: failure.error) { try await checker.check() }
        }
        await #expect(throws: URLError.self) { try await Self.checker(current: "0.2.0", [:]).check() }
    }
}

/// Collects what the local test server received.
private final class ReceivedHeaders: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: String]?
    var value: [String: String]? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

@Suite(.serialized)
struct UpdateRequestTests {
    @Test func identifiesOnlyAsGoldenPassport() async throws {
        let port = UInt16.random(in: 40000...60000)
        let received = ReceivedHeaders()
        let server = LocalHTTPServer(port: port) { request in
            received.value = request.headers
            return .text("{}")
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            server.onStateChange = { state in
                if state == .running { continuation.resume() }
            }
            server.start()
        }
        defer { server.stop() }

        let fetch = UpdateChecker.networkFetch(appVersion: "9.9.9")
        let (_, response) = try await fetch(URL(string: "http://127.0.0.1:\(port)/latest")!)
        #expect(response.statusCode == 200)
        let headers = try #require(received.value)
        #expect(headers["user-agent"] == "GoldenPassport/9.9.9")
        #expect(headers["accept-language"] == "en")
    }
}
