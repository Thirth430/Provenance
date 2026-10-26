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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("EXTERNAL ROM FOLDER")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(LinearGradient(gradient: Gradient(colors: [.retroBlue, .retroPurple]),
                                                startPoint: .leading, endPoint: .trailing))

            Text("Use a folder from Files in place. ROMs stay on the USB drive or microSD card. Matched covers and metadata, saves, and save states stay in Provenance's app library; source files are left unchanged.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))

            if let folderName = model.folderName {
                Label(folderName, systemImage: "externaldrive.fill")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(.white)

                Button {
                    model.scanAndIndex()
                } label: {
                    SettingsRow(title: "Scan external folder", subtitle: "Find supported games in nested folders and add them without copying.",
                                icon: .sfSymbol("magnifyingglass"))
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

            Text("To copy games into Provenance instead, use the existing Import Games action in the library.")
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
    }
}

@MainActor
@Observable
private final class ExternalROMLibrarySettingsModel {
    static let shared = ExternalROMLibrarySettingsModel()

    private(set) var folderName = ExternalROMFolderStore.shared.load()?.displayName
    private(set) var isBusy = false
    private(set) var progressMessage = "Preparing…"
    private(set) var progressFraction: Double?
    private(set) var reportSummary: String?
    private(set) var reportIssues: [String] = []
    private(set) var errorMessage: String?
    private var currentIndexNumber = 0
    private var totalIndexCount = 0
    private var currentIndexRelativePath: String?

    private var scanTask: Task<Void, Never>?
    private var scanProgress: Progress?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    func selectFolder(_ url: URL) {
        do {
            let folder = try ExternalROMFolderAccessManager().select(url)
            folderName = folder.displayName
            reportSummary = nil
            reportIssues = []
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func forgetFolder() {
        ExternalROMFolderStore.shared.clear()
        ExternalROMFolderRootAccess.shared.invalidate()
        folderName = nil
        reportSummary = nil
        reportIssues = []
        errorMessage = nil
    }

    func cancel() {
        scanProgress?.cancel()
        scanTask?.cancel()
    }

    func scanAndIndex() {
        guard !isBusy, folderName != nil else { return }
        isBusy = true
        errorMessage = nil
        reportSummary = nil
        reportIssues = []
        progressMessage = "Opening external folder…"
        progressFraction = nil

        let progress = Progress(totalUnitCount: -1)
        scanProgress = progress
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "External ROM Library Scan") { [weak self] in
            Task { @MainActor in
                self?.scanProgress?.cancel()
                self?.endBackgroundTask()
            }
        }
        let systems = PVEmulatorConfiguration.availableSystemIdentifiers.compactMap { identifier -> ExternalROMSystem? in
            guard let extensions = PVEmulatorConfiguration.fileExtensions(forSystemIdentifier: identifier),
                  !extensions.isEmpty else { return nil }
            return ExternalROMSystem(identifier: identifier.rawValue, supportedExtensions: extensions)
        }

        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                // Keep the security scope alive for directory traversal and the full indexing pass.
                let access = try ExternalROMFolderAccessManager().openSavedFolder()
                let result = try ExternalROMScanner.scan(root: access.url,
                                                         systems: systems,
                                                         progress: progress,
                                                         onProgress: { visited in
                    Task { @MainActor [weak self] in
                        self?.progressMessage = "Scanning folders… \(visited) files checked"
                    }
                })

                guard !result.wasCancelled else {
                    await self?.finishCancelled()
                    withExtendedLifetime(access) {}
                    return
                }

                await self?.beginIndexing(count: result.candidates.count)
                progress.totalUnitCount = Int64(result.candidates.count)
                progress.completedUnitCount = 0
                let indexReport = await ExternalROMLibraryIndexer().index(result.candidates,
                                                                           progress: progress,
                                                                           onCandidateStarted: { candidate, current, total in
                    let size = ByteCountFormatter.string(fromByteCount: candidate.fileSize, countStyle: .file)
                    Task { @MainActor [weak self] in
                        self?.updateCurrentIndexProgress(relativePath: candidate.relativePath,
                                                         fileName: candidate.url.lastPathComponent,
                                                         size: size,
                                                         current: current,
                                                         total: total)
                    }
                },
                                                                           onHashProgress: { candidate, bytesProcessed, totalBytes in
                    Task { @MainActor [weak self] in
                        self?.updateHashProgress(relativePath: candidate.relativePath,
                                                 fileName: candidate.url.lastPathComponent,
                                                 bytesProcessed: bytesProcessed,
                                                 totalBytes: totalBytes)
                    }
                },
                                                                           onProgress: { done, total in
                    Task { @MainActor [weak self] in
                        self?.updateIndexProgress(done: done, total: total)
                    }
                })

                var issues = result.issues.map { "\($0.path): \($0.message)" }
                issues.append(contentsOf: indexReport.issues.map { "\($0.relativePath): \($0.message)" })
                await self?.finish(report: indexReport,
                                   discoveredCount: result.candidates.count,
                                   issues: issues)
                withExtendedLifetime(access) {}
            } catch {
                await self?.fail(error.localizedDescription)
            }
        }
    }

    private func beginIndexing(count: Int) {
        currentIndexNumber = 0
        totalIndexCount = count
        progressMessage = "Adding \(count) games to your library…"
        progressFraction = count == 0 ? 1 : 0
    }

    private func updateIndexProgress(done: Int, total: Int) {
        progressMessage = "Adding games… \(done) of \(total)"
        progressFraction = total == 0 ? 1 : Double(done) / Double(total)
    }

    private func updateCurrentIndexProgress(relativePath: String,
                                            fileName: String,
                                            size: String,
                                            current: Int,
                                            total: Int) {
        currentIndexNumber = current
        totalIndexCount = total
        currentIndexRelativePath = relativePath
        progressMessage = "Preparing game \(current) of \(total): \(fileName) (\(size))…"
        let fraction = total == 0 ? 1 : Double(current - 1) / Double(total)
        progressFraction = max(progressFraction ?? 0, fraction)
    }

    private func updateHashProgress(relativePath: String,
                                    fileName: String,
                                    bytesProcessed: Int64,
                                    totalBytes: Int64) {
        guard currentIndexRelativePath == relativePath else { return }
        let percent = min(100, Int((Double(bytesProcessed) / Double(max(1, totalBytes))) * 100))
        let processed = ByteCountFormatter.string(fromByteCount: bytesProcessed, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        progressMessage = "Checking \(fileName) for duplicates… \(percent)% (\(processed) of \(total))"
        if totalIndexCount > 0, currentIndexNumber > 0 {
            let fraction = min(1,
                               (Double(currentIndexNumber - 1) + Double(percent) / 100)
                                / Double(totalIndexCount))
            progressFraction = max(progressFraction ?? 0, fraction)
        }
    }

    private func finish(report: ExternalROMIndexReport, discoveredCount: Int, issues: [String]) {
        isBusy = false
        scanTask = nil
        scanProgress = nil
        progressFraction = nil
        reportIssues = Array(issues.prefix(500))
        reportSummary = report.wasCancelled
            ? "Scan cancelled after \(report.processedCount) of \(discoveredCount) games. Added \(report.indexedCount); skipped \(report.duplicateCount)."
            : "Found \(discoveredCount) games. Added \(report.indexedCount); skipped \(report.duplicateCount) duplicates. \(issues.count) issue(s). Game metadata and cover art are looked up in the background after games are added."
        endBackgroundTask()
        if report.indexedCount > 0 {
            // Refresh library views once after the batch, without invoking the full ROM rescan.
            NotificationCenter.default.post(name: .gameLibraryDidUpdate, object: nil)
        }
    }

    private func finishCancelled() {
        isBusy = false
        scanTask = nil
        scanProgress = nil
        progressFraction = nil
        reportSummary = "Folder scan cancelled. No games were indexed."
        endBackgroundTask()
    }

    private func fail(_ message: String) {
        isBusy = false
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
