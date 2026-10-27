//
//  ExternalROMCatalogTests.swift
//  PVLibraryTests
//

import Foundation
import XCTest
@testable import PVFileSystem

final class ExternalROMCatalogTests: XCTestCase {
    private var root: URL!
    private var catalogURL: URL!
    private var store: ExternalROMCatalogStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        catalogURL = root.appendingPathComponent("catalog.json")
        store = ExternalROMCatalogStore(fileURL: catalogURL)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    func testQuickScanCatalogPersistsNamesAndRelativePathsWithoutHashes() async throws {
        let folder = ExternalROMFolder(bookmark: Data([1, 2, 3]), displayName: "USB")
        let gameURL = root.appendingPathComponent("Nested/Handheld/Game.gba")
        try FileManager.default.createDirectory(at: gameURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("rom".utf8).write(to: gameURL)
        let result = try ExternalROMScanner.scan(root: root,
                                                 systems: [ExternalROMSystem(identifier: "gba", supportedExtensions: ["gba"])])

        let catalog = try await store.replaceDiscovery(result.candidates, for: folder)
        let reloaded = try await store.load(for: folder)

        XCTAssertEqual(reloaded, catalog)
        XCTAssertEqual(reloaded.entries.map(\.relativePath), ["Nested/Handheld/Game.gba"])
        XCTAssertNil(reloaded.entries.first?.contentMD5)
    }

    func testScanPreservesCachedHashForUnchangedCandidateAndDropsItWhenChanged() async throws {
        let folder = ExternalROMFolder(bookmark: Data([4, 5, 6]), displayName: "USB")
        let gameURL = root.appendingPathComponent("Game.nes")
        try Data("first".utf8).write(to: gameURL)
        let systems = [ExternalROMSystem(identifier: "nes", supportedExtensions: ["nes"])]
        let firstCandidate = try XCTUnwrap(ExternalROMScanner.scan(root: root, systems: systems).candidates.first)
        var initial = try await store.replaceDiscovery([firstCandidate], for: folder)
        initial.entries[0].contentMD5 = "cached-hash"
        initial.entries[0].isIndexed = true
        try await store.save(initial)

        let unchanged = try await store.replaceDiscovery([firstCandidate], for: folder)
        XCTAssertEqual(unchanged.entries[0].contentMD5, "cached-hash")
        XCTAssertTrue(unchanged.entries[0].isIndexed)

        try Data("different size".utf8).write(to: gameURL)
        let changedCandidate = try XCTUnwrap(ExternalROMScanner.scan(root: root, systems: systems).candidates.first)
        let changed = try await store.replaceDiscovery([changedCandidate], for: folder)
        XCTAssertNil(changed.entries[0].contentMD5)
        XCTAssertFalse(changed.entries[0].isIndexed)
    }

    func testCatalogIsScopedToPersistentFolderIdentity() async throws {
        let selectedFolder = ExternalROMFolder(bookmark: Data([7]), displayName: "USB")
        let differentFolder = ExternalROMFolder(bookmark: Data([7]), displayName: "USB")
        let original = ExternalROMCatalog(folderIdentifier: selectedFolder.identifier,
                                          entries: [ExternalROMCatalogEntry(relativePath: "Game.nes",
                                                                           systemIdentifiers: ["nes"],
                                                                           fileSize: 100,
                                                                           modificationDate: Date())])
        try await store.save(original)

        let catalogForOtherSelection = try await store.load(for: differentFolder)

        XCTAssertTrue(catalogForOtherSelection.entries.isEmpty)
        XCTAssertEqual(catalogForOtherSelection.folderIdentifier, differentFolder.identifier)
    }

    func testCatalogRejectsTraversalPathsWhenRebuildingCandidates() {
        let entry = ExternalROMCatalogEntry(relativePath: "../outside.nes",
                                            systemIdentifiers: ["nes"],
                                            fileSize: 1,
                                            modificationDate: nil)

        XCTAssertNil(entry.candidate(under: root))
    }
}
