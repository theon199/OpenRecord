import Foundation

public enum ProjectAssetResolver: Sendable {
    /// Resolve a project-declared cursor PNG without allowing traversal or symlink escape.
    public static func cursorPNG(relativePath: String, in projectURL: URL) -> URL? {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              URL(fileURLWithPath: relativePath).pathExtension.lowercased() == "png"
        else {
            return nil
        }

        let root = ProjectLayout.cursorsDirectory(in: projectURL)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let candidate = projectURL
            .appendingPathComponent(relativePath, isDirectory: false)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(rootPrefix) else { return nil }
        return candidate
    }
}
