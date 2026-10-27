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

        let report = await makeIndexer().index([candidate])

        XCTAssertEqual(database.indexedSystems, [.NES])
        XCTAssertEqual(report.indexedCount, 0)
        XCTAssertEqual(report.duplicateCount, 1)
        XCTAssertTrue(report.issues.isEmpty)
    }

    func testAmbiguousExtensionsAreReportedWithoutGuessing() async throws {
        try write("Track.bin")
        let candidate = try scan(extensions: ["bin"], systems: [.NES, .SNES])

        let report = await makeIndexer().index([candidate])

        XCTAssertTrue(database.indexedSystems.isEmpty)
        XCTAssertEqual(report.issues.first?.relativePath, "Track.bin")
        XCTAssertEqual(report.processedCount, 1)
    }

    func testSystemOverrideResolvesAnAmbiguousExtension() async throws {
        try write("Track.bin")
        let candidate = try scan(extensions: ["bin"], systems: [.NES, .SNES])

        let report = await makeIndexer()
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

        let report = await makeIndexer().index(candidates,
                                               progress: progress,
                                               onProgress: { count, _ in
            if count == 1 { progress.cancel() }
        })

        XCTAssertTrue(report.wasCancelled)
        XCTAssertEqual(database.indexedSystems.count, 1)
        XCTAssertEqual(report.processedCount, 1)
    }

    func testHashesAtMostTwoFilesAtOnce() async throws {
        try write("One.nes")
        try write("Two.nes")
        try write("Three.nes")
        let candidates = try scanAll()
        let probe = HashConcurrencyProbe()
        let indexer = ExternalROMLibraryIndexer(databaseService: database, hashOperation: { candidate, _, _ in
            await probe.enter()
            try? await Task.sleep(for: .milliseconds(30))
            await probe.leave()
            return candidate.relativePath
        })

        let report = await indexer.index(candidates)

        let maximumConcurrency = await probe.maximumConcurrency
        XCTAssertEqual(maximumConcurrency, 2)
        XCTAssertEqual(database.indexedSystems.count, 3)
        XCTAssertEqual(report.indexedCount, 3)
        XCTAssertEqual(report.processedCount, 3)
    }

    func testReusesCachedHashWhenFileFingerprintIsUnchanged() async throws {
        try write("Cached.nes")
        let candidate = try scan(extensions: ["nes"])
        let probe = HashCallProbe()
        let indexer = ExternalROMLibraryIndexer(databaseService: database, hashOperation: { _, _, _ in
            await probe.recordCall()
            return "unexpected-new-hash"
        })

        let report = await indexer.index([candidate],
                                         cachedMD5ByRelativePath: [candidate.relativePath: "cached-md5"])

        let hashCallCount = await probe.callCount
        XCTAssertEqual(hashCallCount, 0)
        XCTAssertEqual(report.indexedCount, 1)
        XCTAssertTrue(database.indexedSystems.contains(.NES))
    }

    private func makeIndexer() -> ExternalROMLibraryIndexer {
        ExternalROMLibraryIndexer(databaseService: database, hashOperation: { candidate, _, onProgress in
            if candidate.fileSize > 0 { await onProgress(candidate.fileSize, candidate.fileSize) }
            return "test-md5"
        })
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
                           contentMD5: String,
                           progress: Progress?) async throws -> Bool {
        indexedSystems.append(systemID)
        return indexResult
    }
}

private actor HashConcurrencyProbe {
    private var active = 0
    private(set) var maximumConcurrency = 0

    func enter() {
        active += 1
        maximumConcurrency = max(maximumConcurrency, active)
    }

    func leave() {
        active -= 1
    }
}

private actor HashCallProbe {
    private(set) var callCount = 0

    func recordCall() {
        callCount += 1
    }
}
