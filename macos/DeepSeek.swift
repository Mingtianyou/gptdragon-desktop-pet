import AppKit
import Foundation
import Security
import CryptoKit

// Secrets stay in the user's login keychain, never in preferences or process args.
enum DeepSeekKeychain {
    private static let service = "local.codex.gptdragon.deepseek"
    private static let account = "api-key"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    static func load() throws -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return key
    }
    static func save(_ value: String) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count <= 512, key.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let data = key.data(using: .utf8) else { throw DeepSeekError.invalidKey }
        let changes = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(added)) }
        } else if status != errSecSuccess { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}

enum PetPersona {
    static let key = "deepSeekPersonaV1"
    static var defaultText: String {
        guard let url = Bundle.main.url(forResource: "Persona", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else {
            return "你是用户桌面上的 GPT 娘，温柔自然地简短闲聊；不假装能查看桌面或执行任务。"
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static var current: String {
        let text = UserDefaults.standard.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? defaultText : text
    }
}

enum DeepSeekError: Error {
    case invalidKey, missingKey, http(Int), malformed, interrupted, tooLong
    var display: String {
        switch self {
        case .invalidKey: return "API Key 格式不正确"
        case .missingKey: return "请先在右键菜单绑定 DeepSeek API Key"
        case .http(401), .http(403): return "DeepSeek API Key 无效或无权限"
        case .http(402): return "DeepSeek 余额不足"
        case .http(429): return "DeepSeek 请求较多，请稍后再试"
        case .http: return "DeepSeek 服务暂时不可用"
        case .malformed: return "DeepSeek 返回的数据无法识别"
        case .interrupted: return "回复中断，输入已保留"
        case .tooLong: return "回复过长，输入已保留"
        }
    }
}

struct DeepSeekBalance: Codable {
    struct Amount: Codable { let currency: String; let total: String }
    let amounts: [Amount]
    let available: Bool
    let observedAt: Date
    let keyID: String
    var summary: String {
        amounts.map { item in
            let prefix = item.currency == "CNY" ? "¥" : item.currency == "USD" ? "$" : item.currency + " "
            return prefix + item.total
        }.joined(separator: " / ")
    }
    var symbol: String {
        guard amounts.count == 1 else { return "余额" }
        return amounts[0].currency == "CNY" ? "¥" : amounts[0].currency == "USD" ? "$" : "余额"
    }
    static func identifier(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
    static func parse(_ data: Data, keyID: String, now: Date = Date()) throws -> DeepSeekBalance {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let available = json["is_available"] as? Bool,
              let raw = json["balance_infos"] as? [[String: Any]], !raw.isEmpty, raw.count <= 4 else { throw DeepSeekError.malformed }
        let amounts = raw.compactMap { item -> Amount? in
            guard let currency = item["currency"] as? String, ["CNY", "USD"].contains(currency),
                  let total = item["total_balance"] as? String, total.count <= 24,
                  let number = Decimal(string: total, locale: Locale(identifier: "en_US_POSIX")), number >= 0 else { return nil }
            return Amount(currency: currency, total: total)
        }
        guard amounts.count == raw.count else { throw DeepSeekError.malformed }
        return DeepSeekBalance(amounts: amounts, available: available, observedAt: now, keyID: keyID)
    }
}

private final class DeepSeekNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

final class DeepSeekBalanceStore {
    private let defaults: UserDefaults?
    private let keyLoader: () throws -> String?
    private var session: URLSession?
    private let endpoint: URL
    private let cacheKey = "deepSeekBalanceSnapshotV1"
    private var task: URLSessionDataTask?
    private var token = UUID()
    private(set) var snapshot: DeepSeekBalance?
    private(set) var refreshing = false
    private(set) var error: String?
    private(set) var restored = false
    var didChange: (() -> Void)?
    init(defaults: UserDefaults? = .standard, keyLoader: @escaping () throws -> String? = DeepSeekKeychain.load,
         session: URLSession? = nil,
         endpoint: URL = URL(string: "https://api.deepseek.com/user/balance")!) {
        self.defaults=defaults; self.keyLoader=keyLoader; self.session=session; self.endpoint=endpoint
    }
    func clear() {
        token=UUID(); task?.cancel(); task=nil; refreshing=false; snapshot=nil; restored=false; error=nil
        defaults?.removeObject(forKey: cacheKey); didChange?()
    }
    func refresh() {
        guard !refreshing else { return }
        let key: String
        do {
            guard let value = try keyLoader(), !value.isEmpty else {
                snapshot=nil; restored=false; error=DeepSeekError.missingKey.display; didChange?(); return
            }
            key=value
        } catch { self.error="无法读取钥匙串中的 API Key"; didChange?(); return }
        let id=DeepSeekBalance.identifier(key)
        if snapshot?.keyID != id {
            snapshot=nil; restored=false
            if let data=defaults?.data(forKey:cacheKey), let saved=try? JSONDecoder().decode(DeepSeekBalance.self,from:data),
               saved.keyID==id, saved.observedAt<=Date(), !saved.amounts.isEmpty { snapshot=saved;restored=true }
        }
        refreshing=true;error=nil;didChange?()
        let requestID=UUID();token=requestID
        var request=URLRequest(url:endpoint,cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:15)
        request.setValue("Bearer " + key,forHTTPHeaderField:"Authorization")
        request.setValue("application/json",forHTTPHeaderField:"Accept")
        if session == nil {
            let config=URLSessionConfiguration.ephemeral;config.urlCache=nil;config.httpCookieStorage=nil
            config.httpShouldSetCookies=false
            session=URLSession(configuration:config,delegate:DeepSeekNoRedirect(),delegateQueue:nil)
        }
        task=session?.dataTask(with:request){ [weak self] data,response,networkError in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.token==requestID else { return }
                self.task=nil; self.refreshing=false
                if let http=response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    self.error=DeepSeekError.http(http.statusCode).display
                } else if networkError != nil { self.error="余额更新失败，请检查网络" }
                else if let data, data.count <= 65_536, let result=try? DeepSeekBalance.parse(data,keyID:id) {
                    self.snapshot=result; self.restored=false; self.error=nil
                    if let encoded=try? JSONEncoder().encode(result) { self.defaults?.set(encoded,forKey:self.cacheKey) }
                } else { self.error=DeepSeekError.malformed.display }
                self.didChange?()
            }
        };task?.resume()
    }
    deinit { task?.cancel();session?.invalidateAndCancel() }
}

// One short-lived ephemeral session per sent message. Reasoning is never shown
// or persisted, and the request contains only the persona and chat messages.
final class DeepSeekChatStream: NSObject, URLSessionDataDelegate {
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buffer=Data()
    private var text=""
    private var httpStatus=0
    private var sawDone=false
    private var failed: DeepSeekError?
    private var lastPartial: TimeInterval=0
    var onPartial: ((String)->Void)?
    var onComplete: ((Result<String,DeepSeekError>)->Void)?
    private let endpoint: URL
    private let configuration: URLSessionConfiguration
    init(endpoint: URL = URL(string:"https://api.deepseek.com/chat/completions")!,
         configuration: URLSessionConfiguration = .ephemeral) {
        self.endpoint=endpoint; self.configuration=configuration; super.init()
    }
    func start(key: String, persona: String, messages: [(String,String)]) throws {
        let body: [String:Any] = ["model":"deepseek-flash", "thinking":["type":"enabled"],
                                  "reasoning_effort":"low", "stream":true, "max_tokens":1024,
                                  "messages": [["role":"system","content":persona]] + messages.map { ["role":$0.0,"content":$0.1] }]
        var request=URLRequest(url:endpoint,cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:90)
        request.httpMethod="POST";request.setValue("Bearer " + key,forHTTPHeaderField:"Authorization")
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.httpBody=try JSONSerialization.data(withJSONObject:body)
        configuration.urlCache=nil;configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage=nil;configuration.httpShouldSetCookies=false
        let queue=OperationQueue();queue.maxConcurrentOperationCount=1;queue.qualityOfService = .utility
        session=URLSession(configuration:configuration,delegate:self,delegateQueue:queue)
        task=session?.dataTask(with:request);task?.resume()
    }
    func cancel() { task?.cancel();session?.invalidateAndCancel();task=nil;session=nil;onPartial=nil;onComplete=nil }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session:URLSession, dataTask:URLSessionDataTask, didReceive response:URLResponse,
                    completionHandler:@escaping (URLSession.ResponseDisposition)->Void) {
        httpStatus=(response as? HTTPURLResponse)?.statusCode ?? 0;completionHandler(.allow)
    }
    func urlSession(_ session:URLSession, dataTask:URLSessionDataTask, didReceive data:Data) {
        guard (200..<300).contains(httpStatus), failed == nil else { return }
        buffer.append(data)
        if buffer.count > 1_048_576 || text.utf8.count > 262_144 { failed = .tooLong; task?.cancel(); return }
        while let newline=buffer.firstIndex(of:10) {
            let line=Data(buffer[..<newline]);buffer.removeSubrange(...newline);consume(line)
        }
    }
    private func consume(_ data:Data) {
        guard let line=String(data:data,encoding:.utf8)?.trimmingCharacters(in:.whitespacesAndNewlines), line.hasPrefix("data:") else { return }
        let content=line.dropFirst(5).trimmingCharacters(in:.whitespaces)
        if content == "[DONE]" { sawDone=true;return }
        guard let json=content.data(using:.utf8), let object=(try? JSONSerialization.jsonObject(with:json)) as? [String:Any] else { return }
        if object["error"] != nil { failed = .malformed;return }
        guard let choices=object["choices"] as? [[String:Any]], let first=choices.first,
              let delta=first["delta"] as? [String:Any], let chunk=delta["content"] as? String else { return }
        text += chunk
        let now=ProcessInfo.processInfo.systemUptime
        if now-lastPartial >= 0.06 { lastPartial=now;let snapshot=text;DispatchQueue.main.async { [weak self] in self?.onPartial?(snapshot) } }
    }
    func urlSession(_ session:URLSession, task:URLSessionTask, didCompleteWithError error:Error?) {
        if !buffer.isEmpty { consume(buffer);buffer.removeAll() }
        let result: Result<String,DeepSeekError>
        if let failed { result = .failure(failed) }
        else if !(200..<300).contains(httpStatus), httpStatus != 0 { result = .failure(.http(httpStatus)) }
        else if error != nil || !sawDone { result = .failure(.interrupted) }
        else if text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { result = .failure(.malformed) }
        else { result = .success(text) }
        self.task=nil;self.session=nil;session.finishTasksAndInvalidate()
        DispatchQueue.main.async { [weak self] in self?.onComplete?(result) }
    }
}
