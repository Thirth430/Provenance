//
//  ExternalROMCatalog.swift
//  PVFileSystem
//

import Foundation

/// A fast, persistent inventory entry. A content hash is filled only when a game is verified.
public struct ExternalROMCatalogEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: String { relativePath }
    public let relativePath: String
    public let systemIdentifiers: [String]
    public let fileSize: Int64
    public let modificationDate: Date?
    public var contentMD5: String?
    public var isIndexed: Bool
    public var isDuplicate: Bool
    public var lastError: String?

    public init(relativePath: String,
                systemIdentifiers: [String],
                fileSize: Int64,
                modificationDate: Date?,
                contentMD5: String? = nil,
                isIndexed: Bool = false,
                isDuplicate: Bool = false,
                lastError: String? = nil) {
        self.relativePath = relativePath
        self.systemIdentifiers = systemIdentifiers
        self.fileSize = fileSize
        self.modificationDate = modificationDate
        self.contentMD5 = contentMD5
        self.isIndexed = isIndexed
        self.isDuplicate = isDuplicate
        self.lastError = lastError
    }

    /// A saved hash is reused only when both size and modification time are available and unchanged.
    public func hasSameFingerprint(as candidate: ExternalROMCandidate) -> Bool {
        guard let modificationDate, let candidateDate = candidate.modificationDate else { return false }
        return fileSize == candidate.fileSize && modificationDate == candidateDate
    }

    /// Rebuilds a candidate under the selected root, rejecting unsafe paths from a damaged catalog.
    public func candidate(under rootURL: URL) -> ExternalROMCandidate? {
        guard ExternalROMPath.partialPath(forRelativePath: relativePath) != nil else { return nil }
        return ExternalROMCandidate(url: rootURL.appendingPathComponent(relativePath).standardizedFileURL,
                                    relativePath: relativePath,
                                    systemIdentifiers: systemIdentifiers,
                                    fileSize: fileSize,
                                    modificationDate: modificationDate)
    }
}

/// The discovered external folder inventory. It contains paths and metadata, never ROM contents.
public struct ExternalROMCatalog: Codable, Equatable, Sendable {
    public let folderIdentifier: UUID
    public var scannedAt: Date
    public var entries: [ExternalROMCatalogEntry]

    public init(folderIdentifier: UUID, scannedAt: Date = Date(), entries: [ExternalROMCatalogEntry] = []) {
        self.folderIdentifier = folderIdentifier
        self.scannedAt = scannedAt
        self.entries = entries
    }

    public static func empty(for folder: ExternalROMFolder) -> Self {
        Self(folderIdentifier: folder.identifier)
    }
}

/// App-managed persistence for the external inventory and completed hashes.
public actor ExternalROMCatalogStore {
    public static let shared = ExternalROMCatalogStore()

    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                              in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                    .appendingPathComponent("Library", isDirectory: true)
                    .appendingPathComponent("Application Support", isDirectory: true)
            self.fileURL = applicationSupport
                .appendingPathComponent("Provenance", isDirectory: true)
                .appendingPathComponent("ExternalROMCatalog.json", isDirectory: false)
        }
    }

    public func load(for folder: ExternalROMFolder) throws -> ExternalROMCatalog {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .empty(for: folder) }
        let data = try Data(contentsOf: fileURL)
        let catalog = try JSONDecoder().decode(ExternalROMCatalog.self, from: data)
        guard catalog.folderIdentifier == folder.identifier else { return .empty(for: folder) }
        return catalog
    }

    /// Replaces a completed name-only scan while preserving hashes for unchanged files.
    public func replaceDiscovery(_ candidates: [ExternalROMCandidate],
                                 for folder: ExternalROMFolder) throws -> ExternalROMCatalog {
        let previous = try load(for: folder)
        var previousByPath: [String: ExternalROMCatalogEntry] = [:]
        for entry in previous.entries where previousByPath[entry.relativePath] == nil {
            previousByPath[entry.relativePath] = entry
        }
        let entries = candidates.map { candidate -> ExternalROMCatalogEntry in
            guard let oldEntry = previousByPath[candidate.relativePath],
                  oldEntry.hasSameFingerprint(as: candidate) else {
                return ExternalROMCatalogEntry(relativePath: candidate.relativePath,
                                               systemIdentifiers: candidate.systemIdentifiers,
                                               fileSize: candidate.fileSize,
                                               modificationDate: candidate.modificationDate)
            }

            return ExternalROMCatalogEntry(relativePath: candidate.relativePath,
                                           systemIdentifiers: candidate.systemIdentifiers,
                                           fileSize: candidate.fileSize,
                                           modificationDate: candidate.modificationDate,
                                           contentMD5: oldEntry.contentMD5,
                                           isIndexed: oldEntry.isIndexed,
                                           isDuplicate: oldEntry.isDuplicate)
        }
        let catalog = ExternalROMCatalog(folderIdentifier: folder.identifier, entries: entries)
        try save(catalog)
        return catalog
    }

    public func save(_ catalog: ExternalROMCatalog) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(catalog).write(to: fileURL, options: .atomic)
    }

    /// Clears only this folder's catalog, so a delayed cleanup can't erase a newly selected folder.
    public func clear(folderIdentifier: UUID) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let data = try Data(contentsOf: fileURL)
        let catalog = try JSONDecoder().decode(ExternalROMCatalog.self, from: data)
        guard catalog.folderIdentifier == folderIdentifier else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}
