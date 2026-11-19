import Foundation
import Observation

@MainActor
@Observable
final class AppUpdates {
    struct Update {
        let version: String
        let downloadURL: URL
    }

    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    static let releasePage = URL(string: "https://github.com/tianmengchu/GlassList/releases")!
    private static let latestRelease = URL(string: "https://api.github.com/repos/tianmengchu/GlassList/releases/latest")!
    private static let automaticChecksKey = "SUEnableAutomaticChecks"

    private(set) var available: Update?
    private(set) var statusMessage: String?
    private(set) var isChecking = false
    private(set) var automaticallyChecks = UserDefaults.standard.bool(forKey: AppUpdates.automaticChecksKey)
    @ObservationIgnored private var automaticCheckTask: Task<Void, Never>?

    init() {
        scheduleAutomaticChecks()
    }

    func setAutomaticChecks(_ enabled: Bool) {
        guard enabled != automaticallyChecks else { return }
        automaticallyChecks = enabled
        UserDefaults.standard.set(enabled, forKey: Self.automaticChecksKey)
        scheduleAutomaticChecks()
    }

    private func scheduleAutomaticChecks() {
        automaticCheckTask?.cancel()
        automaticCheckTask = nil
        guard automaticallyChecks else { return }

        automaticCheckTask = Task { [weak self] in
            while !Task.isCancelled, self != nil {
                await self?.check()
                do {
                    try await Task.sleep(for: .seconds(86_400))
                } catch {
                    return
                }
            }
        }
    }

    func check() async {
        guard !isChecking else { return }
        isChecking = true
        statusMessage = nil
        defer { isChecking = false }

        var request = URLRequest(url: Self.latestRelease, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try Task.checkCancellation()
            switch (response as? HTTPURLResponse)?.statusCode {
            case 200:
                apply(try JSONDecoder().decode(Release.self, from: data))
            case 404:
                available = nil
                statusMessage = "GitHub 暂无正式发布。"
            default:
                statusMessage = "暂时无法检查更新，请稍后重试。"
            }
        } catch {
            if !Task.isCancelled {
                statusMessage = "暂时无法检查更新，请稍后重试。"
            }
        }
    }

    private func apply(_ release: Release) {
        available = nil
        guard !release.draft, !release.prerelease,
              let latest = ReleaseVersion(release.tagName) else {
            statusMessage = "GitHub 暂无正式发布。"
            return
        }
        guard let installed = ReleaseVersion(Self.version),
              installed.components.lexicographicallyPrecedes(latest.components) else {
            statusMessage = "当前已是最新版本。"
            return
        }
        guard let downloadURL = release.macDownload(version: latest.label) else {
            statusMessage = "已发布 \(latest.label)，GitHub 暂未提供 macOS 安装包。"
            return
        }
        available = Update(version: latest.label, downloadURL: downloadURL)
    }
}

private struct ReleaseVersion {
    let label: String
    let components: [Int]

    init?(_ tag: String) {
        let version = tag.first?.lowercased() == "v" ? String(tag.dropFirst()) : tag
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { part -> Int? in
            guard part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(part)
        }
        guard (1...3).contains(parts.count), numbers.count == parts.count else { return nil }
        label = version
        components = numbers + Array(repeating: 0, count: 3 - numbers.count)
    }
}

private struct Release: Decodable {
    struct Asset: Decodable {
        let name: String
        let state: String
        let size: Int
        let downloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name, state, size
            case downloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case draft, prerelease, assets
        case tagName = "tag_name"
    }

    func macDownload(version: String) -> URL? {
        let basename = "glasslist-\(version)"
        let names = ["\(basename)-universal.dmg", "\(basename)-universal.zip", "\(basename).dmg", "\(basename).zip"]
        let path = "/tianmengchu/GlassList/releases/download/\(tagName)/"
        let uploaded = assets.filter { asset in
            asset.state == "uploaded" && asset.size > 0 && asset.downloadURL.scheme == "https" &&
                asset.downloadURL.host == "github.com" && asset.downloadURL.path == path + asset.name
        }
        return names.lazy.compactMap { name in
            uploaded.first { $0.name.lowercased() == name }?.downloadURL
        }.first
    }
}
