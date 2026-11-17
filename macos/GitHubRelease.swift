import CryptoKit
import Foundation

enum DownloadUpdateError: Error {
    case invalidRelease, invalidPackage, downloadFailed
}

struct ReleaseVersion: Comparable, Equatable {
    let parts: [UInt32]

    init?(_ text: String, installed: Bool = false) {
        var fields = text.split(separator: ".", omittingEmptySubsequences: false)
        if installed && fields.count == 4 && fields.last == "0" { fields.removeLast() }
        guard fields.count == 3, fields.allSatisfy({ field in
            !field.isEmpty && (field.count == 1 || field.first != "0") &&
                field.utf8.allSatisfy { (48...57).contains($0) }
        }) else { return nil }
        let numbers = fields.compactMap { UInt32($0) }
        guard numbers.count == 3 else { return nil }
        parts = numbers
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.parts.lexicographicallyPrecedes(rhs.parts)
    }
}

struct DownloadRelease: Equatable {
    static let repository = "Mingtianyou/gptdragon-desktop-pet"
    static let tag = "macos-stable"
    static let packageLimit: Int64 = 1024 * 1024 * 1024
    static let feedURL = URL(string: "https://api.github.com/repos/\(repository)/releases/tags/\(tag)")!
    let version: String
    let fileName: String
    let url: URL
    let size: Int64
    let sha256: String

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let size: Int64
            let browser_download_url: String
            let digest: String?
        }
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }

    static func select(_ data: Data, installed: ReleaseVersion) throws -> Self? {
        guard data.count <= 1024 * 1024 else { throw DownloadUpdateError.invalidRelease }
        let feed = try JSONDecoder().decode(Release.self, from: data)
        guard !feed.draft, !feed.prerelease, feed.tag_name == tag else {
            throw DownloadUpdateError.invalidRelease
        }
        let prefix = "GPTDragon-macos-arm64-"
        var candidates: [Self] = []
        for asset in feed.assets where asset.name.hasPrefix(prefix) && asset.name.hasSuffix(".zip") {
            let version = String(asset.name.dropFirst(prefix.count).dropLast(4))
            guard let parsed = ReleaseVersion(version), parsed > installed,
                  (1...packageLimit).contains(asset.size), let digest = asset.digest,
                  digest.range(of: #"\Asha256:[a-fA-F0-9]{64}\z"#, options: .regularExpression) != nil,
                  let url = URL(string: asset.browser_download_url),
                  url.absoluteString == "https://github.com/\(repository)/releases/download/\(tag)/\(asset.name)"
            else { continue }
            candidates.append(Self(version: version, fileName: asset.name, url: url,
                                   size: asset.size, sha256: String(digest.dropFirst(7)).lowercased()))
        }
        guard Set(candidates.map(\.version)).count == candidates.count else {
            throw DownloadUpdateError.invalidRelease
        }
        return candidates.max { ReleaseVersion($0.version)! < ReleaseVersion($1.version)! }
    }

    func verify(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize.map(Int64.init) == size else {
            throw DownloadUpdateError.invalidPackage
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        var length: Int64 = 0
        while let bytes = try file.read(upToCount: 256 * 1024), !bytes.isEmpty {
            length += Int64(bytes.count)
            guard length <= size else { throw DownloadUpdateError.invalidPackage }
            hash.update(data: bytes)
        }
        let actual = hash.finalize().map { String(format: "%02x", Int($0)) }.joined()
        guard length == size, actual == sha256 else { throw DownloadUpdateError.invalidPackage }
    }

    static func permits(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return ["api.github.com", "github.com", "release-assets.githubusercontent.com",
                "objects.githubusercontent.com", "github-releases.githubusercontent.com"].contains(host)
    }
}
