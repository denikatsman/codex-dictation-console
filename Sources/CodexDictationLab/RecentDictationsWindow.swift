import AppKit
import DictationArchiveCore
import SwiftUI

private final class DictationLogPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class RecentDictationsWindowController: NSWindowController, NSWindowDelegate {
    let model: RecentDictationsLogModel
    private let state: AppState
    private let openRecord: (String) -> Void
    private var closed = false
    private let restoreFrame: Bool
    static let frameName = "CodexDictationLab.RecentDictations"

    init(state: AppState, restoreFrame: Bool = true, openRecord: @escaping (String) -> Void) {
        self.state = state
        self.restoreFrame = restoreFrame
        self.openRecord = openRecord
        model = RecentDictationsLogModel(store: ArchiveStore(layout: state.layout))
        super.init(window: nil)
        window = makePanel()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func makePanel() -> NSPanel {
        let panel = DictationLogPanel(contentRect: NSRect(x: 0, y: 0, width: 430, height: 650),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "Latest Dictations"
        panel.identifier = NSUserInterfaceItemIdentifier("dictation.floating-log")
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.contentView = nil
        panel.contentMinSize = NSSize(width: 340, height: 260)
        panel.appearance = NSAppearance(named: .darkAqua)
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.delegate = self
        panel.center()
        if restoreFrame {
            _ = panel.setFrameUsingName(Self.frameName)
            panel.setFrameAutosaveName(Self.frameName)
        }
        return panel
    }

    func prepareForPresentation() {
        if closed {
            window?.setFrameAutosaveName("")
            window = makePanel()
            closed = false
        }
        guard let window else { return }
        if window.contentView == nil {
            let host = NSHostingView(rootView: RecentDictationsLogView(model: model,
                openRecord: openRecord, close: { [weak self] in self?.window?.performClose(nil) }))
            host.sceneBridgingOptions = [.toolbars]
            window.contentView = host
        }
        recoverDisplay()
        model.start(state: state)
    }

    func present() {
        prepareForPresentation()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func recoverDisplay() {
        guard let window else { return }
        let frame = LibraryWindowGeometry.recovered(window.frame, screens: NSScreen.screens.map(\.visibleFrame))
        if frame != window.frame { window.setFrame(frame, display: false) }
    }

    func windowWillClose(_ notification: Notification) {
        model.stop()
        window?.contentView = nil
        closed = true
    }
}

private struct LogHeaderDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}

struct RecentDictationsLogView: View {
    @ObservedObject var model: RecentDictationsLogModel
    let openRecord: (String) -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Image(systemName: "waveform").foregroundStyle(.secondary)
                        Text("Dictation log").font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                    }
                    Text("LATEST 10  ·  NEWEST FIRST")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .tracking(0.7).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay { LogHeaderDragArea() }
                .help("Drag to move this window")
                Image(systemName: "pin.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                    .help("Always on top, across desktops")
                    .accessibilityLabel("Always on top, across desktops")
                Button(action: model.refresh) { Image(systemName: "arrow.clockwise") }
                    .help("Refresh latest dictations").accessibilityLabel("Refresh latest dictations")
                Button(action: close) { Image(systemName: "xmark") }
                    .help("Close floating log").accessibilityLabel("Close floating log")
                    .keyboardShortcut("w", modifiers: .command)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18).padding(.vertical, 16)
            Divider().overlay(Color.white.opacity(0.05))
            if let error = model.error {
                Label(model.entries.isEmpty ? "Could not load dictations" : "Could not refresh · showing saved entries", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).padding(12).help(error)
            }
            if model.entries.isEmpty {
                VStack(spacing: 10) {
                    if !model.hasLoaded { ProgressView().controlSize(.small) }
                    else {
                        Image(systemName: model.error == nil ? "text.bubble" : "exclamationmark.triangle")
                            .font(.title2).foregroundStyle(.secondary)
                    }
                    Text(emptyMessage)
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(18)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.entries) { entry in
                            DictationLogRow(entry: entry, openRecord: openRecord)
                            if entry.id != model.entries.last?.id { Divider().padding(.vertical, 18) }
                        }
                    }.padding(18)
                }
                .accessibilityIdentifier("dictation.log.entries")
            }
            Divider()
            HStack(spacing: 6) {
                Circle().fill(model.error != nil ? Color.orange : model.hasLoaded ? .green : .secondary)
                    .frame(width: 5, height: 5)
                Text(footerStatus)
                Spacer()
                Text("LOCAL ARCHIVE").font(.system(size: 9, design: .monospaced)).tracking(0.5)
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
            .padding(.horizontal, 18).padding(.vertical, 11)
        }
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(Color.white.opacity(0.12)) }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(.dark)
    }

    private var emptyMessage: String {
        if !model.hasLoaded { return "Loading your dictations…" }
        if model.error != nil { return "Your dictations could not be loaded. Try refreshing." }
        return "Your next dictation will appear here."
    }

    private var footerStatus: String {
        if model.error != nil { return "Refresh needs attention" }
        if !model.hasLoaded { return "Loading…" }
        let count = model.entries.count
        return "Live · \(count) dictation\(count == 1 ? "" : "s")"
    }
}

private struct DictationLogRow: View {
    let entry: DictationLogEntry
    let openRecord: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.timestamp)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.cyan.opacity(0.85))
                    .textSelection(.enabled)
                    .help("Recorded time from your archive, shown in the local timezone")
                Spacer(minLength: 0)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.text, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                .disabled(entry.text.isEmpty).help("Copy full dictation").accessibilityLabel("Copy full dictation")
                Button { openRecord(entry.id) } label: { Image(systemName: "arrow.up.forward.square") }
                    .help("Open in library").accessibilityLabel("Open dictation in library")
            }.buttonStyle(.plain).foregroundStyle(.secondary)
            if entry.recovered || entry.partial {
                HStack(spacing: 8) {
                    if entry.recovered { Text("Recovered transcript") }
                    if entry.partial { Text("Partial source capture") }
                }
                .font(.system(size: 10)).foregroundStyle(.orange.opacity(0.9))
            }
            Text(verbatim: entry.text.isEmpty ? "No transcript saved. Open this dictation in the library to recover its audio." : entry.text)
                .font(.system(size: 14)).lineSpacing(4)
                .foregroundStyle(entry.text.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("dictation.log.text.\(entry.id)")
        }
    }
}
