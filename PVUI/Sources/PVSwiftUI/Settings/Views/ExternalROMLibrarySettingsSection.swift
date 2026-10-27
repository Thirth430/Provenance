//
//  ExternalROMLibrarySettingsSection.swift
//  PVSwiftUI
//

#if os(iOS)
import Foundation
import Observation
import SwiftUI
import UIKit
import PVLibrary
import PVFileSystem
import PVSystems
import PVThemes
import PVUIBase

/// Controls the optional, in-place ROM folder. The normal import queue remains the copy-import path.
struct ExternalROMLibrarySettingsSection: View {
    @State private var model = ExternalROMLibrarySettingsModel.shared
    @State private var showsFolderPicker = false
    @State private var showsReport = false
    @State private var showsCatalog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("EXTERNAL ROM FOLDER")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(LinearGradient(gradient: Gradient(colors: [.retroBlue, .retroPurple]),
                                                startPoint: .leading, endPoint: .trailing))

            Text("Use a folder from Files in place. ROMs stay on the USB drive or microSD card. " +
                 "Matched covers, metadata, saves, and save states stay in Provenance's app library; source files are unchanged.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))

            if let folderName = model.folderName {
                Label(folderName, systemImage: "externaldrive.fill")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(.white)

                Button {
                    model.discoverGames()
                } label: {
                    SettingsRow(title: "Quick scan folder", subtitle: "List supported games in nested folders without reading ROM data.",
                                icon: .sfSymbol("magnifyingglass"))
                }
                .buttonStyle(.plain)
                .disabled(model.isBusy)

                if !model.catalogEntries.isEmpty {
                    Button { showsCatalog = true } label: {
                        SettingsRow(title: "Browse discovered games (\(model.catalogEntries.count))",
                                    subtitle: "Verify and add only the games you want to play.",
                                    icon: .sfSymbol("list.bullet.rectangle"))
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isBusy)
                }

                Button {
                    model.fullScanAndAddAll()
                } label: {
                    SettingsRow(title: "Full scan and add all",
                                subtitle: "Refresh the folder, verify games, and reuse hashes for unchanged files.",
                                icon: .sfSymbol("arrow.triangle.2.circlepath"))
                }
                .buttonStyle(.plain)
                .disabled(model.isBusy)

                Button("Forget external folder", role: .destructive) { model.forgetFolder() }
                    .font(.footnote)
                    .disabled(model.isBusy)
            }

            Button {
                showsFolderPicker = true
            } label: {
                SettingsRow(title: model.folderName == nil ? "Use folder in place…" : "Choose a different folder…",
                            subtitle: "Select a directory in Files. This does not move or copy your games.",
                            icon: .sfSymbol("folder.badge.plus"))
            }
            .buttonStyle(.plain)
            .disabled(model.isBusy)

            if model.isBusy {
                HStack(spacing: 10) {
                    if let fraction = model.progressFraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                    }
                    Text(model.progressMessage)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(2)
                    Button("Cancel", role: .cancel) { model.cancel() }
                        .font(.caption)
                }
            } else if let summary = model.reportSummary {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.75))
                if !model.reportIssues.isEmpty {
                    Button("View scan report (\(model.reportIssues.count) issues)") { showsReport = true }
                        .font(.footnote)
                }
            }

            if let error = model.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            }

            Text("Quick scan lists supported files without reading ROM data. Play a discovered game to verify and add it. " +
                 "Full scan checks every discovered game and can take a while for unverified files; iOS may pause it when backgrounded. To copy games, use Import Games.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.4)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .sheet(isPresented: $showsFolderPicker) {
            ExternalROMFolderPicker { url in model.selectFolder(url) }
        }
        .sheet(isPresented: $showsReport) {
            NavigationStack {
                List(model.reportIssues, id: \.self) { issue in
                    Text(issue).font(.footnote).textSelection(.enabled)
                }
                .navigationTitle("External ROM Scan")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showsReport = false }
                    }
                }
            }
        }
        .sheet(isPresented: $showsCatalog) {
            NavigationStack {
                List {
                    if model.isBusy {
                        Section {
                            VStack(alignment: .leading, spacing: 8) {
                                if let fraction = model.progressFraction {
                                    ProgressView(value: fraction)
                                } else {
                                    ProgressView()
                                }
                                Text(model.progressMessage)
                                    .font(.caption)
                                Button("Cancel scan", role: .cancel) { model.cancel() }
                                    .font(.caption)
                            }
                        }
                    }
                    Section {
                        ForEach(model.catalogEntries) { entry in
                            ExternalROMCatalogRow(entry: entry, isBusy: model.isBusy) {
                                model.verifyAndLaunch(entry)
                            }
                        }
                    }
                }
                .navigationTitle("Discovered Games")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showsCatalog = false }
                    }
                }
            }
        }
    }
}

private struct ExternalROMCatalogRow: View {
    let entry: ExternalROMCatalogEntry
    let isBusy: Bool
    let onVerify: () -> Void

    private var status: String {
        if entry.isIndexed { return "In Provenance library" }
        if entry.isDuplicate { return "Exact duplicate already in library" }
        if entry.contentMD5 != nil { return "Verified; not yet added" }
        return "Not verified"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(URL(fileURLWithPath: entry.relativePath).deletingPathExtension().lastPathComponent)
                .font(.body.weight(.medium))
                .lineLimit(1)
            Text(entry.relativePath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(entry.contentMD5 == nil ? "Play · verify first" : "Play", action: onVerify)
                    .font(.caption.weight(.semibold))
                    .disabled(isBusy)
            }
            if let error = entry.lastError {
                Text(error).font(.caption2).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 3)
    }
}

@MainActor
@Observable
final class ExternalROMLibrarySettingsModel {
    static let shared = ExternalROMLibrarySettingsModel()
    private static let catalogSaveInterval = 8

    private(set) var folderName = ExternalROMFolderStore.shared.load()?.displayName
    private(set) var catalogEntries: [ExternalROMCatalogEntry] = []
    private(set) var isBusy = false
    private(set) var progressMessage = "Preparing…"
    private(set) var progressFraction: Double?
    private(set) var reportSummary: String?
    private(set) var reportIssues: [String] = []
    private(set) var errorMessage: String?
    private var currentIndexNumber = 0
    private var isIndexing = false
    private var catalog: ExternalROMCatalog?
    private var catalogWritesSinceSave = 0
    private var pendingLaunchPath: String?

    private var scanTask: Task<Void, Never>?
    private var scanProgress: Progress?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    init() {
        Task { await reloadCatalog() }
    }

    func selectFolder(_ url: URL) {
        do {
            let folder = try ExternalROMFolderAccessManager().select(url)
            folderName = folder.displayName
            catalog = .empty(for: folder)
            catalogEntries = []
            reportSummary = nil
            reportIssues = []
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func forgetFolder() {
        let previousFolder = ExternalROMFolderStore.shared.load()
        ExternalROMFolderStore.shared.clear()
        ExternalROMFolderRootAccess.shared.invalidate()
        folderName = nil
        catalog = nil
        catalogEntries = []
        reportSummary = nil
        reportIssues = []
        errorMessage = nil
        if let previousFolder {
            Task { try? await ExternalROMCatalogStore.shared.clear(folderIdentifier: previousFolder.identifier) }
        }
    }

    func cancel() {
        scanProgress?.cancel()
        scanTask?.cancel()
    }

    func discoverGames() {
        scanFolder(indexAllAfterDiscovery: false)
    }

    func fullScanAndAddAll() {
        scanFolder(indexAllAfterDiscovery: true)
    }

    private func scanFolder(indexAllAfterDiscovery: Bool) {
        guard !isBusy, folderName != nil else { return }
        isBusy = true
        isIndexing = false
        errorMessage = nil
        reportSummary = nil
        reportIssues = []
        progressMessage = "Opening external folder…"
        progressFraction = nil

        let progress = Progress(totalUnitCount: -1)
        scanProgress = progress
        beginBackgroundTask(name: "External ROM Folder Discovery", progress: progress)
        guard let folder = ExternalROMFolderStore.shared.load() else {
            fail("Select an external ROM folder first.")
            return
        }
        let systems = PVEmulatorConfiguration.availableSystemIdentifiers.compactMap { identifier -> ExternalROMSystem? in
            guard let extensions = PVEmulatorConfiguration.fileExtensions(forSystemIdentifier: identifier),
                  !extensions.isEmpty else { return nil }
            return ExternalROMSystem(identifier: identifier.rawValue, supportedExtensions: extensions)
        }

        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let access = try ExternalROMFolderAccessManager().openSavedFolder()
                let result = try ExternalROMScanner.scan(root: access.url,
                                                         systems: systems,
                                                         progress: progress,
                                                         onProgress: { visited in
                    Task { @MainActor [weak self] in
                        guard let self, self.isBusy, !self.isIndexing else { return }
                        self.progressMessage = "Scanning folders… \(visited) files checked"
                    }
                })

                guard !result.wasCancelled, !Task.isCancelled else {
                    await self?.finishDiscoveryCancelled(visitedFileCount: result.visitedFileCount)
                    withExtendedLifetime(access) {}
                    return
                }

                let updatedCatalog = try await ExternalROMCatalogStore.shared.replaceDiscovery(result.candidates,
                                                                                               for: folder)
                let issues = result.issues.map { "\($0.path): \($0.message)" }
                await self?.finishDiscovery(catalog: updatedCatalog,
                                            visitedFileCount: result.visitedFileCount,
                                            issues: issues,
                                            indexAllAfterDiscovery: indexAllAfterDiscovery)
                withExtendedLifetime(access) {}
            } catch {
                await self?.fail(error.localizedDescription)
            }
        }
    }

    func verifyAndLaunch(_ entry: ExternalROMCatalogEntry) {
        guard !isBusy else { return }
        pendingLaunchPath = entry.relativePath
        startIndexing(entries: [entry], priority: .userInitiated)
    }

    private func startIndexing(entries: [ExternalROMCatalogEntry],
                               priority: TaskPriority,
                               initialIssues: [String] = []) {
        guard !isBusy else { return }
        guard let folder = ExternalROMFolderStore.shared.load() else {
            fail("Select an external ROM folder first.")
            return
        }
        guard !entries.isEmpty else {
            reportSummary = "No supported games were found in the selected folder."
            return
        }

        isBusy = true
        isIndexing = true
        errorMessage = nil
        reportSummary = nil
        reportIssues = Array(initialIssues.prefix(500))
        progressMessage = "Preparing game verification…"
        progressFraction = 0
        currentIndexNumber = 0

        let progress = Progress(totalUnitCount: Int64(entries.count))
        scanProgress = progress
        beginBackgroundTask(name: "External ROM Verification", progress: progress)
        catalogWritesSinceSave = 0

        scanTask = Task.detached(priority: priority) { [weak self] in
            do {
                // Keep the folder permission active while verifying and indexing the selected files.
                let access = try ExternalROMFolderAccessManager().openSavedFolder()
                let candidates = entries.compactMap { $0.candidate(under: access.url) }
                guard candidates.count == entries.count else {
                    throw ExternalROMFolderError.unavailable("A discovered game has an unsafe or invalid relative path.")
                }
                let cachedHashes = entries.reduce(into: [String: String]()) { hashes, entry in
                    if let md5 = entry.contentMD5 { hashes[entry.relativePath] = md5 }
                }

                let indexReport = await ExternalROMLibraryIndexer().index(candidates,
                                                                           cachedMD5ByRelativePath: cachedHashes,
                                                                           progress: progress,
                                                                           onCandidateStarted: { candidate, current, total in
                    let size = ByteCountFormatter.string(fromByteCount: candidate.fileSize, countStyle: .file)
                    await MainActor.run { [weak self] in
                        self?.updateCurrentIndexProgress(fileName: candidate.url.lastPathComponent,
                                                         size: size,
                                                         current: current,
                                                         total: total)
                    }
                },
                                                                           onHashProgress: { candidate, current, total, bytesProcessed, totalBytes in
                    await MainActor.run { [weak self] in
                        self?.updateHashProgress(fileName: candidate.url.lastPathComponent,
                                                 current: current,
                                                 totalGames: total,
                                                 bytesProcessed: bytesProcessed,
                                                 totalBytes: totalBytes)
                    }
                },
                                                                           onHashCompleted: { candidate, md5 in
                    await self?.recordHash(candidate: candidate, md5: md5)
                },
                                                                           onCandidateIndexed: { candidate, md5, wasAdded in
                    await self?.recordIndexResult(candidate: candidate, md5: md5, wasAdded: wasAdded)
                },
                                                                           onProgress: { done, total in
                    await MainActor.run { [weak self] in
                        self?.updateIndexProgress(done: done, total: total)
                    }
                })

                await self?.persistCatalog()
                await self?.recordIssues(indexReport.issues)
                let issues = initialIssues + indexReport.issues.map { "\($0.relativePath): \($0.message)" }
                await self?.finish(report: indexReport, discoveredCount: candidates.count, issues: issues)
                withExtendedLifetime(access) {}
            } catch {
                await self?.fail(error.localizedDescription)
            }
        }
    }

    private func reloadCatalog() async {
        guard let folder = ExternalROMFolderStore.shared.load() else { return }
        do {
            let loadedCatalog = try await ExternalROMCatalogStore.shared.load(for: folder)
            catalog = loadedCatalog
            catalogEntries = loadedCatalog.entries.sorted {
                $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            }
        } catch {
            errorMessage = "Couldn't read the saved external game list: \(error.localizedDescription)"
        }
    }

    private func finishDiscovery(catalog: ExternalROMCatalog,
                                 visitedFileCount: Int,
                                 issues: [String],
                                 indexAllAfterDiscovery: Bool) {
        self.catalog = catalog
        catalogEntries = catalog.entries.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
        isBusy = false
        isIndexing = false
        scanTask = nil
        scanProgress = nil
        progressFraction = nil
        reportIssues = Array(issues.prefix(500))
        reportSummary = "Quick scan found \(catalog.entries.count) supported games after checking \(visitedFileCount) files. ROM contents were not read."
        endBackgroundTask()
        if indexAllAfterDiscovery {
            guard !catalogEntries.isEmpty else {
                reportSummary = "Full scan found no supported games after checking \(visitedFileCount) files."
                return
            }
            startIndexing(entries: catalogEntries, priority: .utility, initialIssues: issues)
        }
    }

    private func finishDiscoveryCancelled(visitedFileCount: Int) {
        isBusy = false
        isIndexing = false
        scanTask = nil
        scanProgress = nil
        progressFraction = nil
        reportSummary = "Quick scan cancelled after checking \(visitedFileCount) files. The previous saved game list was kept."
        endBackgroundTask()
    }

    private func recordHash(candidate: ExternalROMCandidate, md5: String) async {
        guard isBusy else { return }
        progressMessage = "Reading complete. Registering \(candidate.url.lastPathComponent) in the library…"
        progressFraction = nil
        updateEntry(candidate.relativePath) { entry in
            if let existingMD5 = entry.contentMD5, existingMD5.caseInsensitiveCompare(md5) != .orderedSame {
                entry.isIndexed = false
                entry.isDuplicate = false
            }
            entry.contentMD5 = md5
            entry.lastError = nil
        }
        await saveCatalogPeriodically()
    }

    private func recordIndexResult(candidate: ExternalROMCandidate, md5: String, wasAdded: Bool) async {
        updateEntry(candidate.relativePath) { entry in
            entry.contentMD5 = md5
            let wasAlreadyIndexed = entry.isIndexed
            entry.isIndexed = wasAdded || wasAlreadyIndexed
            entry.isDuplicate = !wasAdded && !wasAlreadyIndexed
            entry.lastError = nil
        }
        await saveCatalogPeriodically()
        if wasAdded {
            // Realm-backed console views can show each game as soon as it is committed,
            // instead of waiting for metadata lookup or the rest of a large batch.
            NotificationCenter.default.post(name: .gameLibraryDidUpdate, object: nil)
        }
        if pendingLaunchPath == candidate.relativePath {
            pendingLaunchPath = nil
            AppState.shared.appOpenAction = .openMD5(md5)
        }
    }

    private func recordIssues(_ issues: [ExternalROMIndexIssue]) async {
        for issue in issues {
            updateEntry(issue.relativePath) { entry in entry.lastError = issue.message }
        }
        await persistCatalog()
    }

    private func updateEntry(_ path: String, change: (inout ExternalROMCatalogEntry) -> Void) {
        guard let index = catalogEntries.firstIndex(where: { $0.relativePath == path }) else { return }
        change(&catalogEntries[index])
        catalog?.entries = catalogEntries
        catalogWritesSinceSave += 1
    }

    private func saveCatalogPeriodically() async {
        guard catalogWritesSinceSave >= Self.catalogSaveInterval else { return }
        catalogWritesSinceSave = 0
        await persistCatalog()
    }

    private func persistCatalog() async {
        guard let catalog else { return }
        do {
            try await ExternalROMCatalogStore.shared.save(catalog)
            catalogWritesSinceSave = 0
        } catch {
            errorMessage = "Couldn't save scan progress: \(error.localizedDescription)"
        }
    }

    private func beginBackgroundTask(name: String, progress: Progress) {
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            Task { @MainActor in
                self?.scanProgress?.cancel()
                self?.endBackgroundTask()
            }
        }
        progress.cancellationHandler = { [weak self] in
            Task { @MainActor in self?.scanTask?.cancel() }
        }
    }

    private func updateIndexProgress(done: Int, total: Int) {
        guard isBusy else { return }
        progressMessage = done >= total
            ? "Finished checking \(done) of \(total) games."
            : "Processed \(done) of \(total) games; checking the remaining ROMs…"
        let fraction = total == 0 ? 1 : Double(done) / Double(total)
        progressFraction = max(progressFraction ?? 0, fraction)
    }

    private func updateCurrentIndexProgress(fileName: String,
                                            size: String,
                                            current: Int,
                                            total: Int) {
        guard isBusy, current >= currentIndexNumber else { return }
        currentIndexNumber = current
        progressMessage = "Verifying game \(current) of \(total): \(fileName) (\(size))…"
        progressFraction = nil
    }

    private func updateHashProgress(fileName: String,
                                    current: Int,
                                    totalGames: Int,
                                    bytesProcessed: Int64,
                                    totalBytes: Int64) {
        guard isBusy else { return }
        let percent = min(100, Int((Double(bytesProcessed) / Double(max(1, totalBytes))) * 100))
        let processed = ByteCountFormatter.string(fromByteCount: bytesProcessed, countStyle: .file)
        let formattedTotalBytes = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        progressMessage = "Reading game \(current) of \(totalGames): \(fileName)… \(percent)% (\(processed) of \(formattedTotalBytes))"
    }

    private func finish(report: ExternalROMIndexReport, discoveredCount: Int, issues: [String]) {
        isBusy = false
        isIndexing = false
        scanTask = nil
        scanProgress = nil
        progressFraction = nil
        reportIssues = Array(issues.prefix(500))
        pendingLaunchPath = nil
        reportSummary = report.wasCancelled
            ? "Scan cancelled after \(report.processedCount) of \(discoveredCount) games. Added \(report.indexedCount); skipped \(report.duplicateCount)."
            : "Found \(discoveredCount) games. Added \(report.indexedCount); skipped \(report.duplicateCount) duplicates. " +
                "\(issues.count) issue(s). Metadata and cover art are looked up after games are added."
        endBackgroundTask()
    }

    private func fail(_ message: String) {
        isBusy = false
        isIndexing = false
        scanTask = nil
        scanProgress = nil
        progressFraction = nil
        errorMessage = message
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }
}

/// Main library destination for name-only discoveries, including systems with no imported games yet.
@MainActor
struct ExternalROMCatalogLibraryView: View {
    @State private var model = ExternalROMLibrarySettingsModel.shared

    var body: some View {
        List {
            if let folderName = model.folderName {
                Section {
                    Label("\(folderName) · Quick scan", systemImage: "externaldrive")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("These games are listed from file names. They are not fully verified or added until you play one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if model.isBusy {
                Section {
                    HStack {
                        ProgressView()
                        Text(model.progressMessage).font(.caption)
                        Spacer()
                        Button("Cancel", role: .cancel) { model.cancel() }
                    }
                }
            }
            Section("External folder games") {
                ForEach(model.catalogEntries) { entry in
                    ExternalROMCatalogRow(entry: entry, isBusy: model.isBusy) {
                        model.verifyAndLaunch(entry)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(RetroTheme.retroBackground)
        .navigationTitle("External Games")
    }
}

private struct ExternalROMFolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}
#endif
