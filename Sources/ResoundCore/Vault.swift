import Foundation

public enum VaultError: Error, CustomStringConvertible {
    case notAVault(URL)
    case ioFailure(String)

    public var description: String {
        switch self {
        case .notAVault(let url):
            return "不是合法 vault（缺 resound.yaml）：\(url.path)"
        case .ioFailure(let msg):
            return "文件操作失败：\(msg)"
        }
    }
}

/// Vault = 符合 resound.vault/1 契约的本地工作副本。
public struct Vault {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// 校验是否是合法 vault（根目录有 resound.yaml）。
    public func validate() throws {
        let cfg = root.appendingPathComponent("resound.yaml")
        guard FileManager.default.fileExists(atPath: cfg.path) else {
            throw VaultError.notAVault(root)
        }
    }

    /// 若该目录还不是合法 vault（无 resound.yaml），按数据契约（docs/data-contract.md §2/§3）创建最小结构；
    /// 已是 vault 则原样采用、不改动。返回 true=本次新建，false=采用了已存在的 vault。
    /// **只建文件/目录，不做 git init**（git 同步由用户自行 init/关联远端）。
    @discardableResult
    public func ensureScaffold(timezone: String = TimeZone.current.identifier,
                               language: String = "zh") throws -> Bool {
        let fm = FileManager.default
        let yaml = root.appendingPathComponent("resound.yaml")
        if fm.fileExists(atPath: yaml.path) { return false }   // 已是 vault → 采用，不覆盖
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            for sub in ["recordings", "documents", "notes", "people"] {
                try fm.createDirectory(at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
            }
            let name = root.lastPathComponent.isEmpty ? "my-vault" : root.lastPathComponent
            let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "yyyy-MM-dd"
            let resound = """
            schema: resound.vault/1
            vault_name: \(name)
            created: \(df.string(from: Date()))
            timezone: \(timezone)
            default_language: \(language)
            """
            try resound.write(to: yaml, atomically: true, encoding: .utf8)
            try "schema: resound.people/1\npeople: []\n"
                .write(to: root.appendingPathComponent("people/people.yaml"), atomically: true, encoding: .utf8)
            // 空目录占位（便于 git 跟踪 + 结构可见）
            for sub in ["recordings", "documents", "notes"] {
                try? "".write(to: root.appendingPathComponent("\(sub)/.gitkeep"), atomically: true, encoding: .utf8)
            }
            try "".write(to: root.appendingPathComponent("glossary.txt"), atomically: true, encoding: .utf8)
            try "*.m4a filter=lfs diff=lfs merge=lfs -text\n*.flac filter=lfs diff=lfs merge=lfs -text\n*.wav filter=lfs diff=lfs merge=lfs -text\n"
                .write(to: root.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
            try ".DS_Store\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
            return true
        } catch let e as VaultError {
            throw e
        } catch {
            throw VaultError.ioFailure(String(describing: error))
        }
    }

    /// recordings/YYYY/MM/<id>/
    public func recordingDir(id: String, date: Date) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy"
        let year = f.string(from: date)
        f.dateFormat = "MM"
        let month = f.string(from: date)
        return root
            .appendingPathComponent("recordings")
            .appendingPathComponent(year)
            .appendingPathComponent(month)
            .appendingPathComponent(id)
    }
}
