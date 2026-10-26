//
//  ExternalROMLibraryIndexer.swift
//  PVLibrary
//

import Foundation
import PVFileSystem
import PVSystems

public struct ExternalROMIndexIssue: Sendable, Equatable {
    public let relativePath: String
    public let message: String
}

public struct ExternalROMIndexReport: Sendable, Equatable {
    public let indexedCount: Int
    public let duplicateCount: Int
    public let issues: [ExternalROMIndexIssue]
    public let processedCount: Int
    public let wasCancelled: Bool
}

/// Adds scanned external ROM files to the existing Provenance database without using the copy importer.
public struct ExternalROMLibraryIndexer {
    private let databaseService: any GameImporterDatabaseServicing

    public init(databaseService: any GameImporterDatabaseServicing = GameImporter.shared.databaseService) {
        self.databaseService = databaseService
    }

    /// Indexes candidates one at a time so a large library has bounded memory and can be cancelled.
    /// Ambiguous extensions are reported unless `systemOverrides` selects one detected system.
    public func index(_ candidates: [ExternalROMCandidate],
                      systemOverrides: [String: String] = [:],
                      progress: Progress? = nil,
                      onCandidateStarted: (@Sendable (ExternalROMCandidate, Int, Int) -> Void)? = nil,
                      onProgress: (@Sendable (Int, Int) -> Void)? = nil) async -> ExternalROMIndexReport {
        if let progress, progress.totalUnitCount <= 0 {
            progress.totalUnitCount = Int64(candidates.count)
        }

        var indexedCount = 0
        var duplicateCount = 0
        var issues: [ExternalROMIndexIssue] = []
        var processedCount = 0
        var wasCancelled = false

        for candidate in candidates {
            if progress?.isCancelled == true || Task.isCancelled {
                wasCancelled = true
                break
            }

            guard let systemID = Self.systemIdentifier(for: candidate, override: systemOverrides[candidate.relativePath]) else {
                let message = candidate.systemIdentifiers.isEmpty
                    ? "No installed Provenance system accepts this file."
                    : "More than one system accepts this extension. Choose a system before indexing."
                issues.append(ExternalROMIndexIssue(relativePath: candidate.relativePath, message: message))
                processedCount += 1
                progress?.completedUnitCount = Int64(processedCount)
                onProgress?(processedCount, candidates.count)
                continue
            }

            onCandidateStarted?(candidate, processedCount + 1, candidates.count)
            do {
                if try await databaseService.indexExternalGame(candidate, systemID: systemID, progress: progress) {
                    indexedCount += 1
                } else {
                    duplicateCount += 1
                }
            } catch is CancellationError {
                wasCancelled = true
                break
            } catch {
                issues.append(ExternalROMIndexIssue(relativePath: candidate.relativePath,
                                                   message: error.localizedDescription))
            }

            processedCount += 1
            progress?.completedUnitCount = Int64(processedCount)
            onProgress?(processedCount, candidates.count)
        }

        return ExternalROMIndexReport(indexedCount: indexedCount,
                                      duplicateCount: duplicateCount,
                                      issues: issues,
                                      processedCount: processedCount,
                                      wasCancelled: wasCancelled || progress?.isCancelled == true)
    }

    private static func systemIdentifier(for candidate: ExternalROMCandidate, override: String?) -> SystemIdentifier? {
        if let override,
           candidate.systemIdentifiers.contains(override) {
            return SystemIdentifier(rawValue: override)
        }
        guard candidate.systemIdentifiers.count == 1,
              let detected = candidate.systemIdentifiers.first else { return nil }
        return SystemIdentifier(rawValue: detected)
    }
}
