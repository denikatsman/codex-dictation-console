import Darwin
import Foundation

/// Cheap cross-process invalidation, including atomic database replacement and
/// WAL commits. Read BEFORE loading rows: a concurrent write then remains dirty
/// for the next refresh instead of being accidentally acknowledged.
public struct ArchiveChangeStamp: Equatable, Sendable {
    private struct FileStamp: Equatable, Sendable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let changedSeconds: Int
        let changedNanos: Int
    }
    private let database: FileStamp?
    private let wal: FileStamp?

    public init(databaseURL: URL) throws {
        database = try Self.read(databaseURL.path)
        wal = try Self.read(databaseURL.path + "-wal")
    }

    private static func read(_ path: String) throws -> FileStamp? {
        let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return FileStamp(device: info.st_dev, inode: info.st_ino, size: info.st_size,
            modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanos: info.st_mtimespec.tv_nsec,
            changedSeconds: info.st_ctimespec.tv_sec, changedNanos: info.st_ctimespec.tv_nsec)
    }
}
