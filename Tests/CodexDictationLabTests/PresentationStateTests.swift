import AVFoundation
import DictationArchiveCore
import XCTest
@testable import CodexDictationLab

@MainActor
final class PresentationStateTests: XCTestCase {
    func testRefreshingTheSameSearchKeepsResultsUntilTheLookupCompletes() async throws {
        let fixture = try ArchiveFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let record = fixture.record(folder: fixture.root, firstCapturedAt: .now, updatedAt: .now)
        let model = ArchiveSearchModel(debounce: .zero)
        await model.search("transcript") { _ in [record] }
        let started = expectation(description: "Refresh lookup started")
        var finish: CheckedContinuation<[ArchivedDictationRecord], Never>?
        let refresh = Task {
            await model.search("transcript") { _ in
                await withCheckedContinuation { finish = $0; started.fulfill() }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(model.isSearching)
        XCTAssertEqual(model.results, [record])
        finish?.resume(returning: [])
        await refresh.value
        XCTAssertFalse(model.isSearching)
        XCTAssertTrue(model.results.isEmpty)
    }

    func testChangingTheSearchClearsResultsFromThePreviousQuery() async throws {
        let fixture = try ArchiveFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let record = fixture.record(folder: fixture.root, firstCapturedAt: .now, updatedAt: .now)
        let model = ArchiveSearchModel(debounce: .zero)
        await model.search("first") { _ in [record] }
        await model.search("second") { _ in
            XCTAssertTrue(model.results.isEmpty)
            return []
        }
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertEqual(model.query, "second")
    }

    func testLaterSearchWinsWhenEarlierLookupFinishesLast() async throws {
        let fixture = try ArchiveFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let record = fixture.record(folder: fixture.root, firstCapturedAt: .now, updatedAt: .now)
        let model = ArchiveSearchModel(debounce: .zero)
        let started = expectation(description: "First lookup started")
        var finishFirst: CheckedContinuation<[ArchivedDictationRecord], Never>?
        let first = Task {
            await model.search("first") { _ in
                await withCheckedContinuation { finishFirst = $0; started.fulfill() }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        await model.search("second") { _ in [] }
        finishFirst?.resume(returning: [record])
        await first.value
        XCTAssertEqual(model.query, "second")
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertFalse(model.isSearching)
    }

    func testCancelledSearchDoesNotPublishItsDetachedResult() async throws {
        let fixture = try ArchiveFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let record = fixture.record(folder: fixture.root, firstCapturedAt: .now, updatedAt: .now)
        let model = ArchiveSearchModel(debounce: .zero)
        let started = expectation(description: "Lookup started")
        var finish: CheckedContinuation<[ArchivedDictationRecord], Never>?
        let pending = Task {
            await model.search("cancelled") { _ in
                await withCheckedContinuation { finish = $0; started.fulfill() }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        pending.cancel()
        finish?.resume(returning: [record])
        await pending.value
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertFalse(model.isSearching)
    }

    func testReadyPlayerCanPrepareAgainAfterViewDisappears() async throws {
        let fixture = try ArchiveFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let audio = try writeSilentFixture(to: fixture.root.appendingPathComponent("fixture.caf"))
        let model = NativeAudioPlayerModel(recordID: "fixture", sourceURL: audio, sourceSHA256: nil) { url, _ in url }
        model.prepare()
        try await waitUntil { model.loadState == .ready }
        XCTAssertGreaterThan(model.duration, 0)
        model.stop()
        XCTAssertEqual(model.loadState, .idle)
        XCTAssertEqual(model.duration, 0)
        model.prepare()
        try await waitUntil { model.loadState == .ready }
        XCTAssertGreaterThan(model.duration, 0)
        model.stop()
    }

    func testCancelledPreparationFailureCannotReplaceNewPlayerState() async throws {
        let gate = PlaybackGate()
        let source = URL(fileURLWithPath: "/unused-fixture.webm")
        let model = NativeAudioPlayerModel(recordID: "fixture", sourceURL: source, sourceSHA256: nil) { _, _ in
            try await gate.asset()
        }
        model.prepare()
        try await gate.waitForRequests(1)
        model.stop()
        XCTAssertEqual(model.loadState, .idle)
        model.prepare()
        try await gate.waitForRequests(2)
        await gate.failRequest(0)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(model.loadState, .preparing)
        model.stop()
        await gate.failRequest(1)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(model.loadState, .idle)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PresentationFixtureError.timedOut
    }

    private func writeSilentFixture(to url: URL) throws -> URL {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 800))
        buffer.frameLength = 800
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        samples.initialize(repeating: 0, count: 800)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}

private actor PlaybackGate {
    private var requests: [CheckedContinuation<URL, Error>] = []

    func asset() async throws -> URL {
        try await withCheckedThrowingContinuation { requests.append($0) }
    }

    func waitForRequests(_ count: Int) async throws {
        for _ in 0..<200 {
            if requests.count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PresentationFixtureError.timedOut
    }

    func failRequest(_ index: Int) {
        requests[index].resume(throwing: PresentationFixtureError.cancelledAsset)
    }
}

private enum PresentationFixtureError: Error {
    case timedOut
    case cancelledAsset
}
