//
//  ExternalROMLibraryIndexer.swift
//  PVLibrary
//

import Foundation
import PVFileSystem
import PVSystems
import PVHashing

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

private struct ExternalROMHashWork: Sendable {
    let candidate: ExternalROMCandidate
    let systemIdentifier: String
    let ordinal: Int
}

private struct ExternalROMHashOutcome: Sendable {
    let work: ExternalROMHashWork
    let md5: String?
    let errorMessage: String?
    let wasCancelled: Bool
}

/// Adds scanned external ROM files to the existing Provenance database without using the copy importer.
public struct ExternalROMLibraryIndexer {
    /// Two concurrent sequential reads overlap storage latency without creating an unbounded I/O queue.
    /// Database deduplication and writes remain serialized in this type.
    public static let maximumConcurrentHashes = 2

    private let databaseService: any GameImporterDatabaseServicing
    private let hashOperation: @Sendable (ExternalROMCandidate,
                                          Progress?,
                                          @Sendable (Int64, Int64) async -> Void) async throws -> String

    public init(databaseService: any GameImporterDatabaseServicing = GameImporter.shared.databaseService,
                hashOperation: (@Sendable (ExternalROMCandidate,
                                           Progress?,
                                           @Sendable (Int64, Int64) async -> Void) async throws -> String)? = nil) {
        self.databaseService = databaseService
        self.hashOperation = hashOperation ?? Self.hashExternalROM
    }

    /// Hashes up to two files concurrently, then performs identity checks and library writes one at a time.
    /// Ambiguous extensions are reported unless `systemOverrides` selects one detected system.
    public func index(_ candidates: [ExternalROMCandidate],
                      systemOverrides: [String: String] = [:],
                      cachedMD5ByRelativePath: [String: String] = [:],
                      progress: Progress? = nil,
                      onCandidateStarted: (@Sendable (ExternalROMCandidate, Int, Int) async -> Void)? = nil,
                      onHashProgress: (@Sendable (ExternalROMCandidate, Int, Int, Int64, Int64) async -> Void)? = nil,
                      onHashCompleted: (@Sendable (ExternalROMCandidate, String) async -> Void)? = nil,
                      onCandidateIndexed: (@Sendable (ExternalROMCandidate, String, Bool) async -> Void)? = nil,
                      onProgress: (@Sendable (Int, Int) async -> Void)? = nil) async -> ExternalROMIndexReport {
        if let progress, progress.totalUnitCount <= 0 {
            progress.totalUnitCount = Int64(candidates.count)
        }

        var indexedCount = 0
        var duplicateCount = 0
        var issues: [ExternalROMIndexIssue] = []
        var processedCount = 0
        var wasCancelled = false
        var workItems: [ExternalROMHashWork] = []

        for (ordinal, candidate) in candidates.enumerated() {
            guard let systemID = Self.systemIdentifier(for: candidate,
                                                       override: systemOverrides[candidate.relativePath]) else {
                let message = candidate.systemIdentifiers.isEmpty
                    ? "No installed Provenance system accepts this file."
                    : "More than one system accepts this extension. Choose a system before indexing."
                issues.append(ExternalROMIndexIssue(relativePath: candidate.relativePath, message: message))
                processedCount += 1
                progress?.completedUnitCount = Int64(processedCount)
                await onProgress?(processedCount, candidates.count)
                continue
            }
            workItems.append(ExternalROMHashWork(candidate: candidate,
                                                 systemIdentifier: systemID.rawValue,
                                                 ordinal: ordinal + 1))
        }

        var nextWorkIndex = 0
        await withTaskGroup(of: ExternalROMHashOutcome.self) { group in
            while nextWorkIndex < min(Self.maximumConcurrentHashes, workItems.count),
                  progress?.isCancelled != true,
                  !Task.isCancelled {
                let work = workItems[nextWorkIndex]
                nextWorkIndex += 1
                await onCandidateStarted?(work.candidate, work.ordinal, candidates.count)
                let hashOperation = self.hashOperation
                let cachedMD5 = cachedMD5ByRelativePath[work.candidate.relativePath]
                group.addTask {
                    await Self.hashOutcome(for: work,
                                           cachedMD5: cachedMD5,
                                           totalCandidates: candidates.count,
                                           progress: progress,
                                           hashOperation: hashOperation,
                                           onHashProgress: onHashProgress)
                }
            }

            while let outcome = await group.next() {
                if progress?.isCancelled == true || Task.isCancelled || outcome.wasCancelled {
                    wasCancelled = true
                    group.cancelAll()
                    break
                }

                // Start another read before the serial database work to keep the external drive busy.
                if nextWorkIndex < workItems.count {
                    let work = workItems[nextWorkIndex]
                    nextWorkIndex += 1
                    await onCandidateStarted?(work.candidate, work.ordinal, candidates.count)
                    let hashOperation = self.hashOperation
                    let cachedMD5 = cachedMD5ByRelativePath[work.candidate.relativePath]
                    group.addTask {
                        await Self.hashOutcome(for: work,
                                               cachedMD5: cachedMD5,
                                               totalCandidates: candidates.count,
                                               progress: progress,
                                               hashOperation: hashOperation,
                                               onHashProgress: onHashProgress)
                    }
                }

                if let md5 = outcome.md5,
                   let systemID = SystemIdentifier(rawValue: outcome.work.systemIdentifier) {
                    do {
                        await onHashCompleted?(outcome.work.candidate, md5)
                        let wasAdded = try await databaseService.indexExternalGame(outcome.work.candidate,
                                                                                   systemID: systemID,
                                                                                   contentMD5: md5,
                                                                                   progress: progress)
                        await onCandidateIndexed?(outcome.work.candidate, md5, wasAdded)
                        if wasAdded {
                            indexedCount += 1
                        } else {
                            duplicateCount += 1
                        }
                    } catch is CancellationError {
                        wasCancelled = true
                        group.cancelAll()
                        break
                    } catch {
                        issues.append(ExternalROMIndexIssue(relativePath: outcome.work.candidate.relativePath,
                                                           message: error.localizedDescription))
                    }
                } else if let errorMessage = outcome.errorMessage {
                    issues.append(ExternalROMIndexIssue(relativePath: outcome.work.candidate.relativePath,
                                                       message: errorMessage))
                }

                processedCount += 1
                progress?.completedUnitCount = Int64(processedCount)
                await onProgress?(processedCount, candidates.count)
            }
        }

        return ExternalROMIndexReport(indexedCount: indexedCount,
                                      duplicateCount: duplicateCount,
                                      issues: issues,
                                      processedCount: processedCount,
                                      wasCancelled: wasCancelled || progress?.isCancelled == true)
    }

    private static func hashOutcome(for work: ExternalROMHashWork,
                                    cachedMD5: String?,
                                    totalCandidates: Int,
                                    progress: Progress?,
                                    hashOperation: @Sendable (ExternalROMCandidate,
                                                              Progress?,
                                                              @Sendable (Int64, Int64) async -> Void) async throws -> String,
                                    onHashProgress: (@Sendable (ExternalROMCandidate, Int, Int, Int64, Int64) async -> Void)?) async -> ExternalROMHashOutcome {
        if let cachedMD5 = cachedMD5?.trimmingCharacters(in: .whitespacesAndNewlines),
           !cachedMD5.isEmpty,
           let scannedModificationDate = work.candidate.modificationDate,
           let currentValues = try? work.candidate.url.resourceValues(forKeys: [.isRegularFileKey,
                                                                                .fileSizeKey,
                                                                                .contentModificationDateKey]),
           currentValues.isRegularFile == true,
           Int64(currentValues.fileSize ?? -1) == work.candidate.fileSize,
           currentValues.contentModificationDate == scannedModificationDate {
            return ExternalROMHashOutcome(work: work,
                                          md5: cachedMD5.uppercased(),
                                          errorMessage: nil,
                                          wasCancelled: false)
        }
        do {
            let hash = try await hashOperation(work.candidate, progress) { bytesProcessed, totalBytes in
                await onHashProgress?(work.candidate, work.ordinal, totalCandidates, bytesProcessed, totalBytes)
            }
            return ExternalROMHashOutcome(work: work, md5: hash.uppercased(), errorMessage: nil, wasCancelled: false)
        } catch is CancellationError {
            return ExternalROMHashOutcome(work: work, md5: nil, errorMessage: nil, wasCancelled: true)
        } catch {
            return ExternalROMHashOutcome(work: work,
                                          md5: nil,
                                          errorMessage: error.localizedDescription,
                                          wasCancelled: false)
        }
    }

    private static func hashExternalROM(_ candidate: ExternalROMCandidate,
                                        progress: Progress?,
                                        onProgress: @Sendable (Int64, Int64) async -> Void) async throws -> String {
        let access = try ExternalROMFolderAccessManager().openSavedFolder()
        defer { withExtendedLifetime(access) {} }

        guard ExternalROMPath.partialPath(forRelativePath: candidate.relativePath) != nil else {
            throw ExternalROMFolderError.unavailable("The scanned game has an invalid relative path.")
        }
        let relativePath = candidate.relativePath
        let sourceURL = access.url.appendingPathComponent(relativePath).standardizedFileURL
        guard sourceURL == candidate.url.standardizedFileURL else {
            throw ExternalROMFolderError.unavailable("The game is no longer at its scanned location.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw ExternalROMFolderError.unavailable(sourceURL.path)
        }
        let initialValues = try sourceURL.resourceValues(forKeys: [.isRegularFileKey,
                                                                   .fileSizeKey,
                                                                   .contentModificationDateKey])
        guard initialValues.isRegularFile == true,
              Int64(initialValues.fileSize ?? -1) == candidate.fileSize,
              candidate.modificationDate == nil || initialValues.contentModificationDate == candidate.modificationDate else {
            throw ExternalROMFolderError.unavailable("\(candidate.relativePath) changed after the folder scan. Run Quick scan again.")
        }

        var result: String?
        var lastProgressBucket = -1
        let stream = FileManager.default.md5StreamForFile(at: sourceURL, fromOffset: 0)
        for try await event in stream {
            if Task.isCancelled || progress?.isCancelled == true { throw CancellationError() }
            switch event {
            case .progress(let bytesProcessed, let totalBytes):
                guard totalBytes > 0 else { continue }
                let bucket = min(10, Int((Double(bytesProcessed) / Double(totalBytes)) * 10))
                if bucket > lastProgressBucket {
                    lastProgressBucket = bucket
                    await onProgress(bytesProcessed, totalBytes)
                }
            case .completed(let hash):
                result = hash
                let total = (try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? candidate.fileSize
                if total > 0 { await onProgress(total, total) }
            }
        }
        guard let result, !result.isEmpty else { throw GameImporterError.couldNotCalculateMD5 }
        let finalValues = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard Int64(finalValues.fileSize ?? -1) == Int64(initialValues.fileSize ?? -1),
              finalValues.contentModificationDate == initialValues.contentModificationDate else {
            throw ExternalROMFolderError.unavailable("\(candidate.relativePath) changed while it was being verified. Run Quick scan again.")
        }
        return result
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
