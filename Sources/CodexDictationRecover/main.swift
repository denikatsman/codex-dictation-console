import DictationArchiveCore
import Foundation

@main struct RecoverCommand {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count == 2 || args.count == 3, args[1] != "--help" else {
            print("Usage: CodexDictationRecover RECORD_ID [LOCALE, default en-US]\nTranscribes archived audio with Apple's on-device model and saves a separate recovered transcript. A model download may be needed; audio stays local.")
            return
        }
        do {
            let result = try await LocalTranscriptRecovery().recover(recordID: args[1], locale: Locale(identifier: args.count == 3 ? args[2] : "en-US")) {
                fputs($0 + "\n", stderr)
            }
            print(result.text)
        } catch {
            fputs("Recovery failed: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
}
