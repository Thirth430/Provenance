//
//  ExternalROMFolderTests.swift
//  PVLibraryTests
//

import Foundation
import XCTest
@testable import PVFileSystem

final class ExternalROMFolderTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        suite = "ExternalROMFolderTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        if FileManager.default.fileExists(atPath: temporaryRoot.path) {
            try FileManager.default.removeItem(at: temporaryRoot)
        }
    }

    func testStoreRoundTripPreservesSelection() throws {
        let store = ExternalROMFolderStore(defaults: defaults, key: "externalROMFolder")
        let selection = ExternalROMFolder(bookmark: Data([4, 5, 6]),
                                          displayName: "USB Games",
                                          selectedAt: Date(timeIntervalSinceReferenceDate: 12.5))

        try store.save(selection)

        XCTAssertEqual(store.load(), selection)
        XCTAssertEqual(store.load()?.version, ExternalROMFolder.currentVersion)
    }

    func testMigratesOlderFolderSelectionAndKeepsItsNewIdentityStable() throws {
        let store = ExternalROMFolderStore(defaults: defaults, key: "externalROMFolder")
        let legacy = Data("{\"version\":1,\"bookmark\":\"AQID\",\"displayName\":\"USB Games\",\"selectedAt\":0}".utf8)
        defaults.set(legacy, forKey: "externalROMFolder")

        let firstLoad = try XCTUnwrap(store.load())
        let secondLoad = try XCTUnwrap(store.load())

        XCTAssertEqual(firstLoad.version, ExternalROMFolder.currentVersion)
        XCTAssertEqual(firstLoad.identifier, secondLoad.identifier)
    }

    func testOpenCreatesAnAccessSessionForSelectedFolder() throws {
        let store = ExternalROMFolderStore(defaults: defaults, key: "externalROMFolder")
        let manager = ExternalROMFolderAccessManager(store: store)
        _ = try manager.select(temporaryRoot)

        let access = try manager.openSavedFolder()

        XCTAssertEqual(access.url.standardizedFileURL, temporaryRoot.standardizedFileURL)
    }

    func testDisconnectedFolderReportsUnavailable() throws {
        let folderURL = temporaryRoot.appendingPathComponent("Disconnected")
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let store = ExternalROMFolderStore(defaults: defaults, key: "externalROMFolder")
        let manager = ExternalROMFolderAccessManager(store: store)
        let selection = try manager.select(folderURL)
        try FileManager.default.removeItem(at: folderURL)

        XCTAssertThrowsError(try manager.open(selection)) { error in
            guard case ExternalROMFolderError.unavailable = error else {
                return XCTFail("Expected unavailable-folder error, got \(error)")
            }
        }
    }

    func testInvalidBookmarkReportsPermissionFailure() {
        let manager = ExternalROMFolderAccessManager(store: ExternalROMFolderStore(read: { nil }, write: { _ in }))
        let invalid = ExternalROMFolder(bookmark: Data("not a bookmark".utf8), displayName: "USB Games")

        XCTAssertThrowsError(try manager.open(invalid)) { error in
            guard case ExternalROMFolderError.invalidBookmark = error else {
                return XCTFail("Expected invalid-bookmark error, got \(error)")
            }
        }
    }

    func testAvailabilityReportsUnconfiguredAndUnavailableFolder() throws {
        let store = ExternalROMFolderStore(defaults: defaults, key: "externalROMFolder")
        XCTAssertEqual(ExternalROMFolderAvailability.current(store: store, rootURLProvider: { nil }), .notConfigured)

        try store.save(ExternalROMFolder(bookmark: Data(), displayName: "Travel Drive"))
        XCTAssertEqual(ExternalROMFolderAvailability.current(store: store, rootURLProvider: { nil }),
                       .unavailable(displayName: "Travel Drive"))
        let disconnectedURL = temporaryRoot.appendingPathComponent("DriveRemoved")
        XCTAssertEqual(ExternalROMFolderAvailability.current(store: store, rootURLProvider: { disconnectedURL }),
                       .unavailable(displayName: "Travel Drive"))
    }

    func testAvailabilityReportsReachableFolder() throws {
        let store = ExternalROMFolderStore(defaults: defaults, key: "externalROMFolder")
        try store.save(ExternalROMFolder(bookmark: Data(), displayName: "Travel Drive"))

        XCTAssertEqual(ExternalROMFolderAvailability.current(store: store, rootURLProvider: { temporaryRoot }),
                       .available(displayName: "Travel Drive"))
    }
}
