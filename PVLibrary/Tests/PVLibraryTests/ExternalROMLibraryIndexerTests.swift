//
//  ExternalROMLibraryIndexerTests.swift
//  PVLibraryTests
//

import Foundation
import XCTest
import PVFileSystem
import PVSystems
@testable import PVLibrary

final class ExternalROMLibraryIndexerTests: XCTestCase {
    private var root: URL!
    private var database: ExternalIndexingDatabaseMock!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = ExternalIndexingDatabaseMock()
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    func testIndexesUniqueSystemCandidatesAndCountsDuplicates() async throws {
        try write("Game.nes")
        let candidate = try scan(extensions: ["nes"])
        database.indexResult = false

        let report = await ExternalROMLibraryIndexer(databaseService: database).index([candidate])

        XCTAssertEqual(database.indexedSystems, [.NES])
        XCTAssertEqual(report.indexedCount, 0)
        XCTAssertEqual(report.duplicateCount, 1)
        XCTAssertTrue(report.issues.isEmpty)
    }

    func testAmbiguousExtensionsAreReportedWithoutGuessing() async throws {
        try write("Track.bin")
        let candidate = try scan(extensions: ["bin"], systems: [.NES, .SNES])

        let report = await ExternalROMLibraryIndexer(databaseService: database).index([candidate])

        XCTAssertTrue(database.indexedSystems.isEmpty)
        XCTAssertEqual(report.issues.first?.relativePath, "Track.bin")
        XCTAssertEqual(report.processedCount, 1)
    }

    func testSystemOverrideResolvesAnAmbiguousExtension() async throws {
        try write("Track.bin")
        let candidate = try scan(extensions: ["bin"], systems: [.NES, .SNES])

        let report = await ExternalROMLibraryIndexer(databaseService: database)
            .index([candidate], systemOverrides: [candidate.relativePath: SystemIdentifier.SNES.rawValue])

        XCTAssertEqual(database.indexedSystems, [.SNES])
        XCTAssertEqual(report.indexedCount, 1)
        XCTAssertTrue(report.issues.isEmpty)
    }

    func testCancellationStopsBeforeTheNextGame() async throws {
        try write("One.nes")
        try write("Two.nes")
        let candidates = try scanAll()
        let progress = Progress(totalUnitCount: Int64(candidates.count))

        let report = await ExternalROMLibraryIndexer(databaseService: database).index(candidates,
                                                                                       progress: progress,
                                                                                       onProgress: { count, _ in
            if count == 1 { progress.cancel() }
        })

        XCTAssertTrue(report.wasCancelled)
        XCTAssertEqual(database.indexedSystems.count, 1)
        XCTAssertEqual(report.processedCount, 1)
    }

    private func write(_ relativePath: String) throws {
        let file = root.appendingPathComponent(relativePath)
        try Data("external ROM".utf8).write(to: file)
    }

    private func scan(extensions: [String], systems: [SystemIdentifier] = [.NES]) throws -> ExternalROMCandidate {
        try XCTUnwrap(scanAll(extensions: extensions, systems: systems).first)
    }

    private func scanAll(extensions: [String] = ["nes"], systems: [SystemIdentifier] = [.NES]) throws -> [ExternalROMCandidate] {
        try ExternalROMScanner.scan(root: root,
                                    systems: systems.map {
            ExternalROMSystem(identifier: $0.rawValue, supportedExtensions: extensions)
        }).candidates
    }
}

private final class ExternalIndexingDatabaseMock: GameImporterDatabaseServicing {
    var indexedSystems: [SystemIdentifier] = []
    var indexResult = true

    func setRomsPath(url: URL) {}

    func importGameIntoDatabase(queueItem: ImportQueueItem) async throws {
        XCTFail("External indexing must not use the copy importer")
    }

    func importBIOSIntoDatabase(queueItem: ImportQueueItem) async throws {
        XCTFail("External indexing must not import BIOS files")
    }

    func getUpdatedGameInfo(for game: PVGame, forceRefresh: Bool) async throws -> PVGame { game }

    func getArtwork(forGame game: PVGame) async -> PVGame { game }

    func indexExternalGame(_ candidate: ExternalROMCandidate,
                           systemID: SystemIdentifier,
                           progress: Progress?,
                           onHashProgress: (@Sendable (Int64, Int64) -> Void)?) async throws -> Bool {
        indexedSystems.append(systemID)
        return indexResult
    }
}
