//
//  ExternalROMFolder.swift
//  PVFileSystem
//

import Foundation
import Defaults
import PVSettings

/// A user-selected ROM folder that remains in place outside Provenance's managed library.
public struct ExternalROMFolder: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var bookmark: Data
    public var displayName: String
    public var selectedAt: Date

    public init(bookmark: Data, displayName: String, selectedAt: Date = Date()) {
        version = Self.currentVersion
        self.bookmark = bookmark
        self.displayName = displayName
        self.selectedAt = selectedAt
    }
}

/// Storage for the external ROM folder selection, separate from Provenance's writable library root.
public struct ExternalROMFolderStore: Sendable {
    public static let shared = ExternalROMFolderStore(read: { Defaults[.externalROMFolder] },
                                                       write: { Defaults[.externalROMFolder] = $0 })

    private let read: @Sendable () -> Data?
    private let write: @Sendable (Data?) -> Void

    public init(read: @escaping @Sendable () -> Data?, write: @escaping @Sendable (Data?) -> Void) {
        self.read = read
        self.write = write
    }

    public init(defaults: UserDefaults, key: String) {
        self.init(read: { defaults.data(forKey: key) }, write: { defaults.set($0, forKey: key) })
    }

    public func load() -> ExternalROMFolder? {
        guard let data = read() else { return nil }
        return try? JSONDecoder().decode(ExternalROMFolder.self, from: data)
    }

    public func save(_ folder: ExternalROMFolder) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        write(try encoder.encode(folder))
    }

    public func clear() {
        write(nil)
    }
}

public enum ExternalROMFolderError: Error, Equatable, LocalizedError {
    case invalidBookmark(String)
    case unavailable(String)
    case notDirectory(String)

    public var errorDescription: String? {
        switch self {
        case .invalidBookmark(let detail): return "The external ROM folder permission is no longer valid: \(detail)"
        case .unavailable(let path): return "The external ROM folder is unavailable: \(path)"
        case .notDirectory(let path): return "The selected external ROM location is not a folder: \(path)"
        }
    }
}

/// Whether the selected external folder can currently be reached.
public enum ExternalROMFolderAvailability: Equatable, Sendable {
    case notConfigured
    case available(displayName: String)
    case unavailable(displayName: String)

    /// Checks only the selected root; it does not traverse or rescan the ROM collection.
    public static func current(store: ExternalROMFolderStore = .shared,
                               fileManager: FileManager = .default,
                               rootURLProvider: () -> URL? = { ExternalROMFolderRootAccess.shared.rootURL() }) -> Self {
        guard let folder = store.load() else { return .notConfigured }
        guard let rootURL = rootURLProvider() else { return .unavailable(displayName: folder.displayName) }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .unavailable(displayName: folder.displayName)
        }
        return .available(displayName: folder.displayName)
    }
}

/// An active security-scoped access lifetime. Keep this alive while enumerating or playing a game.
public final class ExternalROMFolderAccess {
    public let url: URL
    private let startedSecurityScope: Bool

    fileprivate init(url: URL, startedSecurityScope: Bool) {
        self.url = url
        self.startedSecurityScope = startedSecurityScope
    }

    deinit {
        if startedSecurityScope { url.stopAccessingSecurityScopedResource() }
    }
}

/// Creates, persists, and resolves the bookmark for an in-place external ROM folder.
public struct ExternalROMFolderAccessManager {
    private let store: ExternalROMFolderStore
    private let fileManager: FileManager

    #if os(macOS)
    private static let creationOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
    private static let resolutionOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
    #else
    private static let creationOptions: URL.BookmarkCreationOptions = []
    private static let resolutionOptions: URL.BookmarkResolutionOptions = []
    #endif

    public init(store: ExternalROMFolderStore = .shared, fileManager: FileManager = .default) {
        self.store = store
        self.fileManager = fileManager
    }

    /// Saves a bookmark from a directory URL supplied by the system document picker.
    @discardableResult
    public func select(_ url: URL) throws -> ExternalROMFolder {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ExternalROMFolderError.unavailable(url.path)
        }
        guard isDirectory.boolValue else { throw ExternalROMFolderError.notDirectory(url.path) }

        let bookmark = try url.bookmarkData(options: Self.creationOptions,
                                           includingResourceValuesForKeys: nil,
                                           relativeTo: nil)
        let folder = ExternalROMFolder(bookmark: bookmark, displayName: url.lastPathComponent)
        try store.save(folder)
        ExternalROMFolderRootAccess.shared.invalidate()
        return folder
    }

    /// Opens the saved folder. Retain the returned session for the duration of access.
    public func openSavedFolder() throws -> ExternalROMFolderAccess {
        guard let folder = store.load() else {
            throw ExternalROMFolderError.unavailable("No external folder has been selected.")
        }
        return try open(folder)
    }

    /// Opens a folder and refreshes its bookmark when the system reports it stale.
    public func open(_ folder: ExternalROMFolder) throws -> ExternalROMFolderAccess {
        var isStale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: folder.bookmark,
                          options: Self.resolutionOptions,
                          relativeTo: nil,
                          bookmarkDataIsStale: &isStale)
        } catch {
            // On Apple platforms, resolving a bookmark to a folder on a removed
            // drive can fail before we get a URL to check with fileExists. Keep
            // this distinct from a malformed or revoked bookmark so the library
            // can report the selected folder as temporarily unavailable.
            if Self.isMissingResource(error) {
                throw ExternalROMFolderError.unavailable(folder.displayName)
            }
            throw ExternalROMFolderError.invalidBookmark(error.localizedDescription)
        }

        let started = url.startAccessingSecurityScopedResource()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            if started { url.stopAccessingSecurityScopedResource() }
            throw ExternalROMFolderError.unavailable(url.path)
        }
        guard isDirectory.boolValue else {
            if started { url.stopAccessingSecurityScopedResource() }
            throw ExternalROMFolderError.notDirectory(url.path)
        }

        if isStale,
           let refreshedBookmark = try? url.bookmarkData(options: Self.creationOptions,
                                                         includingResourceValuesForKeys: nil,
                                                         relativeTo: nil) {
            var refreshed = folder
            refreshed.bookmark = refreshedBookmark
            try? store.save(refreshed)
        }
        return ExternalROMFolderAccess(url: url.standardizedFileURL, startedSecurityScope: started)
    }

    private static func isMissingResource(_ error: Error) -> Bool {
        let nsError = error as NSError
        if (nsError.domain == NSCocoaErrorDomain && [4, 260].contains(nsError.code)) ||
            (nsError.domain == NSPOSIXErrorDomain && nsError.code == 2) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isMissingResource(underlying)
        }
        return false
    }
}

/// Retains the selected folder's security scope while path-based library and emulator code uses it.
public final class ExternalROMFolderRootAccess: @unchecked Sendable {
    public static let shared = ExternalROMFolderRootAccess()

    private let lock = NSLock()
    private var access: ExternalROMFolderAccess?

    private init() {}

    /// Resolves and retains access lazily. Returns nil for a revoked permission or unavailable drive.
    public func rootURL() -> URL? {
        lock.lock()
        if let access {
            lock.unlock()
            return access.url
        }
        lock.unlock()

        guard let resolved = try? ExternalROMFolderAccessManager().openSavedFolder() else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let access { return access.url }
        access = resolved
        return resolved.url
    }

    /// Releases the current scope, for example when the user selects a different folder.
    public func invalidate() {
        lock.lock()
        access = nil
        lock.unlock()
    }
}
