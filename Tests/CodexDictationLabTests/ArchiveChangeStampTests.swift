import Foundation
import SQLite3
import XCTest
@testable import DictationArchiveCore

final class ArchiveChangeStampTests: XCTestCase {
    func testReadOnlyStampsAreStableAndWALCommitInvalidates() throws {
        let f = try CaptureFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try f.makeSourceRecording(sourceKey: "source", id: "one", transcript: "Words", chunks: [Data("audio".utf8)])
        _ = try f.engine.scan()
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(f.layout.databaseURL.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;", nil, nil, nil), SQLITE_OK)
        let before = try ArchiveChangeStamp(databaseURL: f.layout.databaseURL)
        XCTAssertEqual(try ArchiveChangeStamp(databaseURL: f.layout.databaseURL), before)
        XCTAssertEqual(sqlite3_exec(database, "UPDATE records SET transcript='Outside edit' WHERE id='one';", nil, nil, nil), SQLITE_OK)
        XCTAssertNotEqual(try ArchiveChangeStamp(databaseURL: f.layout.databaseURL), before)
    }

    func testAtomicReplacementWithSameBytesAndModifiedDateInvalidates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("index")
        let data = Data("same bytes".utf8)
        try data.write(to: file)
        let date = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as! Date
        let before = try ArchiveChangeStamp(databaseURL: file)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        XCTAssertNotEqual(try ArchiveChangeStamp(databaseURL: file), before)
    }
}
