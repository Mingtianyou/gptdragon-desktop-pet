import Foundation
import SQLite3

enum TurnStatus: String {
    case inProgress, completed, failed, interrupted
    var label: String {
        switch self {
        case .inProgress: return "进行中"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .interrupted: return "已中断"
        }
    }
    var symbol: String {
        switch self {
        case .inProgress: return "hourglass"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .interrupted: return "pause.circle.fill"
        }
    }
}

struct Turn: Equatable {
    let id: String
    let status: TurnStatus
    let started: Int64
    let ended: Int64
}

struct ChatActivity: Equatable {
    let id: String
    let title: String
    var turn: Turn?
    var stage: WorkStage? = nil
}

struct WorkStage: Equatable {
    let kind: String
    let finishedAt: Int64
    var tool: String? = nil

    private var toolLabel: String? {
        guard let tool, !tool.isEmpty, tool.utf8.count <= 36,
              tool.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) ||
                  (48...57).contains($0) || [45, 46, 95].contains($0) }) else { return nil }
        switch tool.lowercased() {
        case "js": return "JS"
        case "python": return "Python"
        case "web_search", "search_query": return "网页搜索"
        default: return tool
        }
    }

    var label: String {
        let verb: String
        switch kind {
        case "commandExecution": verb = "执行命令"
        case "fileChange": verb = "修改文件"
        case "webSearch": verb = "搜索网页"
        case "mcpToolCall", "dynamicToolCall": verb = toolLabel.map { "调用 " + $0 } ?? "调用工具"
        case "imageView": verb = "查看图片"
        case "imageGeneration": verb = "生成图片"
        case "plan": verb = "整理计划"
        case "contextCompaction": verb = "整理上下文"
        case "agentMessage": verb = "整理回复"
        case "subAgentActivity", "collabAgentToolCall": verb = "协调子任务"
        default: return "思考中"
        }
        return finishedAt > 0 ? "刚完成 · " + verb : "正在" + verb
    }
}

struct ActivitySnapshot: Equatable {
    var chats: [ChatActivity]
    var turnsAvailable = true
    var catalogAvailable = true
    var working: [ChatActivity] { chats.filter { $0.turn?.status == .inProgress } }
}

enum ActivityError: Error { case database }

private final class ReadDatabase {
    private var handle: OpaquePointer?
    init(_ url: URL) throws {
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            handle = nil
            throw ActivityError.database
        }
        sqlite3_busy_timeout(handle, 150)
        guard sqlite3_db_readonly(handle, "main") == 1,
              sqlite3_exec(handle, "PRAGMA query_only=ON; PRAGMA trusted_schema=OFF; PRAGMA cache_size=-256;", nil, nil, nil) == SQLITE_OK
        else {
            sqlite3_close(handle)
            handle = nil
            throw ActivityError.database
        }
    }
    deinit { sqlite3_close(handle) }
    func rows(_ query: String, bind: ((OpaquePointer) -> Void)? = nil, row: (OpaquePointer) -> Void) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, query, -1, &statement, nil) == SQLITE_OK, let s = statement else { throw ActivityError.database }
        bind?(s)
        while true {
            switch sqlite3_step(s) {
            case SQLITE_ROW: row(s)
            case SQLITE_DONE: return
            default: throw ActivityError.database
            }
        }
    }
}

private func string(_ row: OpaquePointer, _ column: Int32) -> String {
    guard let raw = sqlite3_column_text(row, column) else { return "" }
    return String(cString: raw)
}

enum CodexLinks {
    static func chat(_ id: String) -> URL? {
        guard UUID(uuidString: id) != nil else { return nil }
        return URL(string: "codex://threads/\(id)")
    }

    static func draft(_ text: String) -> URL? {
        var link = URLComponents()
        link.scheme = "codex"
        link.host = "threads"
        link.path = "/new"
        if !text.isEmpty {
            // Encode plus as data, as the receiving app may use form-style URLSearchParams.
            let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
            guard let value = text.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
            link.percentEncodedQuery = "prompt=" + value
        }
        return link.url
    }
}

struct RecentChatFiles {
    let id: String
    let title: String
    var files: [URL]
}

enum DeliveryFiles {
    private static let documentExtensions: Set<String> = [
        "pdf", "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "svg",
        "mp4", "mov", "m4v", "mp3", "m4a", "wav", "txt", "md", "csv",
        "docx", "xlsx", "pptx", "pages", "numbers", "key"
    ]
    private static let packageExtensions: Set<String> = ["zip", "dmg", "pkg", "app", "7z", "tar", "gz"]
    private static let link = try! NSRegularExpression(pattern: #"!?\[[^\]\r\n]+\]\((?:<([^>\r\n]+)>|([^<)\r\n]+))\)"#)

    static func canOpen(_ url: URL) -> Bool {
        documentExtensions.contains(url.resolvingSymlinksInPath().pathExtension.lowercased())
    }

    static func appendLinks(in reply: String, to files: inout [URL]) {
        var fence: String?
        for raw in reply.split(whereSeparator: \.isNewline) where files.count < 2 {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let marker = ["```", "~~~"].first(where: { line.hasPrefix($0) }) {
                if fence == marker { fence = nil }
                else if fence == nil { fence = marker }
                continue
            }
            guard fence == nil else { continue }
            link.enumerateMatches(in: line, range: NSRange(line.startIndex..., in: line)) { match, _, stop in
                guard let match, let range = Range(match.range(at: 1), in: line) ?? Range(match.range(at: 2), in: line),
                      let url = localFile(String(line[range])), !files.contains(url) else { return }
                files.append(url)
                if files.count == 2 { stop.pointee = true }
            }
        }
    }

    private static func localFile(_ destination: String) -> URL? {
        let target = destination.trimmingCharacters(in: .whitespaces)
        let path: String
        if target.hasPrefix("/") && !target.hasPrefix("//") { path = target }
        else if let url = URL(string: target), url.isFileURL,
                url.host == nil || url.host == "" || url.host == "localhost" { path = url.path }
        else { return nil }
        guard path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count <= 4_096 else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let ext = url.pathExtension.lowercased()
        guard documentExtensions.contains(ext) || packageExtensions.contains(ext) || url.pathComponents.contains("outputs"),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isPackageKey]),
              values.isRegularFile == true || values.isPackage == true else { return nil }
        return url
    }
}

struct ActivityReader {
    let root: URL
    var fallbackRoot: URL? = nil

    static func local(override: URL? = nil) -> ActivityReader {
        if let override { return ActivityReader(root: override) }
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        let configured = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
        guard let configured else { return ActivityReader(root: home) }
        return ActivityReader(root: URL(fileURLWithPath: configured, isDirectory: true), fallbackRoot: home)
    }

    func read(launchedAt: Date?) throws -> ActivitySnapshot {
        do {
            let primary = try read(root: root, launchedAt: launchedAt)
            if (primary.catalogAvailable && primary.turnsAvailable) || fallbackRoot == nil { return primary }
            if let fallbackRoot, let fallback = try? read(root: fallbackRoot, launchedAt: launchedAt),
               fallback.catalogAvailable && (fallback.turnsAvailable || !primary.catalogAvailable) { return fallback }
            return primary
        } catch {
            guard let fallbackRoot else { throw error }
            return try read(root: fallbackRoot, launchedAt: launchedAt)
        }
    }

    func recentDeliveryFiles() -> [RecentChatFiles] {
        if let files = try? recentDeliveryFiles(in: root) { return files }
        guard let fallbackRoot else { return [] }
        return (try? recentDeliveryFiles(in: fallbackRoot)) ?? []
    }

    private func recentDeliveryFiles(in folder: URL) throws -> [RecentChatFiles] {
        let (history, columns) = try database(in: folder, prefix: "thread_history", knownVersion: 1,
                                              table: "thread_turns", requiring: [
                                                "thread_id", "turn_id", "rollout_ordinal", "status", "completed_at"
                                              ])
        let finalAgentID = columns.contains("final_agent_item_id") ? "nullif(r.final_agent_item_id,'')," : ""
        let catalog = try? database(in: folder, prefix: "state", knownVersion: 5, table: "threads", requiring: ["id"])
        let titleFields = ["name", "title"].filter { catalog?.1.contains($0) == true }.map { "nullif(trim(\($0)), '')" }
        let titleSQL = "coalesce(" + (titleFields + ["NULL", "''"]).joined(separator: ",") + ")"
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var groups: [RecentChatFiles] = []
        var catalogIDs: [String: (String, String)] = [:]
        func conversation(_ historyID: String) -> (String, String) {
            if let cached = catalogIDs[historyID] { return cached }
            var result = (historyID, "未命名对话")
            if let (db, cols) = catalog {
                let byRollout = cols.contains("rollout_path")
                let alias = byRollout ? " OR substr(rollout_path, -length(?2))=?2" : ""
                try? db.rows("SELECT id, substr(\(titleSQL),1,100) FROM threads WHERE id=?1\(alias) ORDER BY (id=?1) DESC LIMIT 1", bind: { row in
                    sqlite3_bind_text(row, 1, historyID, -1, transient)
                    if byRollout { sqlite3_bind_text(row, 2, "_\(historyID).jsonl", -1, transient) }
                }) { row in
                    let title = string(row, 1)
                    result = (string(row, 0), title.isEmpty ? "未命名对话" : title)
                }
            }
            catalogIDs[historyID] = result
            return result
        }
        try history.rows("""
            WITH recent AS (
                SELECT * FROM thread_turns
                WHERE status='completed' AND completed_at IS NOT NULL
                ORDER BY completed_at DESC, rollout_ordinal DESC LIMIT 48
            )
            SELECT r.thread_id, CASE WHEN json_valid(i.item_json) THEN substr(json_extract(i.item_json,'$.text'),1,32768) END
            FROM recent r JOIN thread_items i ON i.thread_id=r.thread_id AND i.turn_id=r.turn_id
            AND i.item_id=coalesce(\(finalAgentID) (
                SELECT f.item_id FROM thread_items f
                WHERE f.thread_id=r.thread_id AND f.turn_id=r.turn_id AND f.item_type='agentMessage'
                  AND CASE WHEN json_valid(f.item_json) THEN json_extract(f.item_json,'$.phase') END='final_answer'
                ORDER BY f.rollout_ordinal DESC LIMIT 1
            ), '')
            WHERE i.item_type='agentMessage'
            ORDER BY r.completed_at DESC, r.rollout_ordinal DESC
            """) { row in
                let (id, title) = conversation(string(row, 0))
                if let index = groups.firstIndex(where: { $0.id == id }) {
                    DeliveryFiles.appendLinks(in: string(row, 1), to: &groups[index].files)
                } else if groups.count < 3 {
                    var files: [URL] = []
                    DeliveryFiles.appendLinks(in: string(row, 1), to: &files)
                    if !files.isEmpty { groups.append(RecentChatFiles(id: id, title: title, files: files)) }
                }
            }
        return groups
    }

    private func database(in folder: URL, prefix: String, knownVersion: Int, table: String, requiring required: Set<String>) throws -> (ReadDatabase, Set<String>) {
        let fm = FileManager.default
        let known = folder.appendingPathComponent("\(prefix)_\(knownVersion).sqlite")
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        let versions = names.compactMap { name -> (Int, String)? in
            let beginning = prefix + "_"
            guard name.hasPrefix(beginning), name.hasSuffix(".sqlite"),
                  let version = Int(name.dropFirst(beginning.count).dropLast(7)) else { return nil }
            return (version, name)
        }.sorted { $0.0 > $1.0 }
        let urls = versions.map { folder.appendingPathComponent($0.1) } + (versions.isEmpty ? [known] : [])
        for url in urls {
            guard let db = try? ReadDatabase(url) else { continue }
            var columns: Set<String> = []
            try? db.rows("PRAGMA table_info(\(table))") { columns.insert(string($0, 1)) }
            if required.isSubset(of: columns) { return (db, columns) }
        }
        throw ActivityError.database
    }

    private func read(root: URL, launchedAt: Date?) throws -> ActivitySnapshot {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let currentStart = launchedAt.map { Int64($0.timeIntervalSince1970) - 2 } ?? Int64.max
        var active: [(String, Turn)] = []
        // A resumed/paginated conversation can keep its visible ID while its
        // current turns are written under the suffix of its rollout filename.
        var activeHistoryIDs: [String: String] = [:]
        var chats: [ChatActivity] = []
        var catalogAvailable = false
        var turnsAvailable = false
        let historyInfo = try? database(in: root, prefix: "thread_history", knownVersion: 1, table: "thread_turns", requiring: ["thread_id","turn_id","status","started_at","completed_at","rollout_ordinal"])
        let history = historyInfo.flatMap { info in
            Set(["thread_id","turn_id","status","started_at","completed_at","rollout_ordinal"]).isSubset(of: info.1) ? info.0 : nil
        }

        func turn(_ row: OpaquePointer, offset: Int32) -> Turn? {
            guard let status = TurnStatus(rawValue: string(row, offset + 1)) else { return nil }
            return Turn(id: string(row, offset), status: status, started: sqlite3_column_int64(row, offset + 2),
                        ended: sqlite3_column_int64(row, offset + 3))
        }
        if let history {
            do {
                var seen = Set<String>()
                try history.rows("""
                    SELECT thread_id,turn_id,status,started_at,completed_at FROM thread_turns
                    WHERE status='inProgress' AND started_at>=? ORDER BY started_at DESC LIMIT 32
                    """, bind: { sqlite3_bind_int64($0, 1, currentStart) }) { row in
                    let id = string(row, 0)
                    if UUID(uuidString: id) != nil, seen.insert(id).inserted, let value = turn(row, offset: 1) {
                        active.append((id, value))
                    }
                }
                turnsAvailable = true
            } catch { active.removeAll() }
        }

        if let (state, cols) = try? database(in: root, prefix: "state", knownVersion: 5, table: "threads", requiring: ["id"]) {
            let titleColumns = ["name","title"].filter { cols.contains($0) }.map { "nullif(trim(\($0)), '')" }
            let title = "coalesce(" + (titleColumns + ["NULL", "''"]).joined(separator: ",") + ")"
            let order = ["recency_at_ms","updated_at_ms","recency_at","updated_at","created_at"].first { cols.contains($0) } ?? "id"
            var filters = ["1"]
            if cols.contains("archived") { filters.append("coalesce(archived,0)=0") }
            if cols.contains("source") { filters.append("coalesce(source,'') NOT LIKE '%subagent%'") }
            let rollout = cols.contains("rollout_path") ? "coalesce(rollout_path,'')" : "''"
            let base = "SELECT id,substr(\(title),1,100),\(rollout) FROM threads WHERE " + filters.joined(separator: " AND ")
            var seen = Set<String>()
            func append(_ row: OpaquePointer) {
                let id = string(row, 0)
                guard UUID(uuidString: id) != nil, seen.insert(id).inserted else { return }
                let title = string(row, 1).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                // Keep the current history ID after a turn stops being active,
                // so completion and failure are read from the same record.
                if activeHistoryIDs[id] == nil {
                    let filename = URL(fileURLWithPath: string(row, 2)).lastPathComponent
                    let parts = filename.hasSuffix(".jsonl") ? String(filename.dropLast(6)).split(separator: "_") : []
                    if parts.count >= 2, parts[parts.count - 2].lowercased().hasSuffix(id.lowercased()) {
                        let actual = String(parts[parts.count - 1])
                        if UUID(uuidString: actual) != nil { activeHistoryIDs[id] = actual }
                    }
                }
                chats.append(ChatActivity(id: id, title: title.isEmpty ? "未命名对话" : title, turn: nil))
            }
            do {
                for (id, _) in active {
                    try state.rows(base + " AND id=? LIMIT 1", bind: { sqlite3_bind_text($0, 1, id, -1, transient) }) { row in
                        if activeHistoryIDs[id] == nil { activeHistoryIDs[id] = id }
                        append(row)
                    }
                    if cols.contains("rollout_path") {
                        let suffix = "_\(id).jsonl"
                        try state.rows(base + " AND substr(rollout_path, -length(?)) = ? LIMIT 1", bind: { statement in
                            sqlite3_bind_text(statement, 1, suffix, -1, transient)
                            sqlite3_bind_text(statement, 2, suffix, -1, transient)
                        }) { row in
                            let visibleID = string(row, 0)
                            guard UUID(uuidString: visibleID) != nil else { return }
                            if activeHistoryIDs[visibleID] == nil { activeHistoryIDs[visibleID] = id }
                            append(row)
                        }
                    }
                }
                try state.rows(base + " ORDER BY \(order) DESC,id DESC LIMIT 12", row: append)
                catalogAvailable = true
            } catch { chats.removeAll() }
        }
        if !catalogAvailable {
            chats = active.map { ChatActivity(id: $0.0, title: "本机任务", turn: nil) }
        }
        guard catalogAvailable || turnsAvailable else { throw ActivityError.database }
        if let history, turnsAvailable {
            do {
                for index in chats.indices {
                    let id = chats[index].id
                    var latest: Turn?
                    let historyID = activeHistoryIDs[id] ?? id
                    try history.rows("""
                        SELECT turn_id,status,started_at,completed_at FROM thread_turns
                        WHERE thread_id=? ORDER BY rollout_ordinal DESC LIMIT 1
                        """, bind: { sqlite3_bind_text($0, 1, historyID, -1, transient) }) { row in latest = turn(row, offset: 0) }
                    if latest?.status == .inProgress && (latest?.started ?? 0) < currentStart { latest = nil }
                    chats[index].turn = latest
                }
            } catch {
                turnsAvailable = false
                for index in chats.indices { chats[index].turn = nil }
            }
        }
        if let history, turnsAvailable {
            // Read only the tool identifier from tool events, never its arguments or output.
            var itemColumns = Set<String>()
            try? history.rows("PRAGMA table_info(thread_items)") { itemColumns.insert(string($0, 1)) }
            let toolField = itemColumns.contains("item_json") ? """
                CASE WHEN item_type IN ('mcpToolCall','dynamicToolCall') AND json_valid(item_json)
                THEN json_extract(item_json,'$.tool') END
                """ : "NULL"
            let activeFirst = itemColumns.contains("started_at_ms")
                ? "CASE WHEN completed_at_ms IS NULL AND started_at_ms IS NOT NULL THEN 0 ELSE 1 END," : ""
            let cutoff = Int64(Date().timeIntervalSince1970 * 1000) - 12_000
            for index in chats.indices where chats[index].turn?.status == .inProgress {
                guard let turn = chats[index].turn else { continue }
                let threadID = activeHistoryIDs[chats[index].id] ?? chats[index].id
                try? history.rows("""
                    SELECT item_type,coalesce(completed_at_ms,0),\(toolField) FROM thread_items
                    WHERE thread_id=? AND turn_id=? AND item_type NOT IN ('','userMessage')
                    ORDER BY \(activeFirst) updated_at_ordinal DESC LIMIT 1
                    """, bind: { row in
                    sqlite3_bind_text(row, 1, threadID, -1, transient)
                    sqlite3_bind_text(row, 2, turn.id, -1, transient)
                }) { row in
                    let ended = sqlite3_column_int64(row, 1)
                    if ended == 0 || ended >= cutoff {
                        chats[index].stage = WorkStage(kind: string(row, 0), finishedAt: ended, tool: string(row, 2))
                    }
                }
            }
        }
        chats.sort { ($0.turn?.status == .inProgress ? 0 : 1) < ($1.turn?.status == .inProgress ? 0 : 1) }
        return ActivitySnapshot(chats: chats, turnsAvailable: turnsAvailable, catalogAvailable: catalogAvailable)
    }
}
