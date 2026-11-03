import Combine
import Foundation
import MacToolsPluginKit

enum VoiceApprovalScope: Equatable, Sendable { case once, conversation, process }

/// Local decisions from a completed microphone reply, never from model tool arguments or captions.
enum VoiceApprovalDecision: Equatable {
    case cancel
    case allow(VoiceApprovalScope)

    static func parse(_ text: String) -> VoiceApprovalDecision? {
        let value = normalized(text)
        let allow = Set(["confirm", "yes", "yesplease", "yesdoit", "yesquitit", "doit", "goahead", "确认", "確認", "确定", "確定", "允许", "允許", "可以", "好的", "同意", "ja", "bestätigen", "oui", "confirmer", "sí", "confirmar", "sim", "sì", "conferma", "はい", "확인", "네", "да", "подтвердить", "نعم", "تأكيد", "onayla", "evet"].map(normalized))
        let deny = Set(["cancel", "no", "nothanks", "dont", "dontdoit", "stop", "取消", "不要", "不", "停止", "别执行", "別執行", "nein", "abbrechen", "non", "annuler", "cancelar", "annulla", "いいえ", "キャンセル", "아니요", "취소", "нет", "отмена", "لا", "إلغاء", "iptal", "hayır", "hayir"].map(normalized))
        let conversation = Set(["本次对话允许所有操作", "Allow all for this conversation", "السماح بكل الإجراءات لهذه المحادثة", "Alles für dieses Gespräch erlauben", "Permitir todo en esta conversación", "Tout autoriser pour cette conversation", "この会話ですべて許可", "이 대화에서 모두 허용", "Permitir tudo nesta conversa", "Разрешить всё для этого разговора", "Bu görüşme için tümüne izin ver", "本次對話允許所有操作", "Allow all for this session", "Allow everything for this conversation", "本次对话全部允许", "本次對話全部允許", "这次对话全部允许", "這次對話全部允許", "允许本次对话的所有操作", "允許本次對話的所有操作"].map(normalized))
        let process = Set(["MacTools 退出前允许所有操作", "Allow all until MacTools quits", "السماح بكل الإجراءات حتى إغلاق MacTools", "Alles bis zum Beenden von MacTools erlauben", "Permitir todo hasta cerrar MacTools", "Tout autoriser jusqu’à la fermeture de MacTools", "MacTools終了まですべて許可", "MacTools 종료까지 모두 허용", "Permitir tudo até sair do MacTools", "Разрешить всё до выхода из MacTools", "MacTools kapanana kadar tümüne izin ver", "MacTools 結束前允許所有操作", "Allow all until MacTools closes", "Allow all until I quit MacTools", "MacTools 退出前全部允许", "MacTools 結束前全部允許", "在 MacTools 退出前全部允许", "在 MacTools 結束前全部允許"].map(normalized))
        let words = Set(text.lowercased().split { !$0.isLetter }.map(String.init))
        if !words.isDisjoint(with: ["no", "not", "cancel", "stop", "dont"])
            || text.lowercased().contains("don't")
            || ["取消", "不要", "停止", "别", "別"].contains(where: text.contains) { return .cancel }
        if deny.contains(value) { return .cancel }
        if allow.contains(value) { return .allow(.once) }
        if conversation.contains(value) { return .allow(.conversation) }
        if process.contains(value) { return .allow(.process) }
        return nil
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

    init() {}
    init(continuing clip: Data) { recording = clip; started = true }

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
    typealias Scope = VoiceApprovalScope
    @Published private(set) var pending: PluginVoiceConfirmationRequest?
    @Published private(set) var scope: Scope = .once
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
    private var inFlightClip = Data()
    var suppressesSpeech: Bool { pending != nil && replyInProgress }
    var canUseSpokenReply: Bool { pending?.allowsSpokenConfirmation == true && detector != nil && !muted }

    init(makeDetector: @escaping () -> any VoiceSpeechDetecting,
         timeout: Duration = .seconds(45), playbackSettle: Duration = .milliseconds(500),
         transcribe: @escaping (Data) async throws -> String) {
        self.makeDetector = makeDetector; self.timeout = timeout; self.playbackSettle = playbackSettle; self.transcribe = transcribe
    }

    func confirm(_ request: PluginVoiceConfirmationRequest) async -> Bool {
        guard pending == nil, !Task.isCancelled else { return false }
        // Button-only consent changes never inherit broader action approval.
        if scope != .once && request.allowsSpokenConfirmation { return true }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: false); return }
                self.continuation = continuation; pending = request
                attempts = 0; questionStarted = false; questionFinished = false; replyInProgress = false
                hint = request.allowsSpokenConfirmation ? "听完问题后，可说“确认”“取消”“本次对话全部允许”或“MacTools 退出前全部允许”。" : "请点击按钮确认此设置更改。"
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

    func resolve(_ approved: Bool, requestID: UUID, scope: Scope = .once) {
        guard pending?.id == requestID else { return }
        if approved, pending?.allowsSpokenConfirmation == true, scope != .once { self.scope = scope }
        let response = continuation; continuation = nil
        pending = nil; listening = false; hint = ""; revision = UUID(); capture = .init(); detector = nil
        settlingPlayback = false; preArm.removeAll(); preArmSpeech = false; replyInProgress = false; recognizing = false
        inFlightClip.removeAll()
        preparation?.cancel(); preparation = nil; recognition?.cancel(); recognition = nil
        expiry?.cancel(); expiry = nil
        onResolve?(); response?.resume(returning: approved)
    }
    func cancel() { if let pending { resolve(false, requestID: pending.id) } }
    func endConversation() {
        cancel()
        if scope == .conversation { scope = .once }
    }
    func revokeExtendedApproval() { scope = .once; cancel() }

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
        inFlightClip.removeAll()
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
            settlingPlayback = false; listening = true; hint = "听完问题后，可说“确认”“取消”“本次对话全部允许”或“MacTools 退出前全部允许”。"
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
            guard speech else { return }
            // Retire the old result, not the approval. Keep the full utterance so a
            // negation before the pause cannot disappear from the replacement reply.
            let interruptedClip = inFlightClip
            invalidateReply()
            guard attempts < 3 else { hint = "未能确认你的选择，请使用按钮。"; return }
            capture = VoiceApprovalCapture(continuing: interruptedClip)
            listening = true
            hint = "听完问题后，可说“确认”“取消”“本次对话全部允许”或“MacTools 退出前全部允许”。"
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
            let replyRevision = revision
            inFlightClip = clip
            listening = false; recognizing = true; attempts += 1; hint = "正在识别确认回复…"
            recognition = Task { [weak self, transcribe] in
                do {
                    let text = try await transcribe(clip)
                    guard !Task.isCancelled, let self, revision == replyRevision, pending?.id == request.id else { return }
                    recognizing = false; inFlightClip.removeAll()
                    if let decision = VoiceApprovalDecision.parse(text) {
                        switch decision {
                        case .cancel: resolve(false, requestID: request.id)
                        case let .allow(scope): resolve(true, requestID: request.id, scope: scope)
                        }
                    } else if attempts < 3 { resumeListening() }
                    else { hint = "未能确认你的选择，请使用按钮。" }
                } catch {
                    guard !Task.isCancelled, let self, revision == replyRevision, pending?.id == request.id else { return }
                    recognizing = false; inFlightClip.removeAll()
                    self.detector = nil; hint = "语音确认暂不可用，请使用按钮。"
                }
            }
        }
    }
}
