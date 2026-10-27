import AppKit
import Combine

/// What Ask Boltty listens with: dictation, as a thing that hears until it is told
/// to finish and then hands back the final words.
@MainActor
protocol AskBolttyListening: AnyObject {
  var onText: ((String) -> Void)? { get set }
  var onFailure: ((String) -> Void)? { get set }
  func start()
  /// Stops listening and waits for the engine's final words.
  func finish() async -> String
  func cancel()
}

/// What Ask Boltty speaks with. `onStart` runs as the voice begins the piece.
@MainActor
protocol AskBolttySpeaking: AnyObject {
  /// Whether text in `language` is said at all (`SpeechLanguages`).
  func canSpeak(_ language: String?) -> Bool
  func say(_ piece: String, id: String, language: String?, onStart: (() -> Void)?)
  func isSaying(_ id: String) -> Bool
  func stop()
}

extension SpeechOutput: AskBolttySpeaking {}

/// One Ask Boltty, from the chord being held to the answer's last word: the screen
/// is frozen and the agent's session started while the person speaks, their
/// words go with a picture of the screen when they let go, and the answer is
/// said a sentence at a time as it arrives.
@MainActor
final class AskBolttySession: ObservableObject {
  enum Phase: Equatable {
    case idle
    case listening
    case thinking
    case speaking
    case needsYou(String)
    case failed(String)
  }

  @Published private(set) var phase: Phase = .idle
  /// What the person has said so far.
  @Published private(set) var heard = ""
  /// The sentence the voice was last handed.
  @Published private(set) var caption = ""
  /// The answer's agent, for the face that shows it.
  @Published private(set) var providerID: String?
  @Published private(set) var conversationID: UUID?
  /// Where the answer is pointing now, as the sentence that names it is said.
  @Published private(set) var pointing: AskBolttyPointing?
  /// What the answers have drawn so far, in order: up until the next question.
  @Published private(set) var drawn: [AskBolttyStroke] = []
  /// Whether this answer is said, or only shown: Boltty speaks Siri's
  /// languages and no others. Shown, `reader` paces it as a voice would.
  @Published private(set) var readsAloud = true
  /// The voice for an answer that is only shown: each sentence stays for as
  /// long as it takes to read.
  let reader = AskBolttyReader()
  /// Off: the answer types out beside the face, which "speaks" in blips;
  /// the Mac's voices sound poor. The voice path
  /// stays, behind this, for when a good one is chosen.
  var speaksAloud = false
  /// The caption is the sentence being said: a new one takes the last one's
  /// place.
  static let captionSentences = 1
  /// An answer is said up to this many sentences; the rest stays in the chat.
  static let answerSentences = 2

  /// The line the pointer traced while the chord was held, in AppKit's
  /// global coordinates; sent drawn on the screen's picture.
  private(set) var trail: [CGPoint] = []
  /// A trace shorter than this is a hand at rest, not a line.
  static let minimumTrailLength: CGFloat = 24
  static let trailStep: CGFloat = 3

  /// A question asked within this of the last answer continues that chat,
  /// so a run of questions shares what was said; past it the chat is let go.
  static let followUpWindow: TimeInterval = 600
  /// How long the final words may take once the chord is let go.
  static let finalWordsDeadline: TimeInterval = 3

  private let coordinator: ChatWorkspaceCoordinator
  private let listener: AskBolttyListening
  private let speech: AskBolttySpeaking
  private let target: () -> AskBolttyTarget?
  var pointer: () -> CGPoint = { NSEvent.mouseLocation }
  var freeze: (CGPoint) async throws -> FrozenScreen? = { point in
    guard ScreenRegionCapture.ensureAccess() else { throw ScreenRegionCapture.Failure.notAllowed }
    let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
    guard let id = screen?.displayID else { return nil }
    return try await ScreenRegionCapture.freeze(displayID: id)
  }
  var pictureDirectory: URL = PromptAttachmentStore.shared.directory
  var now: () -> Date = Date.init

  private var freezeTask: Task<FrozenScreen?, Error>?
  private var heldAt: CGPoint?
  private var releasedAt: CGPoint?
  /// Where the picture was taken, in AppKit's coordinates: what a point's
  /// 0–1000 is measured across.
  private var answerFrame: CGRect?
  private var marks: [AskBolttyMark] = []
  private var isNewConversation = false
  private var lastAnsweredAt: Date?
  private var baseline = 0
  private var turnBegan = false
  private var spokenText = ""
  private var chunker = SentenceChunker()
  private var sentencesSaid = 0
  private var language: String?
  private var captioned: [String] = []
  /// Decided once an answer's first piece is in: one answer is never half
  /// said and half shown.
  private var decidedVoice = false
  private var sendTask: Task<Void, Never>?
  private var storeWatch: AnyCancellable?
  /// Lets the chat go once the follow-up window has passed with no question.
  private var expiry: Timer?

  init(
    coordinator: ChatWorkspaceCoordinator,
    listener: AskBolttyListening,
    speech: AskBolttySpeaking,
    target: @escaping () -> AskBolttyTarget?
  ) {
    self.coordinator = coordinator
    self.listener = listener
    self.speech = speech
    self.target = target
    listener.onText = { [weak self] text in self?.heard = text }
    reader.onIdle = { [weak self] in self?.speechFinished() }
    listener.onFailure = { [weak self] message in self?.fail(message) }
  }

  var speechID: String? { conversationID.map { "talk-\($0.uuidString)" } }

  // MARK: - The chord

  /// The chord has been held long enough: freeze the screen, start the
  /// agent, listen.
  func begin() {
    interruptAnswer()
    stopTurn()
    guard let target = target() else {
      return fail("No agent that can see the screen is ready. Turn one on in Settings › Agents.")
    }
    let point = pointer()
    heldAt = point
    releasedAt = nil
    trail = [point]
    pointing = nil
    drawn = []
    freezeTask = Task { [freeze] in try await freeze(point) }
    choosePlace(for: target)
    heard = ""
    caption = ""
    readsAloud = true
    phase = .listening
    listener.start()
  }

  /// The pointer moved while the chord is held.
  func trace(_ point: CGPoint) {
    guard phase == .listening else { return }
    if let last = trail.last, hypot(point.x - last.x, point.y - last.y) < Self.trailStep { return }
    trail.append(point)
  }

  /// Whether the trail is long enough to be a line the person drew.
  var hasTrail: Bool {
    var length: CGFloat = 0
    for (a, b) in zip(trail, trail.dropFirst()) {
      length += hypot(b.x - a.x, b.y - a.y)
      if length >= Self.minimumTrailLength { return true }
    }
    return false
  }

  /// The chord was let go: send what was said.
  func end() {
    guard phase == .listening else { return }
    releasedAt = pointer()
    phase = .thinking
    sendTask = Task { [weak self] in await self?.send() }
  }

  /// Escape while it thinks or answers: the agent's turn is stopped, the
  /// words and the face go. Drawings already up stay for their own Escape.
  func stop() {
    switch phase {
    case .thinking, .speaking, .needsYou:
      interruptAnswer()
      stopTurn()
      phase = .idle
    case .idle, .listening, .failed:
      return
    }
  }

  /// Stops the agent's turn in Ask Boltty's chat, if one is running: a new
  /// question or an Escape is not a reason for it to go on spending.
  private func stopTurn() {
    guard let id = conversationID,
          coordinator.store.conversation(id: id)?.lastKnownState.blocksSending == true
    else { return }
    let engine = coordinator.engine
    Task { await engine.stop(conversationID: id) }
  }

  /// A key or a click while the chord was held: nothing is sent.
  func cancel() {
    listener.cancel()
    freezeTask?.cancel()
    freezeTask = nil
    sendTask?.cancel()
    if phase == .listening || phase == .thinking { discardIfNew() }
    trail = []
    pointing = nil
    phase = .idle
  }

  // MARK: - Sending

  private func choosePlace(for target: AskBolttyTarget) {
    if let id = conversationID,
       let conversation = coordinator.store.conversation(id: id),
       conversation.providerID == target.providerID,
       conversation.readOnly == target.readOnly,
       !conversation.lastKnownState.blocksSending,
       let last = lastAnsweredAt, now().timeIntervalSince(last) < Self.followUpWindow {
      isNewConversation = false
      providerID = conversation.providerID
      return
    }
    // Ask Boltty keeps no history past the window: the chats before this one are done with.
    coordinator.forgetAskBolttyChats()
    let conversation = coordinator.prepareAskBolttyConversation(
      providerID: target.providerID, model: target.model, effort: target.effort,
      readOnly: target.readOnly)
    conversationID = conversation.id
    providerID = conversation.providerID
    isNewConversation = true
  }

  private func send() async {
    let words = await finalWords()
    guard !Task.isCancelled, phase == .thinking, let id = conversationID else { return }
    guard !words.isEmpty else {
      discardIfNew()
      phase = .idle
      return
    }
    heard = words
    let frozen = try? await freezeTask?.value
    guard !Task.isCancelled, phase == .thinking else { return }
    let primaryHeight = NSScreen.screens.first?.frame.height ?? frozen?.displayFrame.height ?? 0
    let traced = hasTrail
    // Scaling a 5K screen and writing its PNG is tens of milliseconds: off the
    // main thread, so the face and the line do not stall as the chord is let go.
    let made: (shot: (png: Data, size: CGSize, context: String?), url: URL)?
    if let frozen {
      let pointer = releasedAt ?? heldAt
      let line = traced ? trail : []
      let directory = pictureDirectory
      made = await Task.detached(priority: .userInitiated) {
        guard let shot = ScreenRegionCapture.wholeScreen(
          frozen, pointer: pointer, trail: line, primaryScreenHeight: primaryHeight),
          let url = Self.writePicture(shot.png, in: directory)
        else { return nil }
        return (shot, url)
      }.value
    } else {
      made = nil
    }
    guard !Task.isCancelled, phase == .thinking else { return }
    guard let frozen, let made else {
      return fail(CGPreflightScreenCaptureAccess()
        ? "Boltty could not take a picture of the screen."
        : AgentPaletteController.screenRecordingNeeded)
    }
    let (shot, url) = made
    let readOnly = coordinator.store.conversation(id: id)?.readOnly ?? true
    let bracket = AskBolttyPrompt.bracket(
      context: shot.context, screenshotPath: url.path, readOnly: readOnly, traced: traced)
    let picture = ConversationAttachment(
      id: "talk-\(url.lastPathComponent)", displayName: "Screen", url: url,
      mimeType: "image/png", byteCount: shot.png.count)
    // The card shows the question and the screen's picture, not the bracket.
    coordinator.store.recordSentFiles(
      [SentFile(path: url.path, label: "", name: "Screen.png", expansion: bracket)], for: id)
    if isNewConversation {
      coordinator.store.rename(id: id, to: ConversationEngine.title(from: words))
    }
    answerFrame = frozen.displayFrameInAppKit(primaryScreenHeight: primaryHeight)
    marks = []
    captioned = []
    language = SpeechOutput.language(of: words)
    decidedVoice = false
    baseline = coordinator.store.transcript(id: id).messages.count
    spokenText = ""
    turnBegan = false
    chunker = SentenceChunker()
    sentencesSaid = 0
    guard coordinator.sendFollowUp(bracket + words, pictures: [picture], to: id) else {
      return fail("That question was not sent.")
    }
    isNewConversation = false
    watch(id)
  }

  private func finalWords() async -> String {
    let words = await listener.finish()
    return words.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  nonisolated private static func writePicture(_ data: Data, in directory: URL) -> URL? {
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let url = directory.appendingPathComponent("talk-\(UUID().uuidString.prefix(8)).png")
      try data.write(to: url, options: .atomic)
      return url
    } catch {
      return nil
    }
  }

  // MARK: - The answer

  private func watch(_ id: UUID) {
    storeWatch = coordinator.store.objectWillChange
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in self?.follow(id) }
    follow(id)
  }

  /// Feeds what the answer added since last time, sentence by sentence, and
  /// settles once the turn is over and its last word has been said.
  func follow(_ id: UUID) {
    guard id == conversationID, let speechID else { return }
    guard let conversation = coordinator.store.conversation(id: id) else { return finish() }
    // The parts as written: what the card shows has the point tags taken out.
    let answer = coordinator.store.transcript(id: id).messages.dropFirst(baseline)
      .filter { $0.role == .agent }
      .map { message in
        message.parts.compactMap { part -> String? in
          if case let .text(text) = part { return text.text }
          return nil
        }
        .joined(separator: "\n\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      }
      .filter { !$0.isEmpty }
      .joined(separator: "\n\n")
    marks = AskBolttyMark.all(in: answer)
    let spoken = SpokenText.speakable(answer, keepingPoints: true)
    if spoken.hasPrefix(spokenText), spoken.count > spokenText.count {
      feed(String(spoken.dropFirst(spokenText.count)), id: speechID)
      spokenText = spoken
    }

    // The send is on its way until the coordinator lets go of it; the turn
    // has not begun until the agent says it is working (or has spoken).
    if coordinator.failedPanelPrompts[id] != nil {
      return fail("\(name(of: conversation)) did not get that question.")
    }
    if coordinator.pendingPanelPrompts[id] != nil { return }
    if conversation.lastKnownState == .working || !spokenText.isEmpty { turnBegan = true }
    guard turnBegan else { return }

    switch conversation.lastKnownState {
    case .working:
      return
    case .waiting where conversation.readOnly:
      // The engine refuses a read-only chat's every ask itself: nothing to call the person for.
      return
    case .waiting:
      phase = .needsYou("\(name(of: conversation)) needs your answer in Boltty.")
      return
    case .failed, .rateLimited:
      if spokenText.isEmpty { return fail("\(name(of: conversation)) could not answer that.") }
    case .idle, .interrupted:
      break
    }
    for piece in chunker.finish() { say(piece, id: speechID) }
    lastAnsweredAt = now()
    scheduleExpiry()
    if voice.isSaying(speechID) {
      phase = .speaking
      return
    }
    finish()
  }

  private func feed(_ delta: String, id: String) {
    let pieces = chunker.append(delta)
    guard !pieces.isEmpty else { return }
    for piece in pieces { say(piece, id: id) }
    phase = .speaking
  }

  /// Hands one piece to the voice. The caption and the marks it carries wait
  /// for the voice to reach it; a mark with no words is shown at once.
  private func say(_ piece: String, id: String) {
    let (text, indices) = AskBolttyPoint.split(piece)
    let carried = indices.compactMap { index in index < marks.count ? marks[index] : nil }
    guard !text.isEmpty else {
      show(carried)
      return
    }
    guard sentencesSaid < Self.answerSentences else { return }
    sentencesSaid += 1
    if !decidedVoice {
      decidedVoice = true
      readsAloud = speaksAloud && speech.canSpeak(language ?? SpeechOutput.language(of: text))
    }
    voice.say(text, id: id, language: language) { [weak self] in
      guard let self, self.speechID == id else { return }
      self.captioned.append(text)
      self.caption = self.captioned.suffix(Self.captionSentences).joined(separator: " ")
      self.show(carried)
    }
  }

  /// A sentence's marks as it is said: the face flies to its first point,
  /// and what it draws goes up.
  private func show(_ carried: [AskBolttyMark]) {
    var flewTo = false
    for mark in carried {
      switch mark {
      case let .point(target) where !flewTo:
        flewTo = true
        point(at: target)
      case .point:
        break
      case let .shape(shape):
        guard let answerFrame else { continue }
        drawn.append(AskBolttyStroke(shape: shape, frame: answerFrame))
      case let .board(shapes):
        drawn += shapes.map { AskBolttyStroke(shape: $0, frame: nil) }
      }
    }
  }

  /// What says this answer: the Mac's voice, or the reader.
  private var voice: AskBolttySpeaking { readsAloud ? speech : reader }

  private func point(at target: AskBolttyPoint) {
    guard let answerFrame else { return }
    pointing = AskBolttyPointing(
      location: target.location(in: answerFrame), label: target.label,
      sequence: (pointing?.sequence ?? 0) + 1)
  }

  /// Called again as the voice falls silent, so the last word ends the Ask Boltty.
  /// Looks again rather than ending: the voice can fall silent between the
  /// turn ending and Ask Boltty hearing of it, and the last sentence — still in the
  /// chunker, waiting for the end — was then never said.
  func speechFinished() {
    guard phase == .speaking, let id = conversationID else { return }
    follow(id)
  }

  private func finish() {
    storeWatch = nil
    phase = .idle
  }

  private func scheduleExpiry() {
    expiry?.invalidate()
    expiry = Timer.scheduledTimer(withTimeInterval: Self.followUpWindow, repeats: false) {
      [weak self] _ in
      MainActor.assumeIsolated { self?.expire() }
    }
  }

  /// The window has passed with no question: the chat and its screenshots go.
  /// One being asked or answered stays; the next answer schedules this again.
  private func expire() {
    expiry = nil
    switch phase {
    case .listening, .thinking, .speaking: return
    case .idle, .needsYou, .failed: break
    }
    coordinator.forgetAskBolttyChats()
    conversationID = nil
    lastAnsweredAt = nil
  }

  private func interruptAnswer() {
    speech.stop()
    reader.stop()
    pointing = nil
    storeWatch = nil
    sendTask?.cancel()
    if case .listening = phase { listener.cancel() }
  }

  private func discardIfNew() {
    guard isNewConversation, let id = conversationID else { return }
    coordinator.discardAskBolttyConversation(id)
    conversationID = nil
    isNewConversation = false
  }

  private func fail(_ message: String) {
    listener.cancel()
    discardIfNew()
    storeWatch = nil
    phase = .failed(message)
  }

  private func name(of conversation: Conversation) -> String {
    AgentId(rawValue: conversation.providerID)?.displayName ?? "The agent"
  }
}

/// The voice of an answer that is only shown: it "says" each piece by
/// putting it in the caption and waiting as long as reading it takes, so a
/// shown answer moves on as a spoken one does.
@MainActor
final class AskBolttyReader: AskBolttySpeaking {
  /// How long a piece stays: a beat, and a little more per character.
  static func readingTime(of text: String) -> TimeInterval {
    max(1.4, 0.6 + 0.055 * Double(text.count))
  }

  var schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, work in
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(work) }
  }
  /// The last piece has been read.
  var onIdle: (() -> Void)?

  private var queue: [(text: String, onStart: (() -> Void)?)] = []
  private var reading = false
  private var id: String?
  private var generation = 0

  func canSpeak(_ language: String?) -> Bool { true }

  func say(_ piece: String, id: String, language: String?, onStart: (() -> Void)?) {
    if self.id != id {
      stop()
      self.id = id
    }
    queue.append((piece, onStart))
    if !reading { next() }
  }

  func isSaying(_ id: String) -> Bool { self.id == id && (reading || !queue.isEmpty) }

  func stop() {
    generation += 1
    queue.removeAll()
    reading = false
    id = nil
  }

  private func next() {
    guard !queue.isEmpty else {
      reading = false
      onIdle?()
      return
    }
    let (text, onStart) = queue.removeFirst()
    reading = true
    onStart?()
    let generation = self.generation
    schedule(Self.readingTime(of: text)) { [weak self] in
      guard let self, self.generation == generation else { return }
      self.next()
    }
  }
}

/// A place the answer is pointing at, on screen.
struct AskBolttyPointing: Equatable {
  /// AppKit's global coordinates.
  var location: CGPoint
  var label: String?
  /// Counts up, so pointing at the same place twice is still news.
  var sequence: Int
}

/// Ask Boltty's ears: Boltty's dictation, with its final words awaited.
@MainActor
final class DictationListener: AskBolttyListening {
  var onText: ((String) -> Void)?
  var onFailure: ((String) -> Void)?
  let dictation: VoiceDictationService
  private var latest = ""
  private var waiting: CheckedContinuation<String, Never>?

  init(dictation: VoiceDictationService = VoiceDictationService()) {
    self.dictation = dictation
    dictation.onTranscript = { [weak self] text in
      self?.latest = text
      self?.onText?(text)
    }
    dictation.onFinalTranscript = { [weak self] in self?.resume() }
    dictation.onError = { [weak self] message in
      self?.resume()
      self?.onFailure?(message)
    }
  }

  func start() {
    latest = ""
    if dictation.state == .idle { dictation.toggle() }
  }

  func finish() async -> String {
    guard dictation.state != .idle else { return latest }
    return await withCheckedContinuation { continuation in
      waiting = continuation
      dictation.stop()
      DispatchQueue.main.asyncAfter(deadline: .now() + AskBolttySession.finalWordsDeadline) { [weak self] in
        self?.resume()
      }
    }
  }

  func cancel() {
    dictation.cancel()
    resume()
  }

  private func resume() {
    guard let waiting else { return }
    self.waiting = nil
    waiting.resume(returning: latest)
  }
}
