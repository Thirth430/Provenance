//
//  ExternalROMPath.swift
//  PVFileSystem
//

import Foundation

/// The stable, app-independent relative-path encoding used in the library database for external ROMs.
public enum ExternalROMPath {
    public static let prefix = "ExternalROMs/"

    /// Returns a namespaced partial path, rejecting absolute paths and traversal components.
    public static func partialPath(forRelativePath path: String) -> String? {
        guard !path.hasPrefix("/"), !path.hasPrefix("\\") else { return nil }
        let normalizedPath = path.replacingOccurrences(of: "\\", with: "/")
        guard !(normalizedPath.count > 1 && normalizedPath[normalizedPath.index(after: normalizedPath.startIndex)] == ":") else {
            return nil
        }
        let components = normalizedPath
            .split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." }) else { return nil }
        return prefix + components.joined(separator: "/")
    }

    /// Returns a safe path below the selected external folder for a namespaced library path.
    public static func relativePath(fromPartialPath path: String) -> String? {
        guard path.hasPrefix(prefix) else { return nil }
        let relativePath = String(path.dropFirst(prefix.count))
        guard partialPath(forRelativePath: relativePath) == prefix + relativePath.replacingOccurrences(of: "\\", with: "/") else {
            return nil
        }
        return relativePath.replacingOccurrences(of: "\\", with: "/")
    }
}
