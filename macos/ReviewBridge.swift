import Foundation
import Darwin
import CoreFoundation


struct ReviewQuestion {
    struct Option {
        let label: String
        let detail: String
    }
    let id: String
    let title: String
    let text: String
    let options: [Option]
    let allowsOther: Bool
    let secret: Bool
}

struct LiveReview {
    let thread: String
    let owner: String
    let request: Any
    let requestKey: String
    let method: String
    let payload: [String: Any]

    enum Kind {
        case decision(title: String, detail: String, allowed: [String], route: String)
        case permissions(detail: String, grants: [String: Any])
        case questions([ReviewQuestion])
        case computerUse(message: String, detail: String)
        case native
    }

    var key: String { thread + ":" + method + ":" + requestKey }
    var isQuestion: Bool { method == "item/tool/requestUserInput" || method == "item/tool/requestOptionPicker" }

    static func decode(_ row: [String: Any], thread: String, owner: String) -> LiveReview? {
        guard let method = row["method"] as? String, let params = row["params"] as? [String: Any],
              let id = row["id"], params["threadId"] as? String == thread,
              row["completed"] as? Bool != true else { return nil }
        let identity: String
        if let value = id as? String, !value.isEmpty { identity = "s:" + value }
        else if let value = id as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() { identity = "n:" + value.stringValue }
        else { return nil }
        return LiveReview(thread: thread, owner: owner, request: id, requestKey: identity, method: method, payload: params)
    }

    var kind: Kind {
        switch method {
        case "item/commandExecution/requestApproval":
            let title: String
            var detail: [String] = []
            if let network = payload["networkApprovalContext"] as? [String: Any],
               let host = network["host"] as? String, !host.isEmpty {
                title = "允许网络访问？"
                detail.append(host)
                if let proto = network["protocol"] as? String { detail.append(proto) }
            } else if let command = payload["command"] as? String, !command.isEmpty {
                title = "允许运行此命令？"
                detail.append(command)
                if let cwd = payload["cwd"] as? String { detail.append(cwd) }
            } else { return .native }
            if let reason = payload["reason"] as? String { detail.append(reason) }
            guard detail.joined().count <= 650 else { return .native }
            let supported = ["accept", "acceptForSession", "decline", "cancel"]
            let advertised: [String]
            if let raw = payload["availableDecisions"], !(raw is NSNull) {
                guard let choices = raw as? [Any] else { return .native }
                advertised = choices.compactMap { $0 as? String }
            } else {
                advertised = ["accept", "decline"]
            }
            let allowed = supported.filter(advertised.contains)
            guard !allowed.isEmpty else { return .native }
            return .decision(title: title, detail: detail.joined(separator: "\n"), allowed: allowed,
                             route: "thread-follower-command-approval-decision")
        case "item/permissions/requestApproval":
            guard let requested = payload["permissions"] as? [String: Any],
                  Set(requested.keys).isSubset(of: ["network", "fileSystem"]) else { return .native }
            var grants: [String: Any] = [:]
            var detail: [String] = []
            if let raw = requested["network"], !(raw is NSNull) {
                guard let network = raw as? [String: Any], Set(network.keys) == ["enabled"],
                      let enabled = network["enabled"] as? NSNumber, CFGetTypeID(enabled) == CFBooleanGetTypeID()
                else { return .native }
                if enabled.boolValue {
                    grants["network"] = ["enabled": true]
                    detail.append("网络访问")
                }
            }
            if let raw = requested["fileSystem"], !(raw is NSNull) {
                guard let files = raw as? [String: Any],
                      Set(files.keys).isSubset(of: ["read", "write", "entries", "globScanMaxDepth"]) else { return .native }
                var displayedFiles: [String] = []
                for (field, label) in [("read", "读取"), ("write", "写入")] {
                    guard let value = files[field], !(value is NSNull) else { continue }
                    guard let paths = value as? [String], paths.count <= 8,
                          paths.allSatisfy({ $0.hasPrefix("/") && $0.count <= 240 && $0.rangeOfCharacter(from: .newlines) == nil })
                    else { return .native }
                    displayedFiles += paths.map { label + " " + $0 }
                }
                if let rawEntries = files["entries"], !(rawEntries is NSNull) {
                    guard let entries = rawEntries as? [[String: Any]], entries.count <= 8 else { return .native }
                    for entry in entries {
                        guard let access = entry["access"] as? String, ["read", "write", "deny"].contains(access),
                              let path = entry["path"] as? [String: Any], path["type"] as? String == "path",
                              let name = path["path"] as? String, name.hasPrefix("/"), name.count <= 240,
                              name.rangeOfCharacter(from: .newlines) == nil else { return .native }
                        let label = access == "read" ? "读取" : access == "write" ? "写入" : "排除"
                        displayedFiles.append(label + " " + name)
                    }
                }
                if !displayedFiles.isEmpty {
                    grants["fileSystem"] = files
                    detail += displayedFiles
                }
            }
            if let reason = payload["reason"] as? String, !reason.isEmpty { detail.append(reason) }
            guard !grants.isEmpty, detail.joined().count <= 850 else { return .native }
            return .permissions(detail: detail.joined(separator: "\n"), grants: grants)
        case "item/tool/requestUserInput":
            guard let rows = payload["questions"] as? [[String: Any]], (1...3).contains(rows.count) else { return .native }
            let questions: [ReviewQuestion] = rows.compactMap { row in
                guard let id = row["id"] as? String, !id.isEmpty,
                      let question = row["question"] as? String, question.count <= 300 else { return nil }
                let options = (row["options"] as? [[String: Any]] ?? []).compactMap { option -> ReviewQuestion.Option? in
                    guard let label = option["label"] as? String, !label.isEmpty, label.count <= 130 else { return nil }
                    return .init(label: label, detail: option["description"] as? String ?? "")
                }
                guard options.count <= 5, options.allSatisfy({ $0.detail.count <= 200 }),
                      options.count == (row["options"] as? [[String: Any]] ?? []).count,
                      Set(options.map(\.label)).count == options.count else { return nil }
                return ReviewQuestion(id: id, title: row["header"] as? String ?? "", text: question, options: options,
                                      allowsOther: row["isOther"] as? Bool == true || options.isEmpty,
                                      secret: row["isSecret"] as? Bool == true)
            }
            guard questions.count == rows.count, Set(questions.map(\.id)).count == questions.count else { return .native }
            return .questions(questions)
        case "mcpServer/elicitation/request":
            // Computer Use's application confirmation has a known, narrowly scoped
            // schema. Other elicitations can contain forms, authentication or
            // execution-bound approvals and must remain in Codex.
            guard payload["mode"] as? String == "form",
                  let schema = payload["requestedSchema"] as? [String: Any],
                  schema["type"] as? String == "object",
                  let properties = schema["properties"] as? [String: Any], properties.isEmpty,
                  (schema["required"] as? [String] ?? []).isEmpty,
                  let meta = payload["_meta"] as? [String: Any],
                  meta["codex_approval_kind"] as? String == "mcp_tool_call",
                  meta["connector_id"] as? String == "computer-use",
                  let persist = meta["persist"] as? [String], persist.contains("session"),
                  let tool = meta["tool_name"] as? String, !tool.isEmpty, tool.count <= 120,
                  let params = meta["tool_params"] as? [String: Any], Set(params.keys) == ["app"],
                  let app = params["app"] as? String, !app.isEmpty, app.count <= 300,
                  let display = meta["tool_params_display"] as? [[String: Any]], display.count == 1,
                  display[0]["name"] as? String == "app",
                  let appName = display[0]["value"] as? String, !appName.isEmpty, appName.count <= 200,
                  let message = payload["message"] as? String, !message.isEmpty, message.count <= 600 else { return .native }
            var detail = "应用：\(appName)\n标识：\(app)\n操作：\(tool)"
            if let subtitle = meta["subtitle"] as? String, !subtitle.isEmpty {
                guard subtitle.count <= 400 else { return .native }
                detail += "\n" + subtitle
            }
            if meta["riskLevel"] as? String == "high" { detail += "\n高风险操作" }
            return .computerUse(message: message, detail: detail)
        default: return .native
        }
    }

    func response(decision: String) -> (String, [String: Any])? {
        switch kind {
        case let .decision(_, _, allowed, route) where allowed.contains(decision):
            return (route, ["conversationId": thread, "requestId": request, "decision": decision])
        case let .permissions(_, grants) where ["accept", "decline"].contains(decision):
            let response: [String: Any] = ["permissions": decision == "accept" ? grants : [:], "scope": "turn"]
            return ("thread-follower-permissions-request-approval-response",
                    ["conversationId": thread, "requestId": request, "response": response])
        case .computerUse where ["acceptForSession", "decline"].contains(decision):
            let accepted = decision == "acceptForSession"
            let response: [String: Any] = ["action": accepted ? "accept" : "decline",
                                           "content": accepted ? [:] : NSNull(),
                                           "_meta": accepted ? ["persist": "session"] : NSNull()]
            return ("thread-follower-submit-mcp-server-elicitation-response",
                    ["conversationId": thread, "requestId": request, "response": response])
        default:
            return nil
        }
    }

    func response(answers: [String: String]) -> (String, [String: Any])? {
        guard case let .questions(questions) = kind, answers.count == questions.count else { return nil }
        var encoded: [String: [String: [String]]] = [:]
        for q in questions {
            guard let value = answers[q.id], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.utf8.count <= 4096, q.allowsOther || q.options.contains(where: { $0.label == value }) else { return nil }
            encoded[q.id] = ["answers": [value]]
        }
        return ("thread-follower-submit-user-input", ["conversationId": thread, "requestId": request,
                                                      "response": ["answers": encoded]])
    }
}

// The desktop's same-user window coordination channel. A length-prefixed frame
// is decoded transiently. Only the selected conversation's pending requests survive.
protocol ReviewTransport: AnyObject {
    var received: (([String: Any]) -> Void)? { get set }
    var disconnected: (() -> Void)? { get set }
    func start(path: String, initializationID: String)
    func send(_ object: [String: Any])
    func stop()
}

final class ReviewSocket: ReviewTransport {
    private let queue = DispatchQueue(label: "local.gptdragon.review-socket", qos: .utility)
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var buffer = Data()
    // A long Codex conversation can produce a snapshot much larger than 8 MB.
    // Keep a bounded ceiling, but allow realistic desktop conversation snapshots.
    private let limit = 128 * 1024 * 1024
    var received: (([String: Any]) -> Void)?
    var disconnected: (() -> Void)?

    func start(path: String, initializationID: String) {
        queue.async { [weak self] in self?.connect(path, initializationID: initializationID) }
    }

    func send(_ object: [String: Any]) {
        queue.async { [weak self] in
            guard let self, self.fd >= 0,
                  let data = try? JSONSerialization.data(withJSONObject: object), data.count <= self.limit else { return }
            var length = UInt32(data.count).littleEndian
            var frame = withUnsafeBytes(of: &length) { Data($0) }
            frame.append(data)
            let ok = frame.withUnsafeBytes { raw -> Bool in
                guard let base = raw.baseAddress else { return false }
                var written = 0
                while written < raw.count {
                    let n = Darwin.send(self.fd, base.advanced(by: written), raw.count - written, 0)
                    if n < 0, errno == EINTR { continue }
                    guard n > 0 else { return false }
                    written += n
                }
                return true
            }
            if !ok {
                self.close()
            }
        }
    }

    func stop() { queue.async { self.close() } }

    private func connect(_ path: String, initializationID: String) {
        var address = sockaddr_un()
        let bytes = Array(path.utf8CString)
        var info = stat()
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path),
              lstat(path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK,
              info.st_mode & 0o077 == 0 else {
                  close(); return }
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { close(); return }
        var one: Int32 = 1
        var deadline = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &deadline, socklen_t(MemoryLayout.size(ofValue: deadline)))
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in bytes.enumerated() { raw[index] = UInt8(bitPattern: byte) }
        }
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard status == 0, getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
            close(); return }
        let descriptor = fd
        let event = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        event.setCancelHandler { Darwin.close(descriptor) }
        event.setEventHandler { [weak self] in self?.readFrame() }
        source = event
        event.resume()
        send(["type": "request", "requestId": initializationID, "sourceClientId": "initializing-client", "version": 0,
              "method": "initialize", "params": ["clientType": "gptdragon"]])
    }

    private func readFrame() {
        var chunk = [UInt8](repeating: 0, count: 16384)
        let length = chunk.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, $0.count, 0) }
        if length < 0, errno == EINTR { return }
        guard length > 0 else {
            close(); return }
        buffer.append(contentsOf: chunk.prefix(length))
        while buffer.count >= 4 {
            let n = buffer.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
            guard n > 0, n <= limit else {
                close(); return }
            guard buffer.count >= n + 4 else { return }
            let json = buffer.subdata(in: 4 ..< n + 4)
            // Release a large snapshot's backing storage once it has been consumed.
            if n > 8 * 1024 * 1024 { buffer = Data(buffer.dropFirst(n + 4)) }
            else { buffer.removeSubrange(0 ..< n + 4) }
            guard let message = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { continue }
            // Only project types that we handle. An unrelated thread is never
            // displayed or used to send a response.
            received?(message)
        }
    }

    private func close() {
        if let source { source.cancel() }
        else if fd >= 0 { Darwin.close(fd) }
        source = nil
        fd = -1
        buffer = Data()
        disconnected?()
    }
}

final class ReviewBridge {
    private let makeTransport: () -> ReviewTransport
    private var socket: ReviewTransport?
    private var client: String?
    private var initializeID: String?
    private var streams: [String: (owner: String, revision: Int)] = [:]

    init(makeTransport: @escaping () -> ReviewTransport = { ReviewSocket() }) {
        self.makeTransport = makeTransport
    }
    private var wanted: Set<String> = []
    private var followed: Set<String> = []
    private var byThread: [String: [LiveReview]] = [:]
    private var refreshing: Set<String> = []
    private var sent: Set<String> = []
    private var awaiting: [String: (owner: String, key: String, thread: String)] = [:]
    private var generation = UUID()
    private(set) var status = "本机连接未启用"
    private(set) var successRevision = 0
    var inFlightCount: Int { awaiting.count }
    var isRefreshingRequests: Bool { !refreshing.isEmpty }
    var didChange: (() -> Void)?
    var isEnabled: Bool { socket != nil }
    var isReady: Bool { client != nil }
    var reviews: [LiveReview] {
        byThread.keys.sorted().flatMap { byThread[$0] ?? [] }.filter { !sent.contains($0.key) }
    }

    func start(path: String) {
        guard socket == nil else { return }
        let token = UUID()
        generation = token
        status = "正在连接本机 Codex…"
        let transport = makeTransport()
        let id = UUID().uuidString
        initializeID = id
        transport.received = { [weak self] message in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.consume(message)
            }
        }
        transport.disconnected = { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.reset(status: "本机连接不可用，可回到 Codex 处理")
            }
        }
        socket = transport
        didChange?()
        transport.start(path: path, initializationID: id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.generation == token, self.client == nil else { return }
            self.reset(status: "连接超时，可回到 Codex 处理")
        }
    }

    func stop() { reset(status: "本机连接未启用") }

    private func reset(status: String) {
        generation = UUID()
        socket?.stop()
        socket = nil
        client = nil
        initializeID = nil
        streams.removeAll()
        followed.removeAll()
        byThread.removeAll()
        refreshing.removeAll()
        awaiting.removeAll()
        sent.removeAll()
        self.status = status
        didChange?()
    }

    func watch(_ threads: [String]) {
        let next = Set(threads.prefix(6).filter { UUID(uuidString: $0) != nil })
        guard wanted != next else { return }
        wanted = next
        sync()
    }

    private func sync() {
        guard client != nil else { return }
        let removed = followed.subtracting(wanted)
        for id in removed {
            follow(id, false)
            byThread[id] = nil
            streams[id] = nil
            refreshing.remove(id)
        }
        for id in wanted.subtracting(followed) { follow(id, true) }
        followed = wanted
        if !removed.isEmpty { didChange?() }
    }

    private func follow(_ id: String, _ following: Bool) {
        guard let client else { return }
        socket?.send(["type": "broadcast", "method": "thread-stream-following-changed", "version": 1,
                      "sourceClientId": client, "params": ["conversationId": id, "hostId": "local", "following": following]])
    }

    private func consume(_ message: [String: Any]) {
        if message["type"] as? String == "client-discovery-request",
           let id = message["requestId"] as? String {
            socket?.send(["type": "client-discovery-response", "requestId": id, "response": ["canHandle": false]])
            return
        }
        if message["type"] as? String == "response" {
            if client == nil, let initializeID, message["requestId"] as? String == initializeID,
               message["method"] as? String == "initialize",
               message["resultType"] as? String == "success",
               let id = (message["result"] as? [String: Any])?["clientId"] as? String,
               UUID(uuidString: id) != nil {
                client = id
                status = "已连接本机 Codex"
                sync()
                didChange?()
            } else if let id = message["requestId"] as? String, let pending = awaiting.removeValue(forKey: id) {
                if message["resultType"] as? String == "success", message["handledByClientId"] as? String == pending.owner {
                    status = "已提交到 Codex"
                    successRevision += 1
                } else {
                    sent.remove(pending.key)
                    status = "Codex 未确认提交，请在原版核对"
                    follow(pending.thread, true)
                }
                didChange?()
            }
            return
        }
        guard client != nil, message["type"] as? String == "broadcast",
              let method = message["method"] as? String, let params = message["params"] as? [String: Any] else { return }
        if method == "client-status-changed", params["status"] as? String == "disconnected",
           let owner = params["clientId"] as? String {
            let lost = streams.keys.filter { streams[$0]?.owner == owner }
            for id in lost {
                byThread[id] = nil
                streams[id] = nil
                refreshing.remove(id)
                follow(id, true)
            }
            if !lost.isEmpty { didChange?() }
            return
        }
        guard params["hostId"] as? String == "local",
              let id = params["conversationId"] as? String, wanted.contains(id),
              let owner = message["sourceClientId"] as? String, UUID(uuidString: owner) != nil else { return }
        if method == "thread-stream-following-status-requested", message["version"] as? Int == 1 {
            // A newly resumed Codex owner can ask existing followers to announce again.
            follow(id, true)
            return
        }
        // Both stream versions carry the pending requests in conversationState.requests.
        guard method == "thread-stream-state-changed",
              let version = message["version"] as? Int, [11, 13].contains(version),
              let change = params["change"] as? [String: Any], let revision = change["revision"] as? Int else { return }
        let stream = streams[id]
        if change["type"] as? String == "snapshot",
           let state = change["conversationState"] as? [String: Any],
           let requests = state["requests"] as? [[String: Any]] {
            guard revision >= (stream?.owner == owner ? stream?.revision ?? 0 : 0) else { return }
            streams[id] = (owner, revision)
            let old = byThread[id] ?? []
            let decoded = requests.prefix(8).compactMap { LiveReview.decode($0, thread: id, owner: owner) }
            byThread[id] = decoded
            let wasRefreshing = refreshing.remove(id) != nil
            let present = Set(decoded.map(\.key))
            for review in old where review.owner != owner || !present.contains(review.key) { sent.remove(review.key) }
            if old.map(\.key) != decoded.map(\.key) || !decoded.isEmpty || wasRefreshing { didChange?() }
        } else if change["type"] as? String == "patches",
                  let patches = change["patches"] as? [[String: Any]] {
            guard stream == nil || stream?.owner == owner else { return }
            let needsRefresh = stream == nil || change["baseRevision"] as? Int != stream?.revision
                || patches.contains { patch in
                    guard let path = patch["path"] as? [Any] else { return true }
                    return path.isEmpty || path.first as? String == "requests"
                }
            if needsRefresh, refreshing.insert(id).inserted {
                byThread[id] = nil
                follow(id, true)
                didChange?()
            } else if !needsRefresh {
                streams[id] = (owner, revision)
            }
        }
    }

    func submit(_ review: LiveReview, decision: String) {
        submit(review, response: review.response(decision: decision))
    }
    func submit(_ review: LiveReview, answers: [String: String]) {
        submit(review, response: review.response(answers: answers))
    }

    private func submit(_ review: LiveReview, response: (String, [String: Any])?) {
        guard let client, let response,
              let current = byThread[review.thread]?.first(where: { $0.key == review.key }),
              current.owner == review.owner,
              NSDictionary(dictionary: current.payload).isEqual(to: review.payload),
              sent.insert(review.key).inserted else {
            status = "请求已更新，请在 Codex 核对"
            didChange?()
            return
        }
        let id = UUID().uuidString
        awaiting[id] = (review.owner, review.key, review.thread)
        status = "正在提交给 Codex…"
        socket?.send(["type": "request", "method": response.0, "requestId": id, "sourceClientId": client,
                      "targetClientId": review.owner, "version": 1, "timeoutMs": 5000, "params": response.1])
        didChange?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, let pending = self.awaiting.removeValue(forKey: id) else { return }
            self.sent.remove(pending.key)
            self.follow(pending.thread, true)
            self.status = "提交未获确认，请在 Codex 核对"
            self.didChange?()
        }
    }
}
