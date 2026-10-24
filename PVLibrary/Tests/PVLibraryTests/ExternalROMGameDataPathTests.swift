import Foundation
import XCTest
@testable import PVLibrary

final class ExternalROMGameDataPathTests: XCTestCase {
    func testExternalSavesUseSystemAndContentIdentityInsteadOfROMFilename() throws {
        let root = URL(fileURLWithPath: "/app/Documents/Saves", isDirectory: true)

        let first = try XCTUnwrap(PVEmulatorConfiguration.externalGameDataDirectory(
            forPartialPath: "ExternalROMs/Console A/Shared Name.nes",
            md5: "AABBCC",
            systemIdentifier: "com.provenance.nes",
            under: root
        ))
        let second = try XCTUnwrap(PVEmulatorConfiguration.externalGameDataDirectory(
            forPartialPath: "ExternalROMs/Console B/Shared Name.nes",
            md5: "DDEEFF",
            systemIdentifier: "com.provenance.nes",
            under: root
        ))

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.lastPathComponent, "aabbcc")
        XCTAssertEqual(first.deletingLastPathComponent().lastPathComponent, "com.provenance.nes")
        XCTAssertTrue(first.path.hasPrefix(root.appendingPathComponent("ExternalROMs").path))
    }

    func testNonExternalPathsKeepExistingSavePathBehavior() {
        let root = URL(fileURLWithPath: "/app/Documents/Saves", isDirectory: true)
        XCTAssertNil(PVEmulatorConfiguration.externalGameDataDirectory(
            forPartialPath: "com.provenance.nes/Shared Name.nes",
            md5: "AABBCC",
            systemIdentifier: "com.provenance.nes",
            under: root
        ))
    }
}
