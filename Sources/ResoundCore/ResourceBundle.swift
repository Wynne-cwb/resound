import Foundation

/// 查找 SwiftPM 资源包（替代直接用 `Bundle.module`）。
///
/// SwiftPM 为 `swift build` 生成的 `Bundle.module` 只在两处找资源包：
/// ① `Bundle.main.bundleURL`（打包后 = Resound.app/ 最外层）② 编译机写死的 .build 路径。
/// 打包脚本把资源包放在 `Contents/Resources/`，两处都不命中 → 在没有编译机
/// .build 目录的电脑上触发 fatalError，App 一转写（ZhConverter）就崩。
/// 这里按实际分发布局补齐候选目录，全部不中再回退 `Bundle.module`
/// （开发环境 swift build/run/test 资源包就在可执行旁边，行为不变）。
public enum ResourceBundle {
    public static func locate(_ name: String, fallback: () -> Bundle) -> Bundle {
        let fm = FileManager.default
        var dirs: [URL] = []
        if let r = Bundle.main.resourceURL { dirs.append(r) }   // App: Contents/Resources；开发 CLI: 可执行同目录
        dirs.append(Bundle.main.bundleURL)                      // SwiftPM 原生候选（app 最外层 / 可执行目录）
        dirs.append(Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("Resources"))               // 随包 CLI: Contents/MacOS/../Resources
        for dir in dirs {
            let url = dir.appendingPathComponent(name + ".bundle")
            if fm.fileExists(atPath: url.path), let b = Bundle(url: url) { return b }
        }
        return fallback()
    }
}

extension Bundle {
    /// ResoundCore 的资源包（TSCharacters.txt / moss_modal.py）。
    static let resoundCore: Bundle = ResourceBundle.locate("Resound_ResoundCore") { .module }
}
