import AppKit
import XCTest
@testable import CodexDictationLab

@MainActor
final class AppQuitCoordinatorTests: XCTestCase {
    func testNonUIQuitFromMainDispatchCompletesInAnIsolatedAppKitProcess() throws {
        if ProcessInfo.processInfo.environment["CDL_UPDATE_QUIT_CHILD"] == "1" {
            let coordinator = AppQuitCoordinator(confirmQuit: { XCTFail("No warning in this path"); return false },
                stopHelper: { try await Task.sleep(for: .milliseconds(30)) }, reportFailure: { _ in XCTFail("Unexpected failure") })
            let delegate = LabApplicationDelegate(backgroundLaunch: true, quitCoordinator: coordinator)
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            app.delegate = delegate
            DispatchQueue.main.async {
                delegate.requestUpdateQuit { print("update-quit-acknowledged"); fflush(stdout) }
            }
            withExtendedLifetime(delegate) { app.run() }
            return
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["-XCTest", "CodexDictationLabTests.AppQuitCoordinatorTests/testNonUIQuitFromMainDispatchCompletesInAnIsolatedAppKitProcess", Bundle(for: Self.self).bundleURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment["CDL_UPDATE_QUIT_CHILD"] = "1"
        child.environment = environment
        let output = Pipe(); child.standardOutput = output; child.standardError = output
        try child.run()
        // Only this disposable test child is eligible for the timeout signal.
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if child.isRunning { child.terminate() } }
        let log = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        child.waitUntilExit()
        XCTAssertEqual(child.terminationReason, .exit, log)
        XCTAssertEqual(child.terminationStatus, 0, log)
        XCTAssertTrue(log.contains("update-quit-acknowledged"), log)
    }

    func testUpdateQuitSkipsWarningButStillDrainsWorker() async {
        let replied = expectation(description: "update quit drained")
        var drained = false
        let coordinator = AppQuitCoordinator(confirmQuit: { XCTFail("Update must not drive UI"); return false },
            stopHelper: { drained = true }, reportFailure: { _ in XCTFail("Unexpected failure") })
        XCTAssertEqual(coordinator.requestQuit(confirm: false) {
            XCTAssertTrue($0); XCTAssertTrue(drained); replied.fulfill()
        }, .terminateLater)
        await fulfillment(of: [replied], timeout: 2)
    }

    func testCancelLeavesCaptureRunningAndDoesNotRequestTermination() {
        var shutdowns = 0
        var replies: [Bool] = []
        let coordinator = AppQuitCoordinator(
            confirmQuit: { false },
            stopHelper: { shutdowns += 1 },
            reportFailure: { _ in XCTFail("Cancelling is not an error") }
        )

        XCTAssertEqual(coordinator.requestQuit { replies.append($0) }, .terminateCancel)
        XCTAssertFalse(coordinator.isQuitting)
        XCTAssertEqual(shutdowns, 0)
        XCTAssertTrue(replies.isEmpty)
    }

    func testQuitWaitsForHelperAndRepeatedRequestsDoNotPromptAgain() async {
        let stopping = expectation(description: "helper stopping")
        let replied = expectation(description: "library allowed to quit")
        var finishScan: CheckedContinuation<Void, Never>?
        var confirmations = 0
        var replies: [Bool] = []
        let coordinator = AppQuitCoordinator(
            confirmQuit: { confirmations += 1; return true },
            stopHelper: {
                await withCheckedContinuation { finishScan = $0; stopping.fulfill() }
            },
            reportFailure: { _ in XCTFail("Shutdown should succeed") }
        )

        XCTAssertEqual(coordinator.requestQuit { replies.append($0); replied.fulfill() }, .terminateLater)
        await fulfillment(of: [stopping], timeout: 2)
        XCTAssertTrue(coordinator.isQuitting)
        XCTAssertTrue(replies.isEmpty, "Do not exit while the helper is still saving")
        XCTAssertEqual(coordinator.requestQuit { _ in XCTFail("Duplicate termination callback") }, .terminateLater)
        XCTAssertEqual(confirmations, 1)

        finishScan?.resume()
        await fulfillment(of: [replied], timeout: 2)
        XCTAssertEqual(replies, [true])
    }

    func testFailedShutdownKeepsAppOpenAndAllowsAnotherQuitAttempt() async {
        let failed = expectation(description: "failure reported")
        let succeeded = expectation(description: "retry completed")
        var shouldFail = true
        var confirmations = 0
        var replies: [Bool] = []
        let coordinator = AppQuitCoordinator(
            confirmQuit: { confirmations += 1; return true },
            stopHelper: { if shouldFail { throw TestFailure.helperStillRunning } },
            reportFailure: { _ in failed.fulfill() }
        )

        _ = coordinator.requestQuit { replies.append($0) }
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertFalse(coordinator.isQuitting)
        XCTAssertEqual(replies, [false])

        shouldFail = false
        _ = coordinator.requestQuit { replies.append($0); succeeded.fulfill() }
        await fulfillment(of: [succeeded], timeout: 2)
        XCTAssertEqual(confirmations, 2)
        XCTAssertEqual(replies, [false, true])
    }

    func testQuitDuringTheWarningCannotOpenADuplicateWarning() async {
        let replied = expectation(description: "quit completed")
        var coordinator: AppQuitCoordinator!
        var confirmations = 0
        coordinator = AppQuitCoordinator(
            confirmQuit: {
                confirmations += 1
                XCTAssertEqual(coordinator.requestQuit { _ in XCTFail("Nested quit") }, .terminateCancel)
                XCTAssertFalse(coordinator.isQuitting, "Capture continues while the user decides")
                return true
            },
            stopHelper: {},
            reportFailure: { _ in XCTFail("Shutdown should succeed") }
        )
        _ = coordinator.requestQuit { XCTAssertTrue($0); replied.fulfill() }
        await fulfillment(of: [replied], timeout: 2)
        XCTAssertEqual(confirmations, 1)
        coordinator = nil
    }

    func testClosingTheLastWindowDoesNotQuitTheApp() {
        XCTAssertFalse(LabApplicationDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }
}

private enum TestFailure: Error {
    case helperStillRunning
}
