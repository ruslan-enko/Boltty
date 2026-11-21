import AppKit
import Combine

@MainActor
protocol AskBolttySpeaking: AnyObject {
  func canSpeak(_ language: String?) -> Bool
  func say(_ piece: String, id: String, language: String?, onStart: (() -> Void)?)
  func isSaying(_ id: String) -> Bool
  func stop()
}

extension SpeechOutput: AskBolttySpeaking {}

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
  @Published private(set) var caption = ""
  @Published private(set) var step: String?
  @Published private(set) var providerID: String?
  @Published private(set) var conversationID: UUID?
  @Published private(set) var pointing: AskBolttyPointing?
  @Published private(set) var drawn: [AskBolttyStroke] = []
  @Published private(set) var readsAloud = true
  /// A walk through steps is under way: each click moves it on.
  @Published private(set) var isGuiding = false
  let reader = AskBolttyReader()
  var speaksAloud = false
  static let captionSentences = 1
  static let answerSentences = 2

  static let followUpWindow: TimeInterval = 600

  private let coordinator: ChatWorkspaceCoordinator
  private let speech: AskBolttySpeaking
  var pictureDirectory: URL = PromptAttachmentStore.shared.directory
  var now: () -> Date = Date.init

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
  private var decidedVoice = false
  private var sendTask: Task<Void, Never>?
  private var storeWatch: AnyCancellable?
  private var expiry: Timer?
  private var followIsScheduled = false
  private var answerSoFar = ""
  private var asked: (words: String, selection: ScreenSelection, displayFrame: CGRect)?
  private var fallbacks: [AskBolttyTarget] = []
  private var note: String?
  private var labels: [ScreenText] = []
  private var steps: [(words: String, target: AskBolttyPoint)] = []
  private var shownStep = -1
  private var waitsForStep = false
  private var lookTask: Task<Void, Never>?
  private var guideIdle: Timer?
  /// A step left this long without a click ends the walk: the face holds
  /// Escape from every other app while it is up.
  static let guideIdleLimit: TimeInterval = 60
  /// What is written on the display with this frame now, read afresh.
  var look: (@MainActor (CGRect) async -> [ScreenText]?)?
  static let settleAfterClick: TimeInterval = 0.45
  static let lookAgainAfter: TimeInterval = 0.7
  var findPlace: (@MainActor (FinderSpot) async -> FinderPlace?)?
  var onSpent: ((String, Date?) -> Void)?

  typealias HandOverReason = AgentHandOver.Reason

  static func handOverNote(skipped: String, why: HandOverReason, next: String) -> String {
    AgentHandOver.sentence(skipped: skipped, why: why, next: next)
  }

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

  func warmUp(_ target: AskBolttyTarget) {
    interruptAnswer()
    stopTurn()
    pointing = nil
    phase = .idle
    choosePlace(for: target)
  }

  func cancel() {
    guard phase == .idle else { return }
    discardIfNew()
  }

  func ask(_ words: String, about selection: ScreenSelection, on displayFrame: CGRect,
           target: AskBolttyTarget, speaksAloud: Bool) {
    ask(words, about: selection, on: displayFrame, targets: [target], speaksAloud: speaksAloud)
  }

  /// The first target answers; if it fails before saying anything, the same
  /// question goes to the next, each once.
  func ask(_ words: String, about selection: ScreenSelection, on displayFrame: CGRect,
           targets: [AskBolttyTarget], note: String? = nil, speaksAloud: Bool) {
    let words = words.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !words.isEmpty, let target = targets.first else { return }
    interruptAnswer()
    stopTurn()
    self.speaksAloud = speaksAloud
    asked = (words, selection, displayFrame)
    fallbacks = Array(targets.dropFirst())
    self.note = note
    choosePlace(for: target)
    pointing = nil
    drawn = []
    caption = ""
    step = note
    readsAloud = true
    phase = .thinking
    sendTask = Task { [weak self] in
      await self?.send(words, about: selection, on: displayFrame)
    }
  }

  func stop() {
    switch phase {
    case .thinking, .speaking, .needsYou:
      interruptAnswer()
      stopTurn()
      phase = .idle
      scheduleExpiry()
    case .idle, .failed:
      return
    }
  }

  private func stopTurn() {
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
      providerID = conversation.providerID
      return
    }
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
      return fail(String(localized: "Boltty could not keep a picture of the screen."))
    }
    var place: FinderPlace?
    if let spot = selection.finderSpot { place = await findPlace?(spot) }
    guard !Task.isCancelled, phase == .thinking else { return }
    if let place, let moved = reopen(id, in: URL(fileURLWithPath: place.folder).path) { id = moved }
    let wholeScreen = selection.frame.insetBy(dx: -1, dy: -1).contains(displayFrame)
    let region = AskBolttyRegion(
      screenPath: screenURL.path, areaPath: areaURL.path, context: selection.context,
      recognizedText: selection.recognizedText, isWholeScreen: wholeScreen, finderPlace: place,
      isOverUnreadFinder: selection.finderSpot != nil && place == nil,
      labels: selection.labels ?? [],
      area: Self.thousandths(of: selection.frame, in: displayFrame))
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
    coordinator.store.recordSentFiles(
      [SentFile(path: (wholeScreen ? screenURL : areaURL).path, label: "",
                name: wholeScreen ? "Screen.png" : "Area.png", expansion: bracket)],
      for: id)
    if isNewConversation {
      coordinator.store.rename(id: id, to: ConversationEngine.title(from: words))
    }
    answerFrame = displayFrame
    labels = selection.labels ?? []
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
      return fail(String(localized: "That question was not sent."))
    }
    isNewConversation = false
    watch(id)
  }

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

  func follow(_ id: UUID) {
    guard id == conversationID, let speechID else { return }
    guard let conversation = coordinator.store.conversation(id: id) else { return finish() }
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

    if coordinator.failedPanelPrompts[id] != nil {
      return handOver(from: conversation, failure: nil)
    }
    if coordinator.pendingPanelPrompts[id] != nil { return }
    let failure = coordinator.store.transcript(id: id).messages.dropFirst(baseline)
      .last { $0.failure.map { !$0.isAbort } == true }?.failure
    if conversation.lastKnownState == .working || !spokenText.isEmpty || failure != nil {
      turnBegan = true
    }
    guard turnBegan else { return }

    switch conversation.lastKnownState {
    case .working:
      // Answered: it is at work again, and the next thing it asks must open the
      // panel again, or a turn with many steps waits unseen on its second.
      if case .needsYou = phase { phase = .thinking }
      let live = BolttyAISessionList.liveStep(in: coordinator.store.transcript(id: id))
      if phase == .speaking, !isGuiding, live != nil, !voice.isSaying(speechID) {
        phase = .thinking
        caption = ""
        sentencesSaid = 0
      }
      let shown = (phase == .thinking && !conversation.readOnly ? live : nil) ?? note
      if shown != step { step = shown }
      return
    case .waiting:
      if conversation.readOnly,
         case .permission? = coordinator.store.transcript(id: id).openInteraction?.kind { return }
      phase = .needsYou(String(localized: "\(name(of: conversation)) needs your answer in Boltty."))
      return
    case .failed, .rateLimited:
      if spokenText.isEmpty { return handOver(from: conversation, failure: failure) }
    case .idle, .interrupted:
      break
    }
    for piece in chunker.finish() { say(piece, id: speechID) }
    lastAnsweredAt = now()
    scheduleExpiry()
    if isGuiding {
      if waitsForStep, shownStep >= 0, shownStep + 1 >= steps.count {
        isGuiding = false
        waitsForStep = false
      } else {
        phase = .speaking
        return
      }
    }
    if voice.isSaying(speechID) {
      phase = .speaking
      return
    }
    finish()
  }

  /// A failure before any word: the next agent gets the same question, and the
  /// face says who took it and why. With none left, it says why it failed.
  private func handOver(from conversation: Conversation, failure: MessageFailure?) {
    let who = name(of: conversation)
    let why: HandOverReason
    if let hit = failure?.rateLimit {
      why = .spent
      onSpent?(conversation.providerID, hit.resetsAt)
    } else if conversation.lastKnownState == .rateLimited {
      why = .spent
      onSpent?(conversation.providerID, nil)
    } else if failure.map(AgentFailureReport.saysModelIsGone) == true {
      why = .modelGone
    } else {
      why = .failed
    }
    guard let asked, !fallbacks.isEmpty else {
      switch why {
      case .spent:
        let reset = failure?.rateLimit?.resetsAt.flatMap { $0 > now() ? $0 : nil }
        return fail(reset.map {
          String(localized: "\(who)'s limit is used up — it comes back \(AgentUsageWindow.resetPhrase($0, now: now())).")
        } ?? String(localized: "\(who)'s limit is used up."))
      case .modelGone:
        return fail(String(localized: "\(who)'s model isn't available any more."))
      case .failed:
        return fail(String(localized: "\(who) could not answer that."))
      }
    }
    let next = fallbacks.removeFirst()
    storeWatch = nil
    isNewConversation = false
    choosePlace(for: next)
    note = AgentId(rawValue: next.providerID).map {
      Self.handOverNote(skipped: who, why: why, next: $0.displayName)
    }
    step = note
    sendTask = Task { [weak self] in
      await self?.send(asked.words, about: asked.selection, on: asked.displayFrame)
    }
  }

  private func feed(_ delta: String, id: String) {
    let pieces = chunker.append(delta)
    guard !pieces.isEmpty else { return }
    note = nil
    for piece in pieces { say(piece, id: id) }
    phase = .speaking
  }

  private func say(_ piece: String, id: String) {
    let (text, indices) = AskBolttyPoint.split(piece)
    let carried = indices.compactMap { index in index < marks.count ? marks[index] : nil }
    if let step = carried.lazy.compactMap({ mark -> AskBolttyPoint? in
      if case let .step(target) = mark { return target }
      return nil
    }).first {
      return addStep(text, target: step)
    }
    if !text.isEmpty, let last = steps.indices.last, steps[last].words.isEmpty {
      steps[last].words = text
      if waitsForStep, last == shownStep + 1 { presentStep(last) }
      return
    }
    if isGuiding { return }
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

  private func show(_ carried: [AskBolttyMark]) {
    var flewTo = false
    for mark in carried {
      switch mark {
      case let .point(target) where !flewTo:
        flewTo = true
        point(at: target)
      case .point, .step:
        break
      case let .shape(shape):
        guard let answerFrame else { continue }
        drawn.append(AskBolttyStroke(shape: shape, frame: answerFrame))
      case let .board(shapes):
        drawn += shapes.map { AskBolttyStroke(shape: $0, frame: nil) }
      }
    }
  }

  private var voice: AskBolttySpeaking { readsAloud ? speech : reader }

  private func point(at target: AskBolttyPoint) {
    guard let answerFrame, let target = target.placed(among: labels) else { return }
    pointing = AskBolttyPointing(
      location: target.location(in: answerFrame), label: target.label,
      sequence: (pointing?.sequence ?? 0) + 1)
  }

  static func thousandths(of frame: CGRect, in display: CGRect) -> CGRect? {
    guard display.width > 0, display.height > 0 else { return nil }
    return CGRect(
      x: (frame.minX - display.minX) / display.width * 1000,
      y: (display.maxY - frame.maxY) / display.height * 1000,
      width: frame.width / display.width * 1000,
      height: frame.height / display.height * 1000)
  }

  // MARK: - Steps

  private func addStep(_ words: String, target: AskBolttyPoint) {
    steps.append((words, target))
    if !isGuiding {
      isGuiding = true
      waitsForStep = true
    }
    if waitsForStep, !words.isEmpty, steps.count - 1 == shownStep + 1 { presentStep(steps.count - 1) }
  }

  /// A click: the next step, once what it opened has had a moment to show.
  func nextStep() {
    guard isGuiding, !waitsForStep else { return }
    lookTask?.cancel()
    let next = shownStep + 1
    let id = conversationID
    guard next < steps.count else {
      let working = id.flatMap { coordinator.store.conversation(id: $0) }?.lastKnownState == .working
      guard !working else {
        waitsForStep = true
        return
      }
      return endGuide()
    }
    waitsForStep = true
    lookTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(Self.settleAfterClick))
      guard let self, !Task.isCancelled, self.conversationID == id else { return }
      self.presentStep(next)
    }
  }

  private func presentStep(_ index: Int) {
    guard isGuiding, steps.indices.contains(index), let speechID else { return }
    // Its words are still coming: the piece that brings them presents it.
    guard !steps[index].words.isEmpty else {
      waitsForStep = true
      return
    }
    waitsForStep = false
    shownStep = index
    restartGuideIdle()
    let step = steps[index]
    let numbered = "\(index + 1). \(step.words)"
    if !decidedVoice {
      decidedVoice = true
      readsAloud = speaksAloud && speech.canSpeak(language ?? SpeechOutput.language(of: step.words))
    }
    phase = .speaking
    voice.say(step.words, id: speechID, language: language) { [weak self] in
      guard let self, self.speechID == speechID, self.shownStep == index else { return }
      self.caption = numbered
    }
    if index == 0, let target = step.target.placed(among: labels) {
      return point(at: target)
    }
    lookTask?.cancel()
    lookTask = Task { [weak self] in await self?.find(step.target, for: index) }
  }

  /// The step's words on the screen as it is now: the earlier step may have
  /// opened a menu or a dialog the agent never saw.
  private func find(_ target: AskBolttyPoint, for index: Int) async {
    guard let text = target.text, let frame = answerFrame, let look else {
      pointAtItsPlace(target)
      return
    }
    let near = target.hasPosition ? CGPoint(x: target.x * 1000, y: target.y * 1000) : nil
    for attempt in 0..<2 {
      if attempt > 0 { try? await Task.sleep(for: .seconds(Self.lookAgainAfter)) }
      guard !Task.isCancelled, shownStep == index else { return }
      guard let lines = await look(frame), !Task.isCancelled, shownStep == index,
            let box = ScreenText.find(text, near: near, in: lines)
      else { continue }
      let found = AskBolttyPoint(x: box.midX / 1000, y: box.midY / 1000, label: target.label)
      pointing = AskBolttyPointing(
        location: found.location(in: frame), label: found.label,
        sequence: (pointing?.sequence ?? 0) + 1)
      return
    }
    if !Task.isCancelled, shownStep == index { pointAtItsPlace(target) }
  }

  /// Where the agent put a step it could see; with no place, the face goes back
  /// to the pointer.
  private func pointAtItsPlace(_ target: AskBolttyPoint) {
    guard target.hasPosition else {
      pointing = nil
      return
    }
    var placed = target
    placed.text = nil
    point(at: placed)
  }

  private func restartGuideIdle() {
    guideIdle?.invalidate()
    guideIdle = Timer.scheduledTimer(withTimeInterval: Self.guideIdleLimit, repeats: false) {
      [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.isGuiding else { return }
        self.endGuide()
      }
    }
  }

  private func endGuide() {
    guideIdle?.invalidate()
    guideIdle = nil
    lookTask?.cancel()
    lookTask = nil
    isGuiding = false
    waitsForStep = false
    if let id = conversationID { follow(id) }
  }

  private func clearGuide() {
    guideIdle?.invalidate()
    guideIdle = nil
    lookTask?.cancel()
    lookTask = nil
    steps = []
    shownStep = -1
    waitsForStep = false
    if isGuiding { isGuiding = false }
  }

  /// Looks again rather than ending: the voice can fall silent between the turn
  /// ending and Ask Boltty hearing of it, and the last sentence was then never
  /// said.
  func speechFinished() {
    guard phase == .speaking, let id = conversationID else { return }
    follow(id)
  }

  private func finish() {
    storeWatch = nil
    note = nil
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

  private func expire() {
    expiry = nil
    switch phase {
    case .thinking, .speaking, .needsYou: return
    case .idle, .failed: break
    }
    if let id = conversationID, coordinator.store.selectedConversationID == id {
      scheduleExpiry()
      return
    }
    coordinator.forgetAskBolttyChats()
    conversationID = nil
    lastAnsweredAt = nil
  }

  private func interruptAnswer() {
    clearGuide()
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
    note = nil
    step = nil
    fallbacks = []
    phase = .failed(message)
    scheduleExpiry()
  }

  private func name(of conversation: Conversation) -> String {
    AgentId(rawValue: conversation.providerID)?.displayName ?? String(localized: "The agent")
  }
}

@MainActor
final class AskBolttyReader: AskBolttySpeaking {
  static func readingTime(of text: String) -> TimeInterval {
    max(1.4, 0.6 + 0.055 * Double(text.count))
  }

  var schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, work in
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(work) }
  }
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

struct AskBolttyPointing: Equatable {
  var location: CGPoint
  var label: String?
  var sequence: Int
}
