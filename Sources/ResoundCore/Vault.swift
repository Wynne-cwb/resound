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
