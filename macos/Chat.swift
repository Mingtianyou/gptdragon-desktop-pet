import AppKit

// The shared composer and head bubble remain owned by AppDelegate. This class
// only handles a bounded, in-memory casual conversation through DeepSeek.
final class PetChat {
    var onReply: ((String) -> Void)?
    var onPartial: ((String) -> Void)?
    var onState: ((String, Bool) -> Void)?
    var onSuccess: (() -> Void)?
    private(set) var isBusy = false
    private var messages: [(String,String)] = []
    private var stream: DeepSeekChatStream?
    private var token = UUID()
    private let keyLoader: () throws -> String?
    private let personaLoader: () -> String
    private let streamFactory: () -> DeepSeekChatStream

    init(keyLoader: @escaping () throws -> String? = DeepSeekKeychain.load,
         personaLoader: @escaping () -> String = { PetPersona.current },
         streamFactory: @escaping () -> DeepSeekChatStream = { DeepSeekChatStream() }) {
        self.keyLoader=keyLoader;self.personaLoader=personaLoader;self.streamFactory=streamFactory
    }

    // Merely opening the composer never starts a model or consumes API credit.
    @discardableResult func prewarm() -> Bool { true }
    func releaseIfIdle() {}

    @discardableResult func sendMessage(_ input: String) -> Bool {
        guard !isBusy else { return false }
        let text=input.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 8000 else { return false }
        let key: String
        do {
            guard let saved=try keyLoader(), !saved.isEmpty else {
                onState?(DeepSeekError.missingKey.display,false);return false
            }
            key=saved
        } catch { onState?("无法读取钥匙串中的 API Key",false);return false }
        let request=streamFactory();stream=request
        let id=UUID();token=id;isBusy=true;onState?("正在回复…",true)
        request.onPartial = { [weak self] text in
            guard let self, self.token==id, self.isBusy else { return }
            self.onPartial?(text)
        }
        request.onComplete = { [weak self] result in
            guard let self, self.token==id, self.isBusy else { return }
            self.stream=nil;self.isBusy=false;self.token=UUID()
            switch result {
            case .success(let result):
                let reply=result.trimmingCharacters(in:.whitespacesAndNewlines)
                self.messages.append(("user",text));self.messages.append(("assistant",reply))
                if self.messages.count > 16 { self.messages.removeFirst(self.messages.count-16) }
                self.onState?("",false);self.onReply?(reply);self.onSuccess?()
            case .failure(let error): self.onState?(error.display + "，输入已保留",false)
            }
        }
        do { try request.start(key:key,persona:personaLoader(),messages:messages + [("user",text)]) }
        catch { stream=nil;isBusy=false;token=UUID();onState?("闲聊启动失败，输入已保留",false);return false }
        return true
    }
    func cancel() {
        guard isBusy else { return }
        token=UUID();isBusy=false;stream?.cancel();stream=nil;onState?("已停止",false)
    }
    deinit { stream?.cancel() }
}
