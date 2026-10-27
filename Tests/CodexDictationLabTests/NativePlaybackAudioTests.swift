import AVFoundation
import XCTest
@testable import DictationArchiveCore

final class NativePlaybackAudioTests: XCTestCase {
    func testCDL023DeletingAnotherRecordingDoesNotInvalidateAnIssuedPlaybackURL() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("CDL-Playback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let source = scratch.appendingPathComponent("source.webm")
        try makeStreamingWebM().write(to: source)
        let cache = scratch.appendingPathComponent("Cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let legacy = cache.appendingPathComponent("old-unowned-partial.m4a")
        try Data("legacy".utf8).write(to: legacy)
        let store = NativePlaybackAssetStore(cacheDirectory: cache)
        let a = try await store.playbackURL(for: source, sourceSHA256: nil, recordID: "a")
        let b = try await store.playbackURL(for: source, sourceSHA256: nil, recordID: "b")
        let oldB = b.deletingLastPathComponent().appendingPathComponent("old-partial.m4a")
        try Data("old".utf8).write(to: oldB)
        // Pause at the exact boundary from the audit: URL issued, player unopened.
        try await store.removeCachedPlaybackFiles(recordID: "b")
        let player = try AVAudioPlayer(contentsOf: a)
        XCTAssertTrue(player.prepareToPlay())
        XCTAssertGreaterThan(player.duration, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldB.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testCDL029AlreadyCancelledConversionDoesNoWorkOrCachePublication() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("CDL-Cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let gate = CancellationStartGate()
        let work = Task {
            await gate.wait()
            return try NativePlaybackAudioConverter().convert(
                sourceURL: scratch.appendingPathComponent("does-not-exist.webm"),
                destinationURL: scratch.appendingPathComponent("output.m4a"))
        }
        work.cancel()
        await gate.release()
        do { _ = try await work.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path))
        let cacheGate = CancellationStartGate()
        let store = NativePlaybackAssetStore(cacheDirectory: scratch)
        let load = Task {
            await cacheGate.wait()
            return try await store.playbackURL(for: scratch.appendingPathComponent("missing.webm"), sourceSHA256: nil, recordID: "one")
        }
        load.cancel()
        await cacheGate.release()
        do { _ = try await load.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path))
    }

    func testCDL029CancellationDuringConversionRemovesIncompleteOutput() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("CDL-MidCancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let destination = scratch.appendingPathComponent("output.m4a")
        let data = makeStreamingWebM(packetCount: 3_000)
        let work = Task.detached {
            try NativePlaybackAudioConverter().convert(sourceData: data, destinationURL: destination)
        }
        // File creation establishes that parsing completed and conversion began.
        for _ in 0..<2_000 {
            if FileManager.default.fileExists(atPath: destination.path) { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        work.cancel()
        do { _ = try await work.value; XCTFail("Expected cancellation during conversion") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testConvertsSuppliedArchiveCorpusWithOnlyNativeAudioFrameworks() throws {
        guard let archivePath = ProcessInfo.processInfo.environment[
            "CODEX_DICTATION_AUDIO_ARCHIVE"
        ] else {
            throw XCTSkip("Set CODEX_DICTATION_AUDIO_ARCHIVE to run the archive corpus check")
        }
        let archiveURL = URL(fileURLWithPath: archivePath, isDirectory: true)
        let enumerator = FileManager.default.enumerator(
            at: archiveURL,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        let sources = (enumerator?.allObjects as? [URL] ?? [])
            .filter { $0.lastPathComponent == "audio.webm" }
            .sorted { $0.path < $1.path }
        XCTAssertFalse(sources.isEmpty)

        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NativePlaybackCorpusTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let converter = NativePlaybackAudioConverter()
        let startedAt = ContinuousClock.now
        var recordingsWithSignal = 0
        var conversionSeconds = 0.0
        var slowestConversionSeconds = 0.0

        for (index, source) in sources.enumerated() {
            let output = scratch.appendingPathComponent("\(index).m4a")
            let conversionStartedAt = ProcessInfo.processInfo.systemUptime
            let duration = try converter.convert(sourceURL: source, destinationURL: output)
            let conversionDuration = ProcessInfo.processInfo.systemUptime - conversionStartedAt
            conversionSeconds += conversionDuration
            slowestConversionSeconds = max(slowestConversionSeconds, conversionDuration)
            XCTAssertGreaterThan(duration, 0, source.path)
            if try peakAmplitude(in: output) > 0.000_1 {
                recordingsWithSignal += 1
            }
        }

        let elapsed = startedAt.duration(to: .now)
        XCTAssertGreaterThan(recordingsWithSignal, 0)
        print(
            "Native conversion corpus: \(sources.count) recordings converted in "
                + String(format: "%.3f seconds (%.1f ms average, %.1f ms slowest); ",
                    conversionSeconds,
                    conversionSeconds / Double(sources.count) * 1_000,
                    slowestConversionSeconds * 1_000)
                + "\(recordingsWithSignal) contain a non-silent decoded signal; "
                + "total conversion and signal verification time \(elapsed)"
        )
    }

    func testConvertsStreamingWebMWithOnlyNativeAudioFrameworks() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NativePlaybackAudioTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let fixtureURL = scratch.appendingPathComponent("streaming.webm")
        let outputURL = scratch.appendingPathComponent("playback.m4a")
        let sourceData = makeStreamingWebM()
        try sourceData.write(to: fixtureURL)
        let sourceHash = DictationCaptureEngine.sha256(sourceData)

        let duration = try NativePlaybackAudioConverter().convert(
            sourceURL: fixtureURL,
            destinationURL: outputURL
        )

        let player = try AVAudioPlayer(contentsOf: outputURL)
        XCTAssertGreaterThan(duration, 0)
        XCTAssertEqual(player.duration, duration, accuracy: 0.02)
        XCTAssertTrue(player.prepareToPlay())
        XCTAssertEqual(try DictationCaptureEngine.sha256(fileAt: fixtureURL), sourceHash)
    }

    func testRecoversCompletePacketsBeforeATruncatedTail() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NativePlaybackTruncatedTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let fixtureURL = scratch.appendingPathComponent("truncated.webm")
        let outputURL = scratch.appendingPathComponent("playback.m4a")
        var sourceData = makeStreamingWebM(packetCount: 10)
        sourceData.removeLast(5)
        try sourceData.write(to: fixtureURL)

        let duration = try NativePlaybackAudioConverter().convert(
            sourceURL: fixtureURL,
            destinationURL: outputURL
        )

        let player = try AVAudioPlayer(contentsOf: outputURL)
        XCTAssertGreaterThan(duration, 0.1)
        XCTAssertTrue(player.prepareToPlay())
    }

    func testInvalidOpusPacketFailsWithoutLeavingAPlaybackFile() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NativePlaybackInvalidPacketTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let fixtureURL = scratch.appendingPathComponent("invalid.webm")
        let outputURL = scratch.appendingPathComponent("playback.m4a")
        try makeStreamingWebM(packetData: Data([0xff])).write(to: fixtureURL)

        XCTAssertThrowsError(
            try NativePlaybackAudioConverter().convert(
                sourceURL: fixtureURL,
                destinationURL: outputURL
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("invalid header"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testConverterNeverReplacesADirectoryAtTheDestination() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NativePlaybackDestinationSafetyTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let fixtureURL = scratch.appendingPathComponent("streaming.webm")
        let destinationDirectory = scratch.appendingPathComponent(
            "must-not-be-replaced.m4a",
            isDirectory: true
        )
        try makeStreamingWebM().write(to: fixtureURL)
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )

        XCTAssertThrowsError(
            try NativePlaybackAudioConverter().convert(
                sourceURL: fixtureURL,
                destinationURL: destinationDirectory
            )
        )
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destinationDirectory.path,
                isDirectory: &isDirectory
            )
        )
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testPlaybackCacheUsesTheSourceHashAndReusesTheConvertedFile() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NativePlaybackCacheTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let fixtureURL = scratch.appendingPathComponent("streaming.webm")
        try makeStreamingWebM().write(to: fixtureURL)
        let sourceHash = try DictationCaptureEngine.sha256(fileAt: fixtureURL)
        let cacheURL = scratch.appendingPathComponent("cache", isDirectory: true)
        let store = NativePlaybackAssetStore(cacheDirectory: cacheURL)

        let firstURL = try await store.playbackURL(
            for: fixtureURL,
            sourceSHA256: sourceHash, recordID: "fixture"
        )
        let firstModificationDate = try firstURL.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate
        let secondURL = try await store.playbackURL(
            for: fixtureURL,
            sourceSHA256: sourceHash, recordID: "fixture"
        )
        let secondModificationDate = try secondURL.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate

        XCTAssertEqual(firstURL, secondURL)
        XCTAssertTrue(firstURL.lastPathComponent.hasPrefix(sourceHash))
        XCTAssertEqual(firstModificationDate, secondModificationDate)

        let cachePermissions = try FileManager.default.attributesOfItem(
            atPath: cacheURL.path
        )[.posixPermissions] as? NSNumber
        XCTAssertEqual(cachePermissions?.intValue, 0o700)
        let staleRevisionURL = firstURL.deletingLastPathComponent().appendingPathComponent("\(sourceHash)-old.m4a")
        try Data("stale cache".utf8).write(to: staleRevisionURL)

        try await store.removeCachedPlaybackFiles(recordID: "fixture")

        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleRevisionURL.path))
    }

    private func peakAmplitude(in url: URL) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: 8_192
        ) else {
            XCTFail("Could not allocate a PCM verification buffer")
            return 0
        }
        var peak: Float = 0
        while file.framePosition < file.length {
            let remaining = AVAudioFrameCount(file.length - file.framePosition)
            try file.read(
                into: buffer,
                frameCount: min(buffer.frameCapacity, remaining)
            )
            guard buffer.frameLength > 0 else { break }
            guard let channels = buffer.floatChannelData else {
                XCTFail("Expected Float32 PCM while verifying converted audio")
                return 0
            }
            for channel in 0..<Int(file.processingFormat.channelCount) {
                for frame in 0..<Int(buffer.frameLength) {
                    peak = max(peak, abs(channels[channel][frame]))
                }
            }
        }
        return peak
    }

    private func makeStreamingWebM(
        packetCount: Int = 10,
        packetData: Data = Data([0xf8, 0xff, 0xfe])
    ) -> Data {
        let opusHead = Data([
            0x4f, 0x70, 0x75, 0x73, 0x48, 0x65, 0x61, 0x64,
            0x01, 0x01, 0x00, 0x00, 0x80, 0xbb, 0x00, 0x00,
            0x00, 0x00, 0x00
        ])
        let audio = element(0xE1, payload:
            element(0xB5, payload: Data([0x47, 0x3b, 0x80, 0x00]))
            + element(0x9F, payload: Data([0x01]))
            + element(0x6264, payload: Data([0x20]))
        )
        let trackEntry = element(0xAE, payload:
            element(0xD7, payload: Data([0x01]))
            + element(0x73C5, payload: Data([0x01]))
            + element(0x83, payload: Data([0x02]))
            + element(0x86, payload: Data("A_OPUS".utf8))
            + element(0x63A2, payload: opusHead)
            + audio
        )
        let info = element(0x1549A966, payload:
            element(0x2AD7B1, payload: Data([0x0f, 0x42, 0x40]))
        )
        let tracks = element(0x1654AE6B, payload: trackEntry)
        var clusterPayload = element(0xE7, payload: Data([0x00]))
        for index in 0..<packetCount {
            let timestamp = UInt16(index * 20)
            let block = Data([
                0x81,
                UInt8(timestamp >> 8),
                UInt8(timestamp & 0xff),
                0x80
            ]) + packetData
            clusterPayload += element(0xA3, payload: block)
        }

        let ebmlHeader = Data([
            0x1a, 0x45, 0xdf, 0xa3, 0x9f,
            0x42, 0x86, 0x81, 0x01,
            0x42, 0xf7, 0x81, 0x01,
            0x42, 0xf2, 0x81, 0x04,
            0x42, 0xf3, 0x81, 0x08,
            0x42, 0x82, 0x84, 0x77, 0x65, 0x62, 0x6d,
            0x42, 0x87, 0x81, 0x04,
            0x42, 0x85, 0x81, 0x02
        ])
        let unknownSize = Data([0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff])
        return ebmlHeader
            + idBytes(0x18538067) + unknownSize
            + info + tracks
            + idBytes(0x1F43B675) + unknownSize + clusterPayload
    }

    private func element(_ id: UInt64, payload: Data) -> Data {
        idBytes(id) + sizeBytes(payload.count) + payload
    }

    private func idBytes(_ id: UInt64) -> Data {
        let width: Int
        if id <= 0xff { width = 1 }
        else if id <= 0xffff { width = 2 }
        else if id <= 0xff_ffff { width = 3 }
        else { width = 4 }
        return Data((0..<width).map { shift in
            UInt8((id >> UInt64((width - shift - 1) * 8)) & 0xff)
        })
    }

    private func sizeBytes(_ size: Int) -> Data {
        for width in 1...8 where size < (1 << (7 * width)) - 1 {
            var bytes = Data(repeating: 0, count: width)
            var remaining = UInt64(size)
            for index in stride(from: width - 1, through: 0, by: -1) {
                bytes[index] = UInt8(remaining & 0xff)
                remaining >>= 8
            }
            bytes[0] |= UInt8(1 << (8 - width))
            return bytes
        }
        fatalError("Synthetic test element is too large")
    }
}

private actor CancellationStartGate {
    private var released = false
    private var pending: CheckedContinuation<Void, Never>?
    func wait() async {
        if released { return }
        await withCheckedContinuation { pending = $0 }
    }
    func release() { released = true; pending?.resume(); pending = nil }
}
