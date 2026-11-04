import AppKit
import Combine

/// What Ask Boltty speaks with. `onStart` runs as the voice begins the piece.
@MainActor
protocol AskBolttySpeaking: AnyObject {
  /// Whether text in `language` is said at all (`SpeechOutput.languages`).
  func canSpeak(_ language: String?) -> Bool
  func say(_ piece: String, id: String, language: String?, onStart: (() -> Void)?)
  func isSaying(_ id: String) -> Bool
  func stop()
}

extension SpeechOutput: AskBolttySpeaking {}

/// One question about the screen, from the region being drawn to the answer's
/// last word: the agent's session starts as the region is drawn (`warmUp`),
/// the words and the region go together (`ask`), and the answer is shown — or
/// said — a sentence at a time beside the face as it arrives.
@MainActor
final class AskBolttySession: ObservableObject {
  enum Phase: Equatable {
    case idle
    case thinking
    case speaking
    case needsYou(String)
    case failed(String)
  }

  @Published private(set) var phase: Phase = .idle
  /// The sentence the voice was last handed.
  @Published private(set) var caption = ""
  /// What a turn that can make changes is doing while it has nothing to say.
  @Published private(set) var step: String?
  /// The answer's agent, for the face that shows it.
  @Published private(set) var providerID: String?
  @Published private(set) var conversationID: UUID?
  /// Where the answer is pointing now, as the sentence that names it is said.
  @Published private(set) var pointing: AskBolttyPointing?
  /// What the answers have drawn so far, in order: up until the next question.
  @Published private(set) var drawn: [AskBolttyStroke] = []
  /// Whether this answer is said, or only shown: Boltty speaks Supertonic's
  /// languages, once it is downloaded, and no others. Shown, `reader` paces it as a voice would.
  @Published private(set) var readsAloud = true
  /// The voice for an answer that is only shown: each sentence stays for as
  /// long as it takes to read.
  let reader = AskBolttyReader()
  /// Settings › Ask Boltty › "Say answers aloud", read as a question is sent.
  /// Off, the answer types out beside the face, which "speaks" in blips.
  var speaksAloud = false
  /// The caption is the sentence being said: a new one takes the last one's
  /// place.
  static let captionSentences = 1
  /// An answer is said up to this many sentences; the rest stays in the chat.
  static let answerSentences = 2

  /// A question asked within this of the last answer continues that chat,
  /// so a run of questions shares what was said; past it the chat is let go.
  static let followUpWindow: TimeInterval = 600

  private let coordinator: ChatWorkspaceCoordinator
  private let speech: AskBolttySpeaking
  var pictureDirectory: URL = PromptAttachmentStore.shared.directory
  var now: () -> Date = Date.init

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
  private var followIsScheduled = false
  /// The answer as last read: nothing else in it to work out while it is the same.
  private var answerSoFar = ""
  /// The folder a region over Finder or the desktop shows, if it can be known.
  var findPlace: (@MainActor (FinderSpot) async -> FinderPlace?)?

  init(
    coordinator: ChatWorkspaceCoordinator,
    speech: AskBolttySpeaking
  ) {
    self.coordinator = coordinator
    self.speech = speech
    reader.onIdle = { [weak self] in self?.speechFinished() }
  }

  var speechID: String? { conversationID.map { "talk-\($0.uuidString)" } }

  // MARK: - The question

  /// A region is drawn: the agent's session starts while the person speaks.
  /// What was being said stops — a new question is not a reason for the old
  /// answer to go on.
  func warmUp(_ target: AskBolttyTarget) {
    interruptAnswer()
    stopTurn()
    pointing = nil
    phase = .idle
    choosePlace(for: target)
  }

  /// The region was let go of without a question: a chat made for it goes.
  func cancel() {
    guard phase == .idle else { return }
    discardIfNew()
  }

  /// Sends `words` about `selection`; `displayFrame` is the screen it was
  /// cut from, in AppKit's coordinates — what the answer's points measure.
  func ask(_ words: String, about selection: ScreenSelection, on displayFrame: CGRect,
           target: AskBolttyTarget, speaksAloud: Bool) {
    let words = words.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !words.isEmpty else { return }
    interruptAnswer()
    stopTurn()
    self.speaksAloud = speaksAloud
    choosePlace(for: target)
    pointing = nil
    drawn = []
    caption = ""
    step = nil
    readsAloud = true
    phase = .thinking
    sendTask = Task { [weak self] in
      await self?.send(words, about: selection, on: displayFrame)
    }
  }

  /// Escape while it thinks or answers: the agent's turn is stopped, the
  /// words and the face go. Drawings already up stay for their own Escape.
  func stop() {
    switch phase {
    case .thinking, .speaking, .needsYou:
      interruptAnswer()
      stopTurn()
      phase = .idle
      // Called off with no answer, it still keeps no history past the window.
      scheduleExpiry()
    case .idle, .failed:
      return
    }
  }

  /// Stops the agent's turn in Ask Boltty's chat, if one is running: a new
  /// question or an Escape is not a reason for it to go on spending.
  private func stopTurn() {
    // One gone on with in the panel is the person's: its turn is not ours to stop.
    guard let id = conversationID,
          let conversation = coordinator.store.conversation(id: id), conversation.isAskBoltty,
          conversation.lastKnownState.blocksSending
    else { return }
    let engine = coordinator.engine
    Task { await engine.stop(conversationID: id) }
  }

  // MARK: - Sending

  private func choosePlace(for target: AskBolttyTarget) {
    if let id = conversationID,
       let conversation = coordinator.store.conversation(id: id),
       conversation.isAskBoltty,
       conversation.providerID == target.providerID,
       conversation.readOnly == target.readOnly,
       !conversation.lastKnownState.blocksSending,
       isNewConversation
        || lastAnsweredAt.map({ now().timeIntervalSince($0) < Self.followUpWindow }) == true {
      // Warmed up for this question, or a follow-up within the window.
      providerID = conversation.providerID
      return
    }
    // A chat warmed up for another agent and never asked in goes; and Ask
    // Boltty keeps no history past the window, so the chats before this do too.
    discardIfNew()
    coordinator.forgetAskBolttyChats()
    let conversation = coordinator.prepareAskBolttyConversation(
      providerID: target.providerID, model: target.model, effort: target.effort,
      readOnly: target.readOnly)
    conversationID = conversation.id
    providerID = conversation.providerID
    isNewConversation = true
  }

  private func send(_ words: String, about selection: ScreenSelection, on displayFrame: CGRect) async {
    guard var id = conversationID else { return }
    let directory = pictureDirectory
    // Two PNGs of a 5K screen are tens of milliseconds: off the main thread.
    let urls = await Task.detached(priority: .userInitiated) {
      (Self.writePicture(selection.screen, in: directory),
       Self.writePicture(selection.region, in: directory))
    }.value
    guard !Task.isCancelled, phase == .thinking else { return }
    guard let screenURL = urls.0, let areaURL = urls.1 else {
      return fail("Boltty could not keep a picture of the screen.")
    }
    // "Organise this": what the picture shows as a window is a folder on disk.
    var place: FinderPlace?
    if let spot = selection.finderSpot { place = await findPlace?(spot) }
    guard !Task.isCancelled, phase == .thinking else { return }
    if let place, let moved = reopen(id, in: URL(fileURLWithPath: place.folder).path) { id = moved }
    let wholeScreen = selection.frame.insetBy(dx: -1, dy: -1).contains(displayFrame)
    let region = AskBolttyRegion(
      screenPath: screenURL.path, areaPath: areaURL.path, context: selection.context,
      recognizedText: selection.recognizedText, isWholeScreen: wholeScreen, finderPlace: place,
      isOverUnreadFinder: selection.finderSpot != nil && place == nil)
    let readOnly = coordinator.store.conversation(id: id)?.readOnly ?? true
    let bracket = AskBolttyPrompt.bracket(region: region, readOnly: readOnly)
    func picture(_ url: URL, _ name: String, _ data: Data) -> ConversationAttachment {
      ConversationAttachment(
        id: "talk-\(url.lastPathComponent)", displayName: name, url: url,
        mimeType: "image/png", byteCount: data.count)
    }
    let pictures = wholeScreen
      ? [picture(screenURL, "Screen", selection.screen)]
      : [picture(screenURL, "Screen", selection.screen), picture(areaURL, "Area", selection.region)]
    // The card shows the question and the area's picture, not the bracket.
    coordinator.store.recordSentFiles(
      [SentFile(path: (wholeScreen ? screenURL : areaURL).path, label: "",
                name: wholeScreen ? "Screen.png" : "Area.png", expansion: bracket)],
      for: id)
    if isNewConversation {
      coordinator.store.rename(id: id, to: ConversationEngine.title(from: words))
    }
    answerFrame = displayFrame
    marks = []
    captioned = []
    language = SpeechOutput.language(of: words)
    decidedVoice = false
    baseline = coordinator.store.transcript(id: id).messages.count
    answerSoFar = ""
    spokenText = ""
    turnBegan = false
    chunker = SentenceChunker()
    sentencesSaid = 0
    guard coordinator.sendFollowUp(bracket + words, pictures: pictures, to: id) else {
      return fail("That question was not sent.")
    }
    isNewConversation = false
    watch(id)
  }

  /// "Here" is where the agent should work, and a session cannot move: a chat
  /// warmed up elsewhere, or one going on from another folder, gives way to one
  /// started there. It is also what lets OpenCode into Downloads or the Desktop
  /// (`OpenCodeClient.isPrivacyProtected` goes by the session's folder).
  private func reopen(_ id: UUID, in folder: String) -> UUID? {
    guard let old = coordinator.store.conversation(id: id), old.workingDirectory != folder else { return nil }
    discardIfNew()
    coordinator.forgetAskBolttyChats()
    let new = coordinator.prepareAskBolttyConversation(
      providerID: old.providerID, model: old.model, effort: old.reasoningEffort,
      readOnly: old.readOnly, workingDirectory: folder)
    conversationID = new.id
    providerID = new.providerID
    isNewConversation = true
    return new.id
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

  /// Once a turn of the run loop however much changed: the store changes per
  /// token of every chat, not only this one's.
  private func watch(_ id: UUID) {
    storeWatch = coordinator.store.objectWillChange
      .sink { [weak self] _ in
        guard let self, !self.followIsScheduled else { return }
        self.followIsScheduled = true
        DispatchQueue.main.async { [weak self] in
          guard let self else { return }
          self.followIsScheduled = false
          if self.storeWatch != nil { self.follow(id) }
        }
      }
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
    if answer != answerSoFar {
      answerSoFar = answer
      marks = AskBolttyMark.all(in: answer)
      let spoken = SpokenText.speakable(answer, keepingPoints: true)
      if spoken.hasPrefix(spokenText), spoken.count > spokenText.count {
        feed(String(spoken.dropFirst(spokenText.count)), id: speechID)
        spokenText = spoken
      }
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
      // Answered: it is at work again, and the next thing it asks must open the
      // panel again, or a turn with many steps waits unseen on its second.
      if case .needsYou = phase { phase = .thinking }
      let live = BolttyAISessionList.liveStep(in: coordinator.store.transcript(id: id))
      // What it said has been said and it is at work again: back to the step,
      // and what it says when it is done has its two sentences of its own.
      if phase == .speaking, live != nil, !voice.isSaying(speechID) {
        phase = .thinking
        caption = ""
        sentencesSaid = 0
      }
      // A question that only looks stays "Thinking…": its steps would be the
      // reading of its own screenshot.
      let shown = phase == .thinking && !conversation.readOnly ? live : nil
      if shown != step { step = shown }
      return
    case .waiting:
      // The engine refuses a read-only chat's permissions itself: nothing to
      // call the person for. What it asks them is theirs to answer.
      if conversation.readOnly,
         case .permission? = coordinator.store.transcript(id: id).openInteraction?.kind { return }
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

  /// What says this answer: Supertonic, or the reader.
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
    step = nil
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
    case .thinking, .speaking, .needsYou: return
    case .idle, .failed: break
    }
    // One open in the panel is being read: looked at again a window later.
    if let id = conversationID, coordinator.store.selectedConversationID == id {
      scheduleExpiry()
      return
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
  }

  private func discardIfNew() {
    guard isNewConversation, let id = conversationID else { return }
    coordinator.discardAskBolttyConversation(id)
    conversationID = nil
    isNewConversation = false
  }

  private func fail(_ message: String) {
    discardIfNew()
    storeWatch = nil
    phase = .failed(message)
    scheduleExpiry()
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
