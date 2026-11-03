import Combine
import Foundation
import MacToolsPluginKit

/// Local decisions from a completed microphone reply, never from model tool arguments or captions.
enum VoiceApprovalDecision {
    static func parse(_ text: String) -> Bool? {
        let value = normalized(text)
        let allow = Set(["confirm", "yes", "yesplease", "yesdoit", "yesquitit", "doit", "goahead", "确认", "確認", "确定", "確定", "允许", "允許", "可以", "好的", "同意", "ja", "bestätigen", "oui", "confirmer", "sí", "confirmar", "sim", "sì", "conferma", "はい", "확인", "네", "да", "подтвердить", "نعم", "تأكيد", "onayla", "evet"].map(normalized))
        let deny = Set(["cancel", "no", "nothanks", "dont", "dontdoit", "stop", "取消", "不要", "不", "停止", "别执行", "別執行", "nein", "abbrechen", "non", "annuler", "cancelar", "annulla", "いいえ", "キャンセル", "아니요", "취소", "нет", "отмена", "لا", "إلغاء", "iptal", "hayır", "hayir"].map(normalized))
        let words = Set(text.lowercased().split { !$0.isLetter }.map(String.init))
        if !words.isDisjoint(with: ["no", "not", "cancel", "stop", "dont"])
            || text.lowercased().contains("don't")
            || ["取消", "不要", "停止", "别", "別"].contains(where: text.contains) { return false }
        if deny.contains(value) { return false }
        return allow.contains(value) ? true : nil
    }
    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter {
                !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0)
            }.map(String.init).joined()
    }
}

/// PCM is retained only while one approval is pending; silence alone cannot create a request.
struct VoiceApprovalCapture {
    private var preRoll = Data()
    private var recording = Data()
    private var quietBytes = 0
    private var started = false
    enum Result { case waiting, completed(Data), tooLong }

    mutating func append(_ pcm: Data, speech: Bool) -> Result {
        if !started {
            guard speech else {
                preRoll.append(pcm)
                if preRoll.count > 12_000 { preRoll.removeFirst(preRoll.count - 12_000) }
                return .waiting
            }
            recording = preRoll; recording.append(pcm); preRoll.removeAll(); started = true
        } else { recording.append(pcm) }
        quietBytes = speech ? 0 : quietBytes + pcm.count
        // Never transcribe a truncated reply: a later negation must not be dropped.
        if recording.count > 288_000 { self = .init(); return .tooLong }
        guard quietBytes >= 28_800 else { return .waiting } // 600 ms at 24 kHz, mono Int16.
        let clip = recording; self = .init(); return .completed(clip)
    }
}

@MainActor
final class VoiceApprovals: ObservableObject {
    @Published private(set) var pending: PluginVoiceConfirmationRequest?
    @Published private(set) var listening = false
    @Published private(set) var hint = ""
    var onPresent: ((PluginVoiceConfirmationRequest) -> Void)?
    var onResolve: (() -> Void)?
    private let makeDetector: () -> any VoiceSpeechDetecting
    private let transcribe: (Data) async throws -> String
    private let timeout: Duration
    private let playbackSettle: Duration
    private var continuation: CheckedContinuation<Bool, Never>?
    private var preparation: Task<Void, Never>?
    private var recognition: Task<Void, Never>?
    private var expiry: Task<Void, Never>?
    private var detector: (any VoiceSpeechDetecting)?
    private var capture = VoiceApprovalCapture()
    private var revision = UUID()
    private var questionStarted = false
    private var questionFinished = false
    private var playing = false
    private var muted = false
    private var attempts = 0
    private var replyInProgress = false
    private var settlingPlayback = false
    private var preArm = Data()
    private var preArmSpeech = false
    private var recognizing = false
    var suppressesSpeech: Bool { pending != nil && replyInProgress }
    var canUseSpokenReply: Bool { pending?.allowsSpokenConfirmation == true && detector != nil && !muted }

    init(makeDetector: @escaping () -> any VoiceSpeechDetecting,
         timeout: Duration = .seconds(45), playbackSettle: Duration = .milliseconds(500),
         transcribe: @escaping (Data) async throws -> String) {
        self.makeDetector = makeDetector; self.timeout = timeout; self.playbackSettle = playbackSettle; self.transcribe = transcribe
    }

    func confirm(_ request: PluginVoiceConfirmationRequest) async -> Bool {
        guard pending == nil, !Task.isCancelled else { return false }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: false); return }
                self.continuation = continuation; pending = request
                attempts = 0; questionStarted = false; questionFinished = false; replyInProgress = false
                hint = request.allowsSpokenConfirmation ? "请听完问题后说“确认”或“取消”，也可以点击按钮。" : "请点击按钮确认此设置更改。"
                if muted && request.allowsSpokenConfirmation { hint = "麦克风已静音，请使用按钮。" }
                expiry = Task { [weak self, timeout] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    self?.resolve(false, requestID: request.id)
                }
                preparation = Task { [weak self] in
                    guard let self else { return }
                    if request.allowsSpokenConfirmation {
                        let candidate = makeDetector()
                        do { try await candidate.prepare() }
                        catch {
                            guard pending?.id == request.id else { return }
                            hint = "语音确认暂不可用，请使用按钮。"
                            onPresent?(request); return
                        }
                        guard !Task.isCancelled, pending?.id == request.id else { return }
                        detector = candidate
                    }
                    onPresent?(request)
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.resolve(false, requestID: request.id) } }
    }

    func resolve(_ approved: Bool, requestID: UUID) {
        guard pending?.id == requestID else { return }
        let response = continuation; continuation = nil
        pending = nil; listening = false; hint = ""; revision = UUID(); capture = .init(); detector = nil
        settlingPlayback = false; preArm.removeAll(); preArmSpeech = false; replyInProgress = false; recognizing = false
        preparation?.cancel(); preparation = nil; recognition?.cancel(); recognition = nil
        expiry?.cancel(); expiry = nil
        onResolve?(); response?.resume(returning: approved)
    }
    func cancel() { if let pending { resolve(false, requestID: pending.id) } }

    func playbackChanged(_ playing: Bool) {
        guard self.playing != playing else { return }
        self.playing = playing
        guard pending != nil else { return }
        if playing { questionStarted = true; questionFinished = false; invalidateReply() }
        else if questionStarted { questionFinished = true; resumeListening() }
    }
    func setMuted(_ muted: Bool) {
        self.muted = muted
        guard pending != nil else { return }
        invalidateReply()
        if muted { hint = "麦克风已静音，请使用按钮。" }
        else { resumeListening() }
    }
    private func invalidateReply() {
        listening = false; revision = UUID(); capture = .init(); replyInProgress = false
        settlingPlayback = false; preArm.removeAll(); preArmSpeech = false
        recognizing = false
        recognition?.cancel(); recognition = nil
    }
    private func resumeListening() {
        guard let request = pending, request.allowsSpokenConfirmation, questionFinished,
              !playing, !muted, let detector, attempts < 3 else { return }
        let token = revision
        settlingPlayback = true
        recognition = Task { [weak self] in
            await detector.reset()
            guard !Task.isCancelled, let self else { return }
            // Streaming output can briefly drain between packets. Retain a quick reply during this gap.
            try? await Task.sleep(for: playbackSettle)
            guard !Task.isCancelled, revision == token, pending?.id == request.id else { return }
            settlingPlayback = false; listening = true; hint = "正在等待“确认”或“取消”…"
        }
    }

    func receiveAudio(_ pcm: Data) async {
        guard (listening || settlingPlayback || recognizing), !muted, !playing, let request = pending, let detector else { return }
        let token = revision
        let speech: Bool
        do { speech = try await detector.detectsSpeech(in: pcm) }
        catch {
            guard revision == token, pending?.id == request.id else { return }
            invalidateReply(); self.detector = nil; hint = "语音确认暂不可用，请使用按钮。"; return
        }
        guard revision == token, (listening || settlingPlayback || recognizing), pending?.id == request.id else { return }
        if recognizing {
            // A correction while recognition is in flight must retire the older positive answer.
            if speech { resolve(false, requestID: request.id) }
            return
        }
        if speech { replyInProgress = true }
        if settlingPlayback {
            preArm.append(pcm); preArmSpeech = preArmSpeech || speech
            if preArm.count > 48_000 { invalidateReply(); hint = "语音确认暂不可用，请使用按钮。" }
            return
        }
        var input = preArm; input.append(pcm)
        let hasSpeech = speech || preArmSpeech
        preArm.removeAll(); preArmSpeech = false
        switch capture.append(input, speech: hasSpeech) {
        case .waiting: return
        case .tooLong:
            listening = false; hint = "回复过长，请使用按钮确认。"
        case let .completed(clip):
            listening = false; recognizing = true; attempts += 1; hint = "正在识别确认回复…"
            recognition = Task { [weak self, transcribe] in
                do {
                    let text = try await transcribe(clip)
                    guard !Task.isCancelled, let self, revision == token, pending?.id == request.id else { return }
                    recognizing = false
                    if let approved = VoiceApprovalDecision.parse(text) { resolve(approved, requestID: request.id) }
                    else if attempts < 3 { resumeListening() }
                    else { hint = "未能确认你的选择，请使用按钮。" }
                } catch {
                    guard !Task.isCancelled, let self, revision == token, pending?.id == request.id else { return }
                    recognizing = false
                    self.detector = nil; hint = "语音确认暂不可用，请使用按钮。"
                }
            }
        }
    }
}
