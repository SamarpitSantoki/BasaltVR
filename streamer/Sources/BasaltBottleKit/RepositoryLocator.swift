import Foundation

public enum RepositoryLocator {
    public static func find(
        startingAt start: URL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> URL {
        if let override = environment["BASALT_REPO_ROOT"], !override.isEmpty {
            let root = URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
            guard isRepository(root, fileManager: fileManager) else {
                throw BottleToolError(
                    "BASALT_REPO_ROOT is not a BasaltVR source or support root: \(root.path)")
            }
            return root
        }

        var candidate = start.standardizedFileURL
        for _ in 0..<10 {
            if isRepository(candidate, fileManager: fileManager) { return candidate }
            let parent = candidate.deletingLastPathComponent()
            if parent == candidate { break }
            candidate = parent
        }
        throw BottleToolError(
            "Could not find the BasaltVR source or packaged support files; set BASALT_REPO_ROOT to their path")
    }

    private static func isRepository(_ url: URL, fileManager: FileManager) -> Bool {
        let sourceLayout =
            fileManager.fileExists(
                atPath: url.appendingPathComponent("runtime/CMakeLists.txt").path)
            && fileManager.fileExists(atPath: url.appendingPathComponent("streamer/Package.swift").path)
        let packagedLayout =
            fileManager.fileExists(
                atPath: url.appendingPathComponent("BasaltVR.support.json").path)
            && fileManager.fileExists(
                atPath: url.appendingPathComponent(
                    "runtime/build/bin/basalt_openxr.dll").path)
            && fileManager.fileExists(
                atPath: url.appendingPathComponent(
                    "runtime/build/bin/basalt_openxr.json").path)
            && fileManager.fileExists(
                atPath: url.appendingPathComponent("docs/BOTTLES.md").path)
        return sourceLayout || packagedLayout
    }
}
