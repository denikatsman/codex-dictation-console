import AVFoundation
import CryptoKit
import Foundation

public enum NativePlaybackAudioError: LocalizedError, Sendable {
    case invalidWebM(String)
    case unsupportedWebM(String)
    case nativeCodecUnavailable
    case conversionFailed(String)
    case invalidConvertedAudio

    public var errorDescription: String? {
        switch self {
        case .invalidWebM(let detail):
            "The archived WebM audio is incomplete or invalid. \(detail)"
        case .unsupportedWebM(let detail):
            "This WebM recording uses an unsupported layout. \(detail)"
        case .nativeCodecUnavailable:
            "macOS could not create its built-in Opus audio decoder."
        case .conversionFailed(let detail):
            "macOS could not prepare this recording for playback. \(detail)"
        case .invalidConvertedAudio:
            "macOS created a playback file, but could not open it again."
        }
    }
}

public struct NativePlaybackAudioConverter: Sendable {
    public static let cacheRevision = "aac96-v1"

    public init() {}

    @discardableResult
    public func convert(sourceURL: URL, destinationURL: URL) throws -> TimeInterval {
        try Task.checkCancellation()
        let sourceData = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        return try convert(sourceData: sourceData, destinationURL: destinationURL)
    }

    @discardableResult
    func convert(sourceData: Data, destinationURL: URL) throws -> TimeInterval {
        try Task.checkCancellation()
        var reader = WebMOpusReader(data: sourceData)
        let webM = try reader.read()
        guard !webM.packets.isEmpty else {
            throw NativePlaybackAudioError.invalidWebM("No complete Opus packets were found.")
        }

        let destinationDirectory = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            let values = try destinationURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw NativePlaybackAudioError.conversionFailed(
                    "The playback destination is not a regular file."
                )
            }
            try FileManager.default.removeItem(at: destinationURL)
        }

        do {
            try Task.checkCancellation()
            try transcode(webM, to: destinationURL)
            try Task.checkCancellation()
            let player = try AVAudioPlayer(contentsOf: destinationURL)
            guard player.duration > 0, player.prepareToPlay() else {
                throw NativePlaybackAudioError.invalidConvertedAudio
            }
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destinationURL.path
            )
            return player.duration
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            if error is CancellationError { throw error }
            if let nativeError = error as? NativePlaybackAudioError {
                throw nativeError
            }
            throw NativePlaybackAudioError.conversionFailed(error.localizedDescription)
        }
    }

    private func transcode(_ webM: WebMOpusAudio, to destinationURL: URL) throws {
        var opusDescription = AudioStreamBasicDescription(
            mSampleRate: webM.sampleRate,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 0,
            mBytesPerFrame: 0,
            mChannelsPerFrame: webM.channelCount,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard
            let opusFormat = AVAudioFormat(streamDescription: &opusDescription),
            let pcmFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: webM.sampleRate,
                channels: webM.channelCount,
                interleaved: false
            ),
            let decoder = AVAudioConverter(from: opusFormat, to: pcmFormat)
        else {
            throw NativePlaybackAudioError.nativeCodecUnavailable
        }
        decoder.magicCookie = webM.codecPrivate

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: webM.sampleRate,
            AVNumberOfChannelsKey: Int(webM.channelCount),
            AVEncoderBitRateKey: webM.channelCount == 1 ? 96_000 : 160_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let outputFile = try AVAudioFile(
            forWriting: destinationURL,
            settings: outputSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        var packetIndex = 0
        var reachedInputEnd = false
        var decodeError: NSError?
        var framesToSkip = webM.initialFramesToDiscard
        let outputCapacity: AVAudioFrameCount = 32_768

        while true {
            try Task.checkCancellation()
            guard let pcmBuffer = AVAudioPCMBuffer(
                pcmFormat: pcmFormat,
                frameCapacity: outputCapacity
            ) else {
                throw NativePlaybackAudioError.conversionFailed(
                    "The PCM output buffer could not be allocated."
                )
            }

            let status = decoder.convert(to: pcmBuffer, error: &decodeError) {
                requestedPacketCount, inputStatus in
                guard packetIndex < webM.packets.count else {
                    reachedInputEnd = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }

                let availableCount = webM.packets.count - packetIndex
                let batchCount = min(max(Int(requestedPacketCount), 1), availableCount, 64)
                let batch = webM.packets[packetIndex..<(packetIndex + batchCount)]
                guard let compressedBuffer = Self.compressedBuffer(
                    packets: batch,
                    format: opusFormat
                ) else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                packetIndex += batchCount
                inputStatus.pointee = .haveData
                return compressedBuffer
            }

            if let decodeError {
                throw NativePlaybackAudioError.conversionFailed(decodeError.localizedDescription)
            }
            if pcmBuffer.frameLength > 0 {
                let writableBuffer = try Self.droppingFirstFrames(
                    framesToSkip,
                    from: pcmBuffer
                )
                let skipped = pcmBuffer.frameLength - writableBuffer.frameLength
                framesToSkip -= min(framesToSkip, skipped)
                if writableBuffer.frameLength > 0 {
                    try outputFile.write(from: writableBuffer)
                }
            }

            switch status {
            case .error:
                throw NativePlaybackAudioError.conversionFailed(
                    "The built-in Opus decoder returned an error."
                )
            case .endOfStream:
                return
            case .inputRanDry where reachedInputEnd:
                return
            case .haveData, .inputRanDry:
                continue
            @unknown default:
                throw NativePlaybackAudioError.conversionFailed(
                    "The built-in Opus decoder returned an unknown state."
                )
            }
        }
    }

    private static func compressedBuffer(
        packets: ArraySlice<WebMOpusPacket>,
        format: AVAudioFormat
    ) -> AVAudioCompressedBuffer? {
        guard let largestPacket = packets.map(\.data.count).max() else { return nil }
        let buffer = AVAudioCompressedBuffer(
            format: format,
            packetCapacity: AVAudioPacketCount(packets.count),
            maximumPacketSize: largestPacket
        )
        guard let descriptions = buffer.packetDescriptions else { return nil }

        var byteOffset = 0
        for (descriptionIndex, packet) in packets.enumerated() {
            packet.data.copyBytes(
                to: buffer.data.advanced(by: byteOffset).assumingMemoryBound(to: UInt8.self),
                count: packet.data.count
            )
            descriptions[descriptionIndex] = AudioStreamPacketDescription(
                mStartOffset: Int64(byteOffset),
                mVariableFramesInPacket: packet.frameCount,
                mDataByteSize: UInt32(packet.data.count)
            )
            byteOffset += packet.data.count
        }
        buffer.packetCount = AVAudioPacketCount(packets.count)
        buffer.byteLength = UInt32(byteOffset)
        return buffer
    }

    private static func droppingFirstFrames(
        _ requestedCount: AVAudioFrameCount,
        from source: AVAudioPCMBuffer
    ) throws -> AVAudioPCMBuffer {
        let dropCount = min(requestedCount, source.frameLength)
        guard dropCount > 0 else { return source }
        let retainedCount = source.frameLength - dropCount
        guard let destination = AVAudioPCMBuffer(
            pcmFormat: source.format,
            frameCapacity: retainedCount
        ) else {
            throw NativePlaybackAudioError.conversionFailed(
                "The trimmed PCM buffer could not be allocated."
            )
        }
        destination.frameLength = retainedCount
        guard retainedCount > 0 else { return destination }

        let channelCount = Int(source.format.channelCount)
        guard
            let sourceChannels = source.floatChannelData,
            let destinationChannels = destination.floatChannelData
        else {
            throw NativePlaybackAudioError.conversionFailed(
                "The decoded PCM buffer had an unexpected layout."
            )
        }
        for channel in 0..<channelCount {
            destinationChannels[channel].update(
                from: sourceChannels[channel].advanced(by: Int(dropCount)),
                count: Int(retainedCount)
            )
        }
        return destination
    }
}

public actor NativePlaybackAssetStore {
    public static let shared = NativePlaybackAssetStore()

    private let cacheDirectory: URL
    private let converter: NativePlaybackAudioConverter
    private var retiredLegacyCache = false

    public init(
        cacheDirectory: URL = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("Codex Dictation Lab", isDirectory: true)
        .appendingPathComponent("Playback", isDirectory: true),
        converter: NativePlaybackAudioConverter = NativePlaybackAudioConverter()
    ) {
        self.cacheDirectory = cacheDirectory
        self.converter = converter
    }

    public func playbackURL(for sourceURL: URL, sourceSHA256: String?, recordID: String) throws -> URL {
        try Task.checkCancellation()
        try retireLegacyCacheIfNeeded()
        let directory = recordDirectory(recordID)
        if let sourceSHA256, Self.isSHA256(sourceSHA256) {
            let expectedURL = cacheURL(for: sourceSHA256, directory: directory)
            if Self.isValidPlaybackFile(at: expectedURL) {
                return expectedURL
            }
        }

        let data = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        let actualHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let destinationURL = cacheURL(for: actualHash, directory: directory)

        if Self.isValidPlaybackFile(at: destinationURL) {
            return destinationURL
        }

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cacheDirectory.path)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        let temporaryURL = directory.appendingPathComponent(
            ".\(UUID().uuidString).m4a"
        )
        do {
            try converter.convert(sourceData: data, destinationURL: temporaryURL)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                let values = try destinationURL.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw NativePlaybackAudioError.conversionFailed(
                        "The playback cache path is not a regular file."
                    )
                }
                try FileManager.default.removeItem(at: destinationURL)
            }
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
            return destinationURL
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    public func removeCachedPlaybackFiles(recordID: String) throws {
        try retireLegacyCacheIfNeeded()
        let directory = recordDirectory(recordID)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func recordDirectory(_ id: String) -> URL {
        cacheDirectory.appendingPathComponent(DictationCaptureEngine.sha256(Data(id.utf8)), isDirectory: true)
    }

    private func retireLegacyCacheIfNeeded() throws {
        guard !retiredLegacyCache else { return }
        // The old flat cache has no record ownership. Retire its disposable
        // derivatives once in the new process, before issuing any playback URL.
        // New URLs always live in record directories and are never swept here.
        if FileManager.default.fileExists(atPath: cacheDirectory.path) {
            for file in try FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.isRegularFileKey])
            where file.pathExtension == "m4a" {
                guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                try FileManager.default.removeItem(at: file)
            }
        }
        retiredLegacyCache = true
    }

    private static func isValidPlaybackFile(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return false }
        return player.duration > 0 && player.prepareToPlay()
    }

    private func cacheURL(for sourceHash: String, directory: URL) -> URL {
        directory.appendingPathComponent(
            "\(sourceHash)-\(NativePlaybackAudioConverter.cacheRevision).m4a"
        )
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (97...102).contains($0.value)
        }
    }
}

private struct WebMOpusAudio {
    let sampleRate: Double
    let channelCount: AVAudioChannelCount
    let codecPrivate: Data
    let initialFramesToDiscard: AVAudioFrameCount
    let packets: [WebMOpusPacket]
}

private struct WebMOpusPacket {
    let data: Data
    let frameCount: UInt32
}

private struct WebMOpusTrack {
    let number: UInt64
    let sampleRate: Double
    let channelCount: AVAudioChannelCount
    let codecPrivate: Data
    let codecDelayNanoseconds: UInt64
}

private struct WebMOpusReader {
    private let data: Data
    private var track: WebMOpusTrack?
    private var packets: [WebMOpusPacket] = []

    init(data: Data) {
        self.data = data
    }

    mutating func read() throws -> WebMOpusAudio {
        try scanMetadata(in: 0..<data.count)
        guard let track else {
            throw NativePlaybackAudioError.unsupportedWebM(
                "No Opus audio track was found."
            )
        }
        guard
            track.codecPrivate.count >= 19,
            track.codecPrivate.starts(with: Data("OpusHead".utf8)),
            track.codecPrivate[8] == 1,
            track.codecPrivate[9] == UInt8(track.channelCount)
        else {
            throw NativePlaybackAudioError.unsupportedWebM(
                "The Opus track has no valid OpusHead descriptor."
            )
        }
        try scanPackets(in: 0..<data.count, trackNumber: track.number)
        let initialFrameCount = (
            Double(track.codecDelayNanoseconds) / 1_000_000_000 * track.sampleRate
        ).rounded()
        guard initialFrameCount <= Double(AVAudioFrameCount.max) else {
            throw NativePlaybackAudioError.invalidWebM("The codec delay is too large.")
        }
        return WebMOpusAudio(
            sampleRate: track.sampleRate,
            channelCount: track.channelCount,
            codecPrivate: track.codecPrivate,
            initialFramesToDiscard: AVAudioFrameCount(initialFrameCount),
            packets: packets
        )
    }

    private mutating func scanMetadata(in range: Range<Int>) throws {
        var offset = range.lowerBound
        while offset < range.upperBound {
            try Task.checkCancellation()
            guard let element = try element(at: offset, limit: range.upperBound) else { break }
            switch element.id {
            case ElementID.segment, ElementID.info, ElementID.tracks:
                try scanMetadata(in: element.payloadRange)
            case ElementID.trackEntry:
                if let candidate = try readTrackEntry(in: element.payloadRange) {
                    track = candidate
                }
            default:
                break
            }
            guard element.nextOffset > offset else { break }
            offset = element.nextOffset
        }
    }

    private func readTrackEntry(in range: Range<Int>) throws -> WebMOpusTrack? {
        var offset = range.lowerBound
        var number: UInt64?
        var type: UInt64?
        var codecID: String?
        var codecPrivate: Data?
        var sampleRate = 48_000.0
        var channelCount: UInt64 = 1
        var codecDelay: UInt64 = 0

        while offset < range.upperBound {
            try Task.checkCancellation()
            guard let element = try element(at: offset, limit: range.upperBound) else { break }
            switch element.id {
            case ElementID.trackNumber:
                number = try unsignedInteger(in: element.payloadRange)
            case ElementID.trackType:
                type = try unsignedInteger(in: element.payloadRange)
            case ElementID.codecID:
                codecID = String(data: data[element.payloadRange], encoding: .utf8)
            case ElementID.codecPrivate:
                codecPrivate = Data(data[element.payloadRange])
            case ElementID.codecDelay:
                codecDelay = try unsignedInteger(in: element.payloadRange)
            case ElementID.audio:
                var audioOffset = element.payloadRange.lowerBound
                while audioOffset < element.payloadRange.upperBound {
                    try Task.checkCancellation()
                    guard let audioElement = try self.element(
                        at: audioOffset,
                        limit: element.payloadRange.upperBound
                    ) else { break }
                    switch audioElement.id {
                    case ElementID.samplingFrequency:
                        sampleRate = try floatingPoint(in: audioElement.payloadRange)
                    case ElementID.channels:
                        channelCount = try unsignedInteger(in: audioElement.payloadRange)
                    default:
                        break
                    }
                    guard audioElement.nextOffset > audioOffset else { break }
                    audioOffset = audioElement.nextOffset
                }
            default:
                break
            }
            guard element.nextOffset > offset else { break }
            offset = element.nextOffset
        }

        guard
            type == 2,
            codecID == "A_OPUS",
            let number,
            let codecPrivate,
            sampleRate == 48_000,
            (1...2).contains(channelCount)
        else { return nil }
        return WebMOpusTrack(
            number: number,
            sampleRate: sampleRate,
            channelCount: AVAudioChannelCount(channelCount),
            codecPrivate: codecPrivate,
            codecDelayNanoseconds: codecDelay
        )
    }

    private mutating func scanPackets(
        in range: Range<Int>,
        trackNumber: UInt64
    ) throws {
        var offset = range.lowerBound
        while offset < range.upperBound {
            try Task.checkCancellation()
            guard let element = try element(at: offset, limit: range.upperBound) else { break }
            switch element.id {
            case ElementID.segment:
                try scanPackets(in: element.payloadRange, trackNumber: trackNumber)
            case ElementID.cluster:
                try readCluster(in: element.payloadRange, trackNumber: trackNumber)
            default:
                break
            }
            guard element.nextOffset > offset else { break }
            offset = element.nextOffset
        }
    }

    private mutating func readCluster(
        in range: Range<Int>,
        trackNumber: UInt64
    ) throws {
        var offset = range.lowerBound
        while offset < range.upperBound {
            try Task.checkCancellation()
            guard let element = try element(at: offset, limit: range.upperBound) else { break }
            switch element.id {
            case ElementID.simpleBlock:
                try appendPackets(
                    from: element.payloadRange,
                    expectedTrackNumber: trackNumber
                )
            case ElementID.blockGroup:
                try readBlockGroup(
                    in: element.payloadRange,
                    trackNumber: trackNumber
                )
            case ElementID.cluster:
                try readCluster(in: element.payloadRange, trackNumber: trackNumber)
            default:
                break
            }
            guard element.nextOffset > offset else { break }
            offset = element.nextOffset
        }
    }

    private mutating func readBlockGroup(
        in range: Range<Int>,
        trackNumber: UInt64
    ) throws {
        var offset = range.lowerBound
        var blockRange: Range<Int>?
        while offset < range.upperBound {
            try Task.checkCancellation()
            guard let element = try element(at: offset, limit: range.upperBound) else { break }
            if element.id == ElementID.block {
                blockRange = element.payloadRange
            }
            guard element.nextOffset > offset else { break }
            offset = element.nextOffset
        }
        if let blockRange {
            try appendPackets(
                from: blockRange,
                expectedTrackNumber: trackNumber
            )
        }
    }

    private mutating func appendPackets(
        from range: Range<Int>,
        expectedTrackNumber: UInt64
    ) throws {
        var offset = range.lowerBound
        let trackVINT = try variableInteger(at: offset, limit: range.upperBound, removingMarker: true)
        guard !trackVINT.isUnknown else {
            throw NativePlaybackAudioError.invalidWebM("A block has an invalid track number.")
        }
        guard trackVINT.value == expectedTrackNumber else { return }
        offset += trackVINT.length
        guard offset + 3 <= range.upperBound else {
            throw NativePlaybackAudioError.invalidWebM("A block header is truncated.")
        }
        offset += 2
        let flags = data[offset]
        offset += 1
        let lacing = (flags & 0x06) >> 1
        let packetRanges = try lacedPacketRanges(
            lacing: lacing,
            payloadStart: offset,
            payloadEnd: range.upperBound
        )
        guard !packetRanges.isEmpty else {
            throw NativePlaybackAudioError.invalidWebM("A block contains no Opus packet.")
        }
        for packetRange in packetRanges {
            let packetData = Data(data[packetRange])
            guard let frameCount = Self.opusFrameCount(packetData) else {
                throw NativePlaybackAudioError.invalidWebM(
                    "An Opus packet has an invalid header."
                )
            }
            packets.append(WebMOpusPacket(
                data: packetData,
                frameCount: frameCount
            ))
        }
    }

    private func lacedPacketRanges(
        lacing: UInt8,
        payloadStart: Int,
        payloadEnd: Int
    ) throws -> [Range<Int>] {
        guard payloadStart <= payloadEnd else { return [] }
        if lacing == 0 {
            return payloadStart < payloadEnd ? [payloadStart..<payloadEnd] : []
        }
        guard payloadStart < payloadEnd else { return [] }
        let packetCount = Int(data[payloadStart]) + 1
        var offset = payloadStart + 1
        var sizes: [Int] = []

        switch lacing {
        case 1:
            for _ in 0..<(packetCount - 1) {
                var size = 0
                var foundTerminator = false
                while offset < payloadEnd {
                    let part = Int(data[offset])
                    offset += 1
                    size += part
                    if part != 255 {
                        foundTerminator = true
                        break
                    }
                }
                guard foundTerminator else {
                    throw NativePlaybackAudioError.invalidWebM(
                        "A Xiph-laced packet size is truncated."
                    )
                }
                sizes.append(size)
            }
        case 2:
            let remaining = payloadEnd - offset
            guard packetCount > 0, remaining % packetCount == 0 else {
                throw NativePlaybackAudioError.invalidWebM("A fixed-laced block is malformed.")
            }
            sizes = Array(repeating: remaining / packetCount, count: packetCount - 1)
        case 3:
            guard packetCount > 1 else { break }
            let first = try variableInteger(at: offset, limit: payloadEnd, removingMarker: true)
            guard !first.isUnknown, first.value <= UInt64(Int.max) else {
                throw NativePlaybackAudioError.invalidWebM("An EBML-laced block is malformed.")
            }
            sizes.append(Int(first.value))
            offset += first.length
            if packetCount > 2 {
                for _ in 0..<(packetCount - 2) {
                    let encoded = try variableInteger(
                        at: offset,
                        limit: payloadEnd,
                        removingMarker: true
                    )
                    let bias = (Int64(1) << Int64(7 * encoded.length - 1)) - 1
                    let difference = Int64(encoded.value) - bias
                    guard let previous = sizes.last else { break }
                    let next = Int64(previous) + difference
                    guard next >= 0, next <= Int64(Int.max) else {
                        throw NativePlaybackAudioError.invalidWebM(
                            "An EBML-laced packet size is invalid."
                        )
                    }
                    sizes.append(Int(next))
                    offset += encoded.length
                }
            }
        default:
            throw NativePlaybackAudioError.invalidWebM("A block has unknown lacing flags.")
        }

        let describedBytes = sizes.reduce(0, +)
        let finalSize = payloadEnd - offset - describedBytes
        guard finalSize >= 0 else {
            throw NativePlaybackAudioError.invalidWebM("A laced block exceeds its declared size.")
        }
        sizes.append(finalSize)
        guard sizes.count == packetCount else {
            throw NativePlaybackAudioError.invalidWebM("A laced block has the wrong packet count.")
        }

        var ranges: [Range<Int>] = []
        for size in sizes {
            let end = offset + size
            guard end <= payloadEnd else {
                throw NativePlaybackAudioError.invalidWebM("A laced packet is truncated.")
            }
            ranges.append(offset..<end)
            offset = end
        }
        return ranges
    }

    private static func opusFrameCount(_ packet: Data) -> UInt32? {
        guard let toc = packet.first else { return nil }
        let configuration = toc >> 3
        let samplesPerFrame: UInt32
        if configuration < 12 {
            samplesPerFrame = [480, 960, 1_920, 2_880][Int(configuration & 0x03)]
        } else if configuration < 16 {
            samplesPerFrame = (configuration & 0x01) == 0 ? 480 : 960
        } else {
            samplesPerFrame = [120, 240, 480, 960][Int(configuration & 0x03)]
        }

        let frameCode = toc & 0x03
        let frameCount: UInt32
        switch frameCode {
        case 0:
            frameCount = 1
        case 1, 2:
            frameCount = 2
        case 3:
            guard packet.count >= 2 else { return nil }
            frameCount = UInt32(packet[packet.index(after: packet.startIndex)] & 0x3f)
            guard frameCount > 0 else { return nil }
        default:
            return nil
        }
        let total = samplesPerFrame * frameCount
        return total <= 5_760 ? total : nil
    }

    private func unsignedInteger(in range: Range<Int>) throws -> UInt64 {
        guard (1...8).contains(range.count) else {
            throw NativePlaybackAudioError.invalidWebM("An integer has an invalid width.")
        }
        return range.reduce(0) { ($0 << 8) | UInt64(data[$1]) }
    }

    private func floatingPoint(in range: Range<Int>) throws -> Double {
        switch range.count {
        case 4:
            let bits = UInt32(try unsignedInteger(in: range))
            return Double(Float(bitPattern: bits))
        case 8:
            return Double(bitPattern: try unsignedInteger(in: range))
        default:
            throw NativePlaybackAudioError.invalidWebM(
                "A floating-point value has an invalid width."
            )
        }
    }

    private func element(at offset: Int, limit: Int) throws -> EBMLElement? {
        guard offset < limit else { return nil }
        let id = try variableInteger(at: offset, limit: limit, removingMarker: false)
        guard (1...4).contains(id.length) else {
            throw NativePlaybackAudioError.invalidWebM("An element ID is malformed.")
        }
        let sizeOffset = offset + id.length
        guard sizeOffset < limit else { return nil }
        let size = try variableInteger(at: sizeOffset, limit: limit, removingMarker: true)
        let payloadStart = sizeOffset + size.length
        guard payloadStart <= limit else { return nil }

        let payloadEnd: Int
        if size.isUnknown {
            payloadEnd = limit
        } else {
            guard size.value <= UInt64(limit - payloadStart) else {
                return nil
            }
            payloadEnd = payloadStart + Int(size.value)
        }
        return EBMLElement(
            id: id.value,
            payloadRange: payloadStart..<payloadEnd,
            nextOffset: payloadEnd
        )
    }

    private func variableInteger(
        at offset: Int,
        limit: Int,
        removingMarker: Bool
    ) throws -> EBMLVariableInteger {
        guard offset < limit else {
            throw NativePlaybackAudioError.invalidWebM("A variable integer is truncated.")
        }
        let firstByte = data[offset]
        guard firstByte != 0 else {
            throw NativePlaybackAudioError.invalidWebM("A variable integer starts with zero.")
        }
        var marker: UInt8 = 0x80
        var length = 1
        while (firstByte & marker) == 0 {
            marker >>= 1
            length += 1
            guard marker != 0, length <= 8 else {
                throw NativePlaybackAudioError.invalidWebM("A variable integer is too wide.")
            }
        }
        guard offset + length <= limit else {
            throw NativePlaybackAudioError.invalidWebM("A variable integer is truncated.")
        }

        var value = UInt64(removingMarker ? firstByte & ~marker : firstByte)
        for index in 1..<length {
            value = (value << 8) | UInt64(data[offset + index])
        }
        let unknownValue = removingMarker
            ? (UInt64(1) << UInt64(7 * length)) - 1
            : UInt64.max
        return EBMLVariableInteger(
            value: value,
            length: length,
            isUnknown: removingMarker && value == unknownValue
        )
    }
}

private struct EBMLElement {
    let id: UInt64
    let payloadRange: Range<Int>
    let nextOffset: Int
}

private struct EBMLVariableInteger {
    let value: UInt64
    let length: Int
    let isUnknown: Bool
}

private enum ElementID {
    static let segment: UInt64 = 0x1853_8067
    static let info: UInt64 = 0x1549_A966
    static let tracks: UInt64 = 0x1654_AE6B
    static let trackEntry: UInt64 = 0xAE
    static let trackNumber: UInt64 = 0xD7
    static let trackType: UInt64 = 0x83
    static let codecID: UInt64 = 0x86
    static let codecPrivate: UInt64 = 0x63A2
    static let codecDelay: UInt64 = 0x56AA
    static let audio: UInt64 = 0xE1
    static let samplingFrequency: UInt64 = 0xB5
    static let channels: UInt64 = 0x9F
    static let cluster: UInt64 = 0x1F43_B675
    static let simpleBlock: UInt64 = 0xA3
    static let blockGroup: UInt64 = 0xA0
    static let block: UInt64 = 0xA1
}
