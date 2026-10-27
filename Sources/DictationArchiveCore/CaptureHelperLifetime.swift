import Darwin
import Foundation

/// A helper owns this separate lock for its entire lifetime. ArchiveLock stays
/// available to serialize individual scans, settings changes and exports.
public final class CaptureHelperLifetime {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit { _ = Darwin.close(descriptor) }

    /// Returns nil only when another helper already owns this archive's monitor.
    /// Never remove the lock file: contenders must keep using the same inode.
    public static func acquire(layout: ArchiveLayout = ArchiveLayout()) throws -> CaptureHelperLifetime? {
        try FileManager.default.createDirectory(
            at: layout.applicationSupportURL, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let descriptor = Darwin.open(
            lockURL(in: layout).path,
            O_CREAT | O_RDWR | O_EXLOCK | O_NONBLOCK | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            let code = errno
            if code == EWOULDBLOCK || code == EAGAIN { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        _ = Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR)
        return CaptureHelperLifetime(descriptor: descriptor)
    }

    static func lockURL(in layout: ArchiveLayout) -> URL {
        layout.applicationSupportURL.appendingPathComponent("capture-helper.lock")
    }
}
