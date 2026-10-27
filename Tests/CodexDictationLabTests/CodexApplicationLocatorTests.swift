import Foundation
import XCTest
@testable import DictationArchiveCore

final class CodexApplicationLocatorTests: XCTestCase {
    func testAccountServiceSupportsNestedAndLegacyLayoutsAndRechecksUpdates() throws {
        let fixture = try ApplicationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let app = try fixture.app(name: "Codex.app", identifier: "com.openai.codex")
        XCTAssertNil(CodexApplicationLocator.accountServiceBinary(in: app))
        let legacy = app.appendingPathComponent("Contents/Resources/codex")
        let nested = app.appendingPathComponent("Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
        for binary in [legacy, nested] {
            try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
            XCTAssertEqual(CodexApplicationLocator.accountServiceBinary(in: app), binary)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: nested.path)
        XCTAssertEqual(CodexApplicationLocator.accountServiceBinary(in: app), legacy)
        try FileManager.default.removeItem(at: legacy)
        XCTAssertNil(CodexApplicationLocator.accountServiceBinary(in: app))
    }

    func testLocatesRenamedCodexByIdentityAndRejectsSeparateChatGPTApp() throws {
        let fixture = try ApplicationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let chat = try fixture.app(name: "ChatGPT.app", identifier: "com.openai.chat")
        let codex = try fixture.app(name: "Some Renamed App.app", identifier: "com.openai.codex")
        XCTAssertEqual(CodexApplicationLocator.locate(in: [chat, codex]), codex)
        XCTAssertNil(CodexApplicationLocator.locate(in: [chat]))
        XCTAssertEqual(InstalledChatGPTInspector(appURL: chat).inspect().auditStatus, .appUnavailable)
        XCTAssertEqual(InstalledChatGPTInspector(appURL: codex).inspect().appVersion, "1.0")
    }

    func testPreferredRunningCandidateWinsOverAnotherInstalledCopy() throws {
        let fixture = try ApplicationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let running = try fixture.app(name: "Running.app", identifier: "com.openai.codex")
        let other = try fixture.app(name: "Other.app", identifier: "com.openai.codex")
        XCTAssertEqual(CodexApplicationLocator.locate(in: [running, other]), running)
    }

    func testBuildStampChangesWhenAppUpdatesAtTheSamePath() throws {
        let fixture = try ApplicationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let app = try fixture.app(name: "Codex.app", identifier: "com.openai.codex")
        let inspector = InstalledChatGPTInspector(appURL: app)
        let before = inspector.buildStamp
        let beforeEvidence = inspector.inspect()
        try Data("updated bundle archive".utf8).write(to: app.appendingPathComponent("Contents/Resources/app.asar"), options: .atomic)
        _ = try fixture.app(name: "Codex.app", identifier: "com.openai.codex", version: "2.0", writeArchive: false)
        XCTAssertNotEqual(before, inspector.buildStamp)
        XCTAssertNotEqual(beforeEvidence.appASARSHA256, inspector.inspect().appASARSHA256)
        XCTAssertEqual(inspector.inspect().appVersion, "2.0")
        XCTAssertEqual(inspector.inspect().auditStatus, .notAudited)
    }

    func testMissingOrIncompleteInstallationDoesNotClaimReviewedEvidence() throws {
        let fixture = try ApplicationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        XCTAssertEqual(InstalledChatGPTInspector(appURL: nil).inspect().auditStatus, .appUnavailable)
        let app = try fixture.app(name: "Codex.app", identifier: "com.openai.codex", writeArchive: false)
        let result = InstalledChatGPTInspector(appURL: app).inspect()
        XCTAssertNil(result.appASARSHA256)
        XCTAssertEqual(result.auditStatus, .notAudited)
    }
}

private struct ApplicationFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CodexDependencyTests-\(UUID().uuidString)")
    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    func app(name: String, identifier: String, version: String = "1.0", writeArchive: Bool = true) throws -> URL {
        let app = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": identifier, "CFBundleName": name, "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version, "CFBundleVersion": version]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"), options: .atomic)
        if writeArchive {
            try Data("initial bundle archive".utf8).write(to: app.appendingPathComponent("Contents/Resources/app.asar"))
        }
        return app
    }
}
