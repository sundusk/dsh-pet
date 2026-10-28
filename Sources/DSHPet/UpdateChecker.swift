import Foundation

/// DSHPet 更新检查：查询 GitHub Releases 最新版并与本地版本对比。
/// 纯 app 侧实现——插件只负责状态接口，app 的功能（含更新）都在自己身上。
enum UpdateChecker {
    /// 发布仓库（与 install.sh / make-app.sh 一致）。
    static let repo = "sundusk/dsh-pet"

    /// Releases 首页（「前往下载」跳转目标）。
    static let releasesPageURL = URL(string: "https://github.com/\(repo)/releases/latest")!

    /// 一次检查的结果。
    struct ReleaseInfo {
        /// 最新 release 版本号（不含前导 v）。
        let latestVersion: String
        /// 是否比本地版本新。
        let updateAvailable: Bool
        /// 该 release 的页面地址。
        let releaseURL: URL
    }

    /// 当前 app 版本（Info.plist CFBundleShortVersionString）。
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// 查询 GitHub 最新 release；网络失败 / 非 200 / 解析失败返回 nil。
    static func checkLatest() async -> ReleaseInfo? {
        let api = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        var request = URLRequest(url: api)
        request.setValue("DSHPet/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 8
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let html = json["html_url"] as? String else { return nil }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            return ReleaseInfo(
                latestVersion: latest,
                updateAvailable: compareVersion(latest, currentVersion) > 0,
                releaseURL: URL(string: html) ?? releasesPageURL
            )
        } catch {
            return nil
        }
    }

    /// 语义化版本比较：> 0 表示 a 比 b 新（逐段数值比较，支持 0.3.0 vs 0.10.0）。
    static func compareVersion(_ a: String, _ b: String) -> Int {
        let av = a.split(separator: ".").map { Int($0) ?? 0 }
        let bv = b.split(separator: ".").map { Int($0) ?? 0 }
        let n = max(av.count, bv.count)
        for i in 0..<n {
            let x = i < av.count ? av[i] : 0
            let y = i < bv.count ? bv[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }
}
