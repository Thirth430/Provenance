//
//  ExternalROMScanner.swift
//  PVFileSystem
//

import Foundation

/// A system and the file extensions the installed Provenance configuration accepts for it.
public struct ExternalROMSystem: Sendable {
    public let identifier: String
    public let supportedExtensions: Set<String>

    public init(identifier: String, supportedExtensions: some Sequence<String>) {
        self.identifier = identifier
        self.supportedExtensions = Set(supportedExtensions.map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        })
    }
}

/// A supported file discovered below an external library root.
public struct ExternalROMCandidate: Sendable, Equatable {
    public let url: URL
    /// Path below the selected folder, using `/` separators and preserving source folder names.
    public let relativePath: String
    public let systemIdentifiers: [String]
    public let fileSize: Int64

    fileprivate init(url: URL, relativePath: String, systemIdentifiers: [String], fileSize: Int64) {
        self.url = url
        self.relativePath = relativePath
        self.systemIdentifiers = systemIdentifiers
        self.fileSize = fileSize
    }
}

public struct ExternalROMScanIssue: Sendable, Equatable {
    public let path: String
    public let message: String
}

public struct ExternalROMScanResult: Sendable, Equatable {
    public let candidates: [ExternalROMCandidate]
    public let issues: [ExternalROMScanIssue]
    public let visitedFileCount: Int
    public let wasCancelled: Bool
}

/// Recursively discovers supported ROMs without reading ROM contents or changing the source folder.
public enum ExternalROMScanner {
    /// Scans a selected root. `Progress.totalUnitCount` remains indeterminate because the number of
    /// nested entries is not known without a second traversal; `completedUnitCount` reports entries visited.
    public static func scan(root: URL,
                            systems: [ExternalROMSystem],
                            progress: Progress? = nil,
                            onProgress: (@Sendable (Int) -> Void)? = nil,
                            fileManager: FileManager = .default) throws -> ExternalROMScanResult {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            throw ExternalROMFolderError.unavailable(root.path)
        }
        guard isDirectory.boolValue else { throw ExternalROMFolderError.notDirectory(root.path) }

        var systemsByExtension: [String: Set<String>] = [:]
        for system in systems {
            for fileExtension in system.supportedExtensions {
                systemsByExtension[fileExtension, default: []].insert(system.identifier)
            }
        }

        var candidates: [ExternalROMCandidate] = []
        var issues: [ExternalROMScanIssue] = []
        var visitedFileCount = 0
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isPackageKey, .fileSizeKey]
        let enumerator = fileManager.enumerator(at: root,
                                                includingPropertiesForKeys: keys,
                                                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                errorHandler: { url, error in
            issues.append(ExternalROMScanIssue(path: url.path, message: error.localizedDescription))
            return true
        })

        while let url = enumerator?.nextObject() as? URL {
            if progress?.isCancelled == true { break }
            visitedFileCount += 1
            progress?.completedUnitCount = Int64(visitedFileCount)
            onProgress?(visitedFileCount)

            do {
                let values = try url.resourceValues(forKeys: Set(keys))
                if values.isPackage == true { enumerator?.skipDescendants() }
                guard values.isRegularFile == true else { continue }
                let fileExtension = url.pathExtension.lowercased()
                // Provenance's launch path extracts ZIPs into app-managed save storage for cores
                // that request it. In-place mode must never make that copy implicitly.
                if fileExtension == "zip" {
                    issues.append(ExternalROMScanIssue(path: url.path,
                                                       message: "ZIP archives are skipped in folder-in-place mode. Use the copy importer to unpack this archive."))
                    continue
                }
                guard let systemIDs = systemsByExtension[fileExtension], !systemIDs.isEmpty else { continue }

                let relativePath = url.standardizedFileURL.pathComponents
                    .dropFirst(root.standardizedFileURL.pathComponents.count)
                    .joined(separator: "/")
                candidates.append(ExternalROMCandidate(url: url.standardizedFileURL,
                                                       relativePath: relativePath,
                                                       systemIdentifiers: systemIDs.sorted(),
                                                       fileSize: Int64(values.fileSize ?? 0)))
            } catch {
                issues.append(ExternalROMScanIssue(path: url.path, message: error.localizedDescription))
            }
        }

        return ExternalROMScanResult(candidates: candidates.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending },
                                     issues: issues,
                                     visitedFileCount: visitedFileCount,
                                     wasCancelled: progress?.isCancelled == true)
    }
}

public struct ExternalROMDuplicateGroup: Sendable, Equatable {
    public let md5: String
    public let candidates: [ExternalROMCandidate]
    public let matchesExistingGame: Bool
}

/// Groups candidates by Provenance's content identity once hashes are available.
public enum ExternalROMDuplicateDetector {
    public static func groups(candidates: [ExternalROMCandidate],
                              md5ByRelativePath: [String: String],
                              existingGameMD5s: Set<String> = []) -> [ExternalROMDuplicateGroup] {
        var candidatesByMD5: [String: [ExternalROMCandidate]] = [:]
        let normalizedExistingMD5s = Set(existingGameMD5s.map { $0.lowercased() })
        for candidate in candidates {
            guard let md5 = md5ByRelativePath[candidate.relativePath]?.lowercased(), !md5.isEmpty else { continue }
            candidatesByMD5[md5, default: []].append(candidate)
        }

        return candidatesByMD5
            .filter { $0.value.count > 1 || normalizedExistingMD5s.contains($0.key) }
            .map { md5, matches in
                ExternalROMDuplicateGroup(md5: md5,
                                          candidates: matches.sorted { $0.relativePath < $1.relativePath },
                                          matchesExistingGame: normalizedExistingMD5s.contains(md5))
            }
            .sorted { $0.md5 < $1.md5 }
    }
}
