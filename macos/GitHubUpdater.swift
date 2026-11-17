import AppKit
import Foundation
import Darwin

final class UpdateTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let limit: Int64
    private let file: FileHandle?
    private var count: Int64 = 0
    private var data = Data()
    private var error: Error?
    private let completion: CheckedContinuation<Data, Error>

    private init(limit: Int64, file: FileHandle?, completion: CheckedContinuation<Data, Error>) {
        self.limit = limit
        self.file = file
        self.completion = completion
    }

    static func load(_ url: URL, limit: Int64, destination: URL? = nil) async throws -> Data {
        guard DownloadRelease.permits(url) else { throw DownloadUpdateError.invalidRelease }
        let file: FileHandle?
        if let destination {
            try Data().write(to: destination, options: .withoutOverwriting)
            file = try FileHandle(forWritingTo: destination)
        } else {
            file = nil
        }
        return try await withCheckedThrowingContinuation { completion in
            let transfer = UpdateTransfer(limit: limit, file: file, completion: completion)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = destination == nil ? 30 : 30 * 60
            let session = URLSession(configuration: configuration, delegate: transfer, delegateQueue: nil)
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.setValue("GPTDragon-macOS", forHTTPHeaderField: "User-Agent")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            session.dataTask(with: request).resume()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(DownloadRelease.permits(request.url) ? request : nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode
        guard status == 200, DownloadRelease.permits(response.url),
              response.expectedContentLength <= limit else {
            error = DownloadUpdateError.downloadFailed
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive bytes: Data) {
        guard error == nil else { return }
        count += Int64(bytes.count)
        guard count <= limit else {
            error = DownloadUpdateError.downloadFailed
            dataTask.cancel()
            return
        }
        do {
            if let file { try file.write(contentsOf: bytes) }
            else { data.append(bytes) }
        } catch {
            self.error = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError transportError: Error?) {
        defer { session.finishTasksAndInvalidate() }
        do { try file?.close() } catch { self.error = error }
        if let error = error ?? transportError { completion.resume(throwing: error) }
        else { completion.resume(returning: data) }
    }
}

@MainActor
final class GitHubUpdater {
    enum State {
        case hidden, available(String), downloading, downloaded(URL), retry(String)

        var label: String? {
            switch self {
            case .hidden: return nil
            case .available(let version): return "下载新版 \(version)"
            case .downloading: return "正在下载并校验新版…"
            case .downloaded: return "新版已下载，点击在访达中显示"
            case .retry(let version): return "下载 \(version) 失败，点击重试"
            }
        }
        var acceptsClick: Bool {
            if case .downloading = self { return false }
            return label != nil
        }
    }
    private let installed: ReleaseVersion
    private var timer: Timer?
    private var checking = false
    private var generation = UUID()
    private var offer: DownloadRelease?
    private(set) var state: State = .hidden { didSet { changed?(state) } }
    var changed: ((State) -> Void)?
    var checked: ((String) -> Void)?

    init(version: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") {
        installed = ReleaseVersion(version, installed: true) ?? ReleaseVersion("0.0.0")!
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(fire: Date().addingTimeInterval(12), interval: 6 * 60 * 60,
                          repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func check(manual: Bool = false) {
        if case .downloaded = state { return activate() }
        guard !checking else { return }
        if case .downloading = state { return }
        checking = true
        let token = generation
        Task { [weak self] in
            defer { self?.checking = false }
            do {
                let bytes = try await UpdateTransfer.load(DownloadRelease.feedURL, limit: 1024 * 1024)
                guard let self, self.generation == token else { return }
                let next = try DownloadRelease.select(bytes, installed: self.installed)
                self.offer = next
                self.state = next.map { .available($0.version) } ?? .hidden
                if manual { self.checked?(next.map { "可下载新版 \($0.version)" } ?? "当前已是最新发布版本") }
            } catch {
                guard let self, self.generation == token else { return }
                if manual { self.checked?("暂未获取到可用版本，请稍后重试") }
            }
        }
    }

    func activate() {
        if case .downloaded(let url) = state {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        guard state.acceptsClick, let offer else { return }
        generation = UUID()
        state = .downloading
        Task { [weak self] in
            do {
                let url = try await Task.detached(priority: .utility) {
                    try await Self.download(offer)
                }.value
                self?.state = .downloaded(url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                self?.state = .retry(offer.version)
            }
        }
    }

    private nonisolated static func download(_ release: DownloadRelease) async throws -> URL {
        let files = FileManager.default
        let downloads = try files.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = downloads.appendingPathComponent("GPT娘桌宠-\(release.version)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var keep = false
        defer { if !keep { try? files.removeItem(at: directory) } }
        let partial = directory.appendingPathComponent(release.fileName + ".download")
        _ = try await UpdateTransfer.load(release.url, limit: release.size, destination: partial)
        try release.verify(partial)
        // Preserve normal macOS download handling when the ZIP is opened by the user.
        let quarantine = "0083;\(String(Int(Date().timeIntervalSince1970), radix: 16));GPTDragon;\(UUID().uuidString)"
        let result = quarantine.withCString {
            setxattr(partial.path, "com.apple.quarantine", $0, strlen($0), 0, 0)
        }
        guard result == 0 else { throw DownloadUpdateError.downloadFailed }
        let destination = directory.appendingPathComponent(release.fileName)
        try files.moveItem(at: partial, to: destination)
        keep = true
        return destination
    }
}

