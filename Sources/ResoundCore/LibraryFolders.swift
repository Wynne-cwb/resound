import Foundation

/// 录音库的文件夹组织（事实源 vault/library.json）。纯组织层，不动录音目录/契约。
public struct LibraryFolder: Identifiable, Codable, Hashable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct LibraryOrganization: Codable {
    public var folders: [LibraryFolder]
    public var assign: [String: String]   // recordingId -> folderId
    public init(folders: [LibraryFolder] = [], assign: [String: String] = [:]) {
        self.folders = folders; self.assign = assign
    }
}

public enum LibraryStore {
    public static func fileURL(vaultRoot: URL) -> URL { vaultRoot.appendingPathComponent("library.json") }

    public static func load(vaultRoot: URL) -> LibraryOrganization {
        guard let d = try? Data(contentsOf: fileURL(vaultRoot: vaultRoot)),
              let org = try? JSONDecoder().decode(LibraryOrganization.self, from: d) else {
            return LibraryOrganization()
        }
        return org
    }

    public static func save(_ org: LibraryOrganization, vaultRoot: URL) throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: true)
        try enc.encode(org).write(to: fileURL(vaultRoot: vaultRoot))
    }
}
