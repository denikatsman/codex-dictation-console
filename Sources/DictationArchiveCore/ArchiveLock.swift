import Darwin
import Foundation

enum ArchiveLock {
    static func withExclusiveAccess<Result>(
        to layout: ArchiveLayout,
        _ operation: () throws -> Result
    ) throws -> Result {
        try layout.prepare()
        let descriptor = Darwin.open(
            layout.captureLockURL.path,
            O_CREAT | O_RDWR | O_EXLOCK,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw ArchiveError.captureLock(String(cString: strerror(errno)))
        }
        defer { _ = Darwin.close(descriptor) }
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: layout.captureLockURL.path
        )
        return try operation()
    }
}
