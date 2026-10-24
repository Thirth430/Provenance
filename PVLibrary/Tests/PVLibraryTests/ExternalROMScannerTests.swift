//
//  ExternalROMScannerTests.swift
//  PVLibraryTests
//

import Foundation
import XCTest
@testable import PVFileSystem

final class ExternalROMScannerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    func testRecursivelyFindsSupportedFilesAndPreservesRelativePaths() throws {
        try writeFile("root.nes", contents: "nes")
        try writeFile("Console A/Platformer.sfc", contents: "snes")
        try writeFile("Console B/Disc/track.bin", contents: "bin")
        try writeFile("Console B/readme.txt", contents: "text")
        try writeFile(".hidden/secret.nes", contents: "hidden")

        let result = try ExternalROMScanner.scan(root: root, systems: [
            ExternalROMSystem(identifier: "nes", supportedExtensions: ["nes"]),
            ExternalROMSystem(identifier: "snes", supportedExtensions: ["sfc"]),
            ExternalROMSystem(identifier: "disc", supportedExtensions: ["bin"])
        ])

        XCTAssertEqual(Set(result.candidates.map(\.relativePath)), [
            "root.nes", "Console A/Platformer.sfc", "Console B/Disc/track.bin"
        ])
        XCTAssertEqual(result.candidates.first(where: { $0.relativePath == "Console A/Platformer.sfc" })?.systemIdentifiers,
                       ["snes"])
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertFalse(result.wasCancelled)
    }

    func testCancellationReturnsPartialResults() throws {
        for index in 0..<5 {
            try writeFile("Folder/Game\(index).nes", contents: "rom \(index)")
        }
        let progress = Progress(totalUnitCount: 0)
        let result = try ExternalROMScanner.scan(root: root,
                                                 systems: [ExternalROMSystem(identifier: "nes", supportedExtensions: ["nes"])],
                                                 progress: progress,
                                                 onProgress: { count in
            if count == 2 { progress.cancel() }
        })

        XCTAssertTrue(result.wasCancelled)
        XCTAssertLessThan(result.candidates.count, 5)
    }

    func testDuplicateDetectionGroupsMatchingMD5AndExistingGames() throws {
        try writeFile("A/Game.nes", contents: "same")
        try writeFile("B/Copy.nes", contents: "same")
        try writeFile("C/Other.nes", contents: "other")
        let result = try ExternalROMScanner.scan(root: root,
                                                 systems: [ExternalROMSystem(identifier: "nes", supportedExtensions: ["nes"])])
        let hashes = ["A/Game.nes": "ABC123", "B/Copy.nes": "abc123", "C/Other.nes": "def456"]

        let groups = ExternalROMDuplicateDetector.groups(candidates: result.candidates,
                                                         md5ByRelativePath: hashes,
                                                         existingGameMD5s: ["DEF456"])

        XCTAssertEqual(groups.map(\.md5), ["abc123", "def456"])
        XCTAssertEqual(groups.first(where: { $0.md5 == "abc123" })?.candidates.count, 2)
        XCTAssertTrue(groups.first(where: { $0.md5 == "def456" })?.matchesExistingGame == true)
    }

    func testZIPArchivesAreReportedAndNotIndexedInFolderInPlaceMode() throws {
        try writeFile("Nested/Pack.zip", contents: "archive")

        let result = try ExternalROMScanner.scan(root: root,
                                                 systems: [ExternalROMSystem(identifier: "nes", supportedExtensions: ["zip", "nes"])])

        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertEqual(result.issues.count, 1)
        XCTAssertTrue(result.issues[0].message.contains("copy importer"))
    }

    private func writeFile(_ relativePath: String, contents: String) throws {
        let fileURL = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: fileURL)
    }
}
