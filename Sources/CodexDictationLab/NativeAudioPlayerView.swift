import AVFoundation
import DictationArchiveCore
import SwiftUI

struct NativeAudioPlayerView: View {
    @StateObject private var model: NativeAudioPlayerModel

    init(recordID: String, audioURL: URL, sourceSHA256: String?) {
        _model = StateObject(wrappedValue: NativeAudioPlayerModel(
            recordID: recordID, sourceURL: audioURL,
            sourceSHA256: sourceSHA256
        ))
    }

    var body: some View {
        Group {
            switch model.loadState {
            case .idle, .preparing:
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Preparing audio…")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            case .ready:
                HStack(spacing: 12) {
                    Button(action: model.togglePlayback) {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .help(model.isPlaying ? "Pause" : "Play")
                    .accessibilityLabel(model.isPlaying ? "Pause recording" : "Play recording")

                    Slider(
                        value: Binding(
                            get: { model.currentTime },
                            set: model.seek(to:)
                        ),
                        in: 0...max(model.duration, 0.01)
                    )
                    .accessibilityLabel("Playback position")
                    .accessibilityValue("\(formatTime(model.currentTime)) of \(formatTime(model.duration))")

                    Text("\(formatTime(model.currentTime)) / \(formatTime(model.duration))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 82, alignment: .trailing)
                }
            case .failed(let message):
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(message)
                    Spacer()
                    Button("Retry") { model.prepare(force: true) }
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 60)
        .background(.quaternary.opacity(0.35))
        .task { model.prepare() }
        .onDisappear { model.stop() }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard ArchiveDuration.wholeSeconds(seconds) != nil else { return "Unavailable" }
        let wholeSeconds = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", wholeSeconds / 60, wholeSeconds % 60)
    }
}

@MainActor
final class NativeAudioPlayerModel: NSObject, ObservableObject, @preconcurrency AVAudioPlayerDelegate {
    enum LoadState: Equatable {
        case idle
        case preparing
        case ready
        case failed(String)
    }

    @Published private(set) var loadState: LoadState = .idle
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    private let sourceURL: URL
    private let sourceSHA256: String?
    private let playbackAsset: @Sendable (URL, String?) async throws -> URL
    private var player: AVAudioPlayer?
    private var preparationTask: Task<Void, Never>?
    private var progressTimer: Timer?

    init(
        recordID: String, sourceURL: URL,
        sourceSHA256: String?,
        playbackAsset: (@Sendable (URL, String?) async throws -> URL)? = nil
    ) {
        self.sourceURL = sourceURL
        self.sourceSHA256 = sourceSHA256
        self.playbackAsset = playbackAsset ?? { url, hash in
            try Task.checkCancellation()
            return try await NativePlaybackAssetStore.shared.playbackURL(for: url, sourceSHA256: hash, recordID: recordID)
        }
    }

    func prepare(force: Bool = false) {
        if !force, loadState == .preparing || loadState == .ready { return }
        preparationTask?.cancel()
        stopPlayback(resetPosition: true)
        loadState = .preparing
        let sourceURL = self.sourceURL
        let sourceSHA256 = self.sourceSHA256
        let playbackAsset = self.playbackAsset

        preparationTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let playbackURL = try await playbackAsset(sourceURL, sourceSHA256)
                try Task.checkCancellation()
                let player = try AVAudioPlayer(contentsOf: playbackURL)
                guard player.duration > 0, player.prepareToPlay() else {
                    throw NativePlaybackAudioError.invalidConvertedAudio
                }
                guard let self else { return }
                player.delegate = self
                self.player = player
                duration = player.duration
                currentTime = 0
                isPlaying = false
                loadState = .ready
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self else { return }
                loadState = .failed(error.localizedDescription)
            }
        }
    }

    func togglePlayback() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            syncProgress()
            isPlaying = false
            stopProgressTimer()
            return
        }
        if currentTime >= duration - 0.01 {
            player.currentTime = 0
            currentTime = 0
        }
        guard player.play() else {
            loadState = .failed("macOS could not start audio playback.")
            return
        }
        isPlaying = true
        startProgressTimer()
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        let boundedTime = min(max(time, 0), duration)
        player.currentTime = boundedTime
        currentTime = boundedTime
    }

    func stop() {
        preparationTask?.cancel()
        preparationTask = nil
        stopPlayback(resetPosition: true)
        // A SwiftUI view can disappear and reappear with the same StateObject.
        // Its discarded player must be prepared again on the next appearance.
        loadState = .idle
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        stopProgressTimer()
        isPlaying = false
        currentTime = flag ? duration : player.currentTime
        if !flag {
            loadState = .failed("macOS stopped before the recording finished playing.")
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        stopProgressTimer()
        isPlaying = false
        loadState = .failed(
            error.map { "Audio decoding failed. \($0.localizedDescription)" }
                ?? "Audio decoding failed."
        )
    }

    private func startProgressTimer() {
        stopProgressTimer()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in self?.syncProgress() }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func syncProgress() {
        guard let player else { return }
        currentTime = player.currentTime
        if isPlaying, !player.isPlaying, player.currentTime < duration - 0.05 {
            isPlaying = false
            stopProgressTimer()
        }
    }

    private func stopPlayback(resetPosition: Bool) {
        stopProgressTimer()
        player?.stop()
        player = nil
        isPlaying = false
        if resetPosition {
            currentTime = 0
            duration = 0
        }
    }
}
