import Foundation
import Observation

@MainActor
@Observable
final class AppUpdates {
    struct Update: Equatable {
        let version: String
        let releaseURL: URL
        let downloadURL: URL?
        let notes: String?

        var destination: URL { downloadURL ?? releaseURL }
    }

    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    static let releasePage = URL(string: "https://github.com/tianmengchu/GlassList/releases")!
    private static let latestRelease = URL(string: "https://api.github.com/repos/tianmengchu/GlassList/releases/latest")!
    private static let latestReleasePage = releasePage.appending(path: "latest")
    private static let automaticChecksKey = "SUEnableAutomaticChecks"

    private(set) var available: Update?
    private(set) var statusMessage: String?
    private(set) var isChecking = false
    private(set) var automaticallyChecks = (UserDefaults.standard.object(forKey: AppUpdates.automaticChecksKey) as? Bool) ?? true
    @ObservationIgnored private var automaticCheckTask: Task<Void, Never>?
    @ObservationIgnored private var apiRetryAt: Date?

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

        do {
            try await checkAPI()
        } catch {
            guard !Task.isCancelled else { return }
            let apiError = error as? UpdateCheckError
            do {
                try await checkReleasePage()
            } catch {
                guard !Task.isCancelled else { return }
                if apiError == .rateLimited {
                    statusMessage = "GitHub 检查请求暂时达到上限，可从发布页查看。"
                } else {
                    statusMessage = "暂时无法连接 GitHub，可从发布页查看。"
                }
            }
        }
    }

    private func checkAPI() async throws {
        if let apiRetryAt, apiRetryAt > .now { throw UpdateCheckError.rateLimited }
        var request = URLRequest(url: Self.latestRelease, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await URLSession.shared.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw UpdateCheckError.unexpectedResponse }
        switch response.statusCode {
        case 200:
            apply(try JSONDecoder().decode(Release.self, from: data))
        case 404:
            available = nil
            statusMessage = "GitHub 暂无正式发布。"
        case 403, 429:
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
            let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining")
            guard response.statusCode == 429 || remaining == "0" || retryAfter != nil else {
                throw UpdateCheckError.unexpectedResponse
            }
            let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset")
                .flatMap(Double.init).map(Date.init(timeIntervalSince1970:)) ?? .distantPast
            apiRetryAt = max(reset, Date.now.addingTimeInterval(max(60, retryAfter.flatMap(Double.init) ?? 0)))
            throw UpdateCheckError.rateLimited
        default:
            throw UpdateCheckError.unexpectedResponse
        }
    }

    private func checkReleasePage() async throws {
        let response = try await Self.head(Self.latestReleasePage)
        try Task.checkCancellation()
        let tagPrefix = Self.releasePage.appending(path: "tag").path + "/"
        guard response.statusCode == 200, let page = response.url,
              page.scheme == "https", page.host == "github.com", page.path.hasPrefix(tagPrefix),
              let latest = ReleaseVersion(String(page.path.dropFirst(tagPrefix.count))) else {
            throw UpdateCheckError.unexpectedResponse
        }
        guard hasNewVersion(latest) else { return }

        let tag = page.lastPathComponent
        let folder = Self.releasePage.appending(path: "download").appending(path: tag)
        let candidates = Release.macAssetNames(version: latest.label).map { folder.appending(path: $0) }
        let download = await withTaskGroup(of: (Int, URL?).self, returning: URL?.self) { group in
            for (index, url) in candidates.enumerated() {
                group.addTask {
                    let response = try? await Self.head(url)
                    return (index, response?.statusCode == 200 ? url : nil)
                }
            }
            var verified: [(Int, URL)] = []
            for await (index, url) in group {
                if let url { verified.append((index, url)) }
            }
            return verified.min { $0.0 < $1.0 }?.1
        }
        try Task.checkCancellation()
        available = Update(version: latest.label, releaseURL: page, downloadURL: download, notes: nil)
    }

    private nonisolated static func head(_ url: URL) async throws -> HTTPURLResponse {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.httpMethod = "HEAD"
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw UpdateCheckError.unexpectedResponse }
        return response
    }

    private func apply(_ release: Release) {
        guard !release.draft, !release.prerelease,
              let latest = ReleaseVersion(release.tagName) else {
            available = nil
            statusMessage = "GitHub 暂无正式发布。"
            return
        }
        guard hasNewVersion(latest) else { return }
        let page = Self.releasePage.appending(path: "tag").appending(path: release.tagName)
        let download = release.macDownload(version: latest.label)
        let trimmedNotes = release.body?.trimmingCharacters(in: .whitespacesAndNewlines)
        available = Update(version: latest.label, releaseURL: page, downloadURL: download,
                           notes: trimmedNotes?.isEmpty == false ? trimmedNotes : nil)
        if download == nil {
            statusMessage = "此版本暂未提供 macOS 安装包。"
        }
    }

    private func hasNewVersion(_ latest: ReleaseVersion) -> Bool {
        guard let installed = ReleaseVersion(Self.version),
              installed.components.lexicographicallyPrecedes(latest.components) else {
            available = nil
            statusMessage = "当前无可用更新 · GitHub 最新发布 \(latest.label)"
            return false
        }
        return true
    }
}

private enum UpdateCheckError: Error {
    case rateLimited, unexpectedResponse
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
    let body: String?
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case draft, prerelease, body, assets
        case tagName = "tag_name"
    }

    func macDownload(version: String) -> URL? {
        let path = "/tianmengchu/GlassList/releases/download/\(tagName)/"
        let uploaded = assets.filter { asset in
            asset.state == "uploaded" && asset.size > 0 && asset.downloadURL.scheme == "https" &&
                asset.downloadURL.host == "github.com" && asset.downloadURL.path == path + asset.name
        }
        return Self.macAssetNames(version: version).lazy.compactMap { name in
            uploaded.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.downloadURL
        }.first
    }

    static func macAssetNames(version: String) -> [String] {
        let basename = "GlassList-\(version)"
        return ["\(basename)-universal.dmg", "\(basename)-universal.zip", "\(basename).dmg", "\(basename).zip"]
    }
}
