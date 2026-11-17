import Foundation
import CryptoKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let bytes = Data("test update package".utf8)
let digest = SHA256.hash(data: bytes).map { String(format: "%02x", Int($0)) }.joined()
let installed = ReleaseVersion("0.9.14.0", installed: true)!
let fileName = "GPTDragon-macos-arm64-0.9.15.zip"
let download = "https://github.com/\(DownloadRelease.repository)/releases/download/macos-stable/\(fileName)"
func feed(name: String = fileName, url: String = download, hash: String? = "sha256:" + digest,
          tag: String = "macos-stable", draft: Bool = false, size: Int = bytes.count) throws -> Data {
    var asset: [String: Any] = ["name":name,"size":size,"browser_download_url":url]
    if let hash { asset["digest"] = hash }
    return try JSONSerialization.data(withJSONObject: ["tag_name":tag, "draft":draft, "prerelease":false,"assets":[asset]])
}
func selected(_ bytes: Data) throws -> DownloadRelease? {
    try DownloadRelease.select(bytes, installed: installed)
}
func reject(_ run: () throws -> Void) {
    do { try run(); fatalError("Expected failure") } catch {}
}
let release = try selected(feed())!
precondition(release.version == "0.9.15")
let sameVersion = try DownloadRelease.select(feed(), installed: ReleaseVersion("0.9.15")!)
precondition(sameVersion == nil)
for data in [
    try feed(name:"GPTDragon-windows-x64-9.0.0.zip"),
    try feed(name:"GPTDragon-macos-x64-9.0.0.zip"),
    try feed(name:"GPTDragon-macos-arm64-0.9.15-beta.zip"),
    try feed(url:"http://github.com/a"),
    try feed(url:download.replacingOccurrences(of: "github.com/", with:"github.com.example.test/")),
    try feed(url:download.replacingOccurrences(of: DownloadRelease.repository, with:"Other/Project")),
    try feed(hash:nil), try feed(hash:"sha256:bad"), try feed(size:0)
] {
    let bad = try selected(data)
    precondition(bad == nil)
}
reject { _ = try selected(feed(tag:"windows-stable")) }
reject { _ = try selected(feed(draft:true)) }
reject { _ = try selected(Data(repeating: 0, count:1024*1024+1)) }
precondition(ReleaseVersion("0.10.0")! > ReleaseVersion("0.9.999")!)
precondition(ReleaseVersion("1.02.0") == nil && ReleaseVersion("1.0.0.0") == nil)
let zip = directory.appendingPathComponent(fileName)
try bytes.write(to:zip)
try release.verify(zip)
try Data(repeating:0,count:bytes.count).write(to:zip)
reject { try release.verify(zip) }
try bytes.dropLast().write(to:zip)
reject { try release.verify(zip) }
precondition(!DownloadRelease.permits(URL(string:"http://github.com")))
precondition(!DownloadRelease.permits(URL(string:"https://github.com:444/")))
precondition(DownloadRelease.permits(URL(string:"https://api.github.com/")))
print("Passed macOS release selection, version, architecture, repository, redirect policy, size and SHA-256 cases.")
