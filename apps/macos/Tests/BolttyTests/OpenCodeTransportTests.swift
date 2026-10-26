import XCTest
@testable import Boltty

final class OpenCodeTransportTests: XCTestCase {
  // MARK: - Errors the provider passed along

  private func errorValue(_ object: [String: Any]) throws -> JSONValue {
    let data = try JSONSerialization.data(withJSONObject: object)
    return try JSONDecoder().decode(JSONValue.self, from: data)
  }

  private static let providerBody = #"""
    {"type":"error","error":{"type":"FreeTierError","message":"Error from provider (Console): OpenCode's free tier can only be used from within OpenCode"}}
    """#

  func testAProviderErrorIsReadToTheEndRatherThanShownAsEscapedJSON() throws {
    let value = try errorValue([
      "type": "unknown",
      "message": "Provider request failed with HTTP 403: \(Self.providerBody)"
    ])

    let failure = OpenCodeMapper.failure(fromError: value)

    XCTAssertEqual(
      failure.name, "FreeTierError",
      "the provider named it; `unknown` is only OpenCode's label for not having raised it"
    )
    XCTAssertEqual(
      failure.message,
      "Error from provider (Console): OpenCode's free tier can only be used from within OpenCode"
    )
    XCTAssertFalse(failure.message.contains("{"), "no JSON reaches the failure card")
  }

  func testAnErrorWithoutAnEnvelopeIsLeftExactlyAsItArrived() throws {
    let value = try errorValue([
      "name": "ProviderAuthError",
      "data": ["message": "missing api key"]
    ])

    let failure = OpenCodeMapper.failure(fromError: value)

    XCTAssertEqual(failure.name, "ProviderAuthError")
    XCTAssertEqual(failure.message, "missing api key")
  }

  func testAnInterruptKeepsItsNameThroughTheUnwrap() throws {
    let value = try errorValue([
      "name": "MessageAbortedError",
      "message": #"aborted {"type":"error","message":"x"}"#
    ])

    XCTAssertTrue(
      OpenCodeMapper.failure(fromError: value).isAbort,
      "an interrupt must stay an interrupt"
    )
  }

  // MARK: - Asking for a transcript

  func testTheTranscriptRequestStaysInsideTheServersLimit() throws {
    let path = OpenCodeClient.messagesPath(sessionID: "ses_1")
    let query = try XCTUnwrap(URLComponents(string: "http://x\(path)")?.queryItems)
    let limit = try XCTUnwrap(query.first { $0.name == "limit" }?.value.flatMap(Int.init))

    XCTAssertLessThanOrEqual(limit, 200, "opencode rejects anything above 200 outright")
    XCTAssertEqual(
      query.first { $0.name == "order" }?.value, "desc",
      "a chat longer than one page must lose its oldest messages, not its newest"
    )
  }

  func testALaterPageCarriesTheCursorAndDropsTheOrder() throws {
    let path = OpenCodeClient.messagesPath(sessionID: "ses_1", cursor: "abc+/=xyz")
    let query = try XCTUnwrap(URLComponents(string: "http://x\(path)")?.queryItems)

    XCTAssertNil(
      query.first { $0.name == "order" },
      "the server rejects order alongside a cursor outright"
    )
    XCTAssertEqual(query.first { $0.name == "cursor" }?.value, "abc+/=xyz")
  }

  func testTheCursorIsPercentEncodedIntoTheQuery() {
    let path = OpenCodeClient.messagesPath(sessionID: "ses_1", cursor: "a+b/c=")

    XCTAssertTrue(path.contains("cursor=a%2Bb%2Fc%3D"), "got \(path)")
  }

  func testTheTranscriptCapIsAWholeNumberOfPages() {
    XCTAssertGreaterThan(OpenCodeClient.transcriptMessageCap, OpenCodeClient.messagePageLimit)
    XCTAssertEqual(
      OpenCodeClient.transcriptMessageCap % OpenCodeClient.messagePageLimit, 0,
      "a cap that stops mid-page makes the last request's work invisible"
    )
  }

  // MARK: - Did anything happen while the stream was down

  private func frame(seq: Int) throws -> OpenCodeDTO.EventFrame {
    try JSONDecoder().decode(OpenCodeDTO.EventFrame.self, from: Data("""
      {"id":"evt_\(seq)","type":"session.next.prompted","durable":{"seq":\(seq)}}
      """.utf8))
  }

  func testAnEmptyPageMeansNothingWasMissed() {
    XCTAssertEqual(OpenCodeClient.missedAnything(seen: 4, events: []), false)
  }

  func testAPageWithEventsMeansSomethingWasMissed() throws {
    XCTAssertEqual(
      OpenCodeClient.missedAnything(seen: 2, events: [try frame(seq: 3)]), true
    )
  }

  func testASessionThatWasNeverStreamedCannotAnswer() {
    XCTAssertNil(OpenCodeClient.missedAnything(seen: nil, events: []))
    XCTAssertNil(OpenCodeClient.missedAnything(seen: nil, events: nil))
  }

  func testAFailedProbeCannotAnswer() {
    XCTAssertNil(OpenCodeClient.missedAnything(seen: 7, events: nil))
  }

  // MARK: - Walking a transcript

  private func pagingFetch(
    count: Int,
    pageSize: Int,
    requests: Box<[String]>
  ) -> (String) async throws -> OpenCodeDTO.ListEnvelope<OpenCodeDTO.Message> {
    let ids = (0..<count).reversed().map { "msg_\($0)" }
    return { path in
      requests.value.append(path)
      let offset = URLComponents(string: "http://x\(path)")?
        .queryItems?.first { $0.name == "cursor" }?.value
        .flatMap { Int($0.replacingOccurrences(of: "at-", with: "")) } ?? 0
      let slice = Array(ids.dropFirst(offset).prefix(pageSize))
      let more = offset + slice.count < ids.count
      let next: Any = more ? "at-\(offset + slice.count)" : NSNull()
      let body: [String: Any] = [
        "data": slice.map { ["id": $0, "type": "user"] },
        "cursor": ["next": next]
      ]
      return try JSONDecoder().decode(
        OpenCodeDTO.ListEnvelope<OpenCodeDTO.Message>.self,
        from: try JSONSerialization.data(withJSONObject: body)
      )
    }
  }

  private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
  }

  func testAChatLongerThanOnePageIsWalkedToTheEndAndPutBackInOrder() async throws {
    let requests = Box<[String]>([])
    let messages = try await OpenCodeClient.walkTranscript(
      sessionID: "ses_1",
      fetch: pagingFetch(count: 11, pageSize: 3, requests: requests)
    )

    XCTAssertGreaterThan(requests.value.count, 1, "precondition: this must actually page")
    XCTAssertEqual(messages.map(\.id), (0..<11).map { "msg_\($0)" }, "oldest first")
    XCTAssertEqual(Set(messages.map(\.id)).count, 11, "and nothing twice")
  }

  func testOnlyTheFirstRequestNamesAnOrder() async throws {
    let requests = Box<[String]>([])
    _ = try await OpenCodeClient.walkTranscript(
      sessionID: "ses_1",
      fetch: pagingFetch(count: 11, pageSize: 3, requests: requests)
    )

    XCTAssertTrue(requests.value[0].contains("order=desc"))
    for later in requests.value.dropFirst() {
      XCTAssertFalse(later.contains("order="), "the server rejects order with a cursor: \(later)")
      XCTAssertTrue(later.contains("cursor="))
    }
  }

  func testAnEndlessServerIsStoppedByTheCapAndLosesTheBeginning() async throws {
    let requests = Box<[String]>([])
    let messages = try await OpenCodeClient.walkTranscript(
      sessionID: "ses_1",
      fetch: pagingFetch(count: 100_000, pageSize: 200, requests: requests)
    )

    XCTAssertEqual(messages.count, OpenCodeClient.transcriptMessageCap)
    XCTAssertEqual(
      messages.last?.id, "msg_99999",
      "the newest message must survive the cap"
    )
  }

  func testAShortChatIsOneRequest() async throws {
    let requests = Box<[String]>([])
    let messages = try await OpenCodeClient.walkTranscript(
      sessionID: "ses_1",
      fetch: pagingFetch(count: 2, pageSize: 200, requests: requests)
    )

    XCTAssertEqual(requests.value.count, 1)
    XCTAssertEqual(messages.map(\.id), ["msg_0", "msg_1"])
  }

  // MARK: - Server-sent events

  private let sample = """
    data: {"id":"evt_1","type":"server.connected","data":{}}

    : heartbeat

    data: {"id":"evt_2","type":"message.part.delta",\
    "data":{"sessionID":"ses_1","messageID":"msg_1","partID":"prt_1",\
    "field":"text","delta":"Hello"}}


    """

  func testFramesAreRecoveredWhateverThePacketBoundariesAre() {
    let expected = ["server.connected", "message.part.delta"]
    for chunkSize in [1, 2, 3, 7, 13, 64, 4096] {
      var parser = ServerSentEventParser()
      var types: [String] = []
      let bytes = Array(sample.utf8)
      for start in stride(from: 0, to: bytes.count, by: chunkSize) {
        let slice = bytes[start..<min(start + chunkSize, bytes.count)]
        for event in parser.consume(slice) {
          let frame = try? JSONDecoder().decode(
            OpenCodeDTO.EventFrame.self,
            from: Data(event.data.utf8)
          )
          if let frame { types.append(frame.type) }
        }
      }
      XCTAssertEqual(types, expected, "failed at chunk size \(chunkSize)")
    }
  }

  func testALargeFrameFedInSmallChunksIsReadInOnePass() {
    let payload = String(repeating: "x", count: 400_000)
    let bytes = Array("data: \(payload)\n\ndata: next\n\n".utf8)
    var parser = ServerSentEventParser()
    var events: [ServerSentEventParser.Event] = []
    let started = Date()
    for start in stride(from: 0, to: bytes.count, by: 32) {
      events += parser.consume(bytes[start..<min(start + 32, bytes.count)])
    }
    XCTAssertEqual(events.map(\.data), [payload, "next"])
    XCTAssertLessThan(Date().timeIntervalSince(started), 5, "read once, not once per chunk")
  }

  func testHeartbeatCommentsAreNotEvents() {
    var parser = ServerSentEventParser()
    XCTAssertTrue(parser.consume(": heartbeat\n\n").isEmpty)
    XCTAssertTrue(parser.consume(":\n\n").isEmpty)
  }

  func testMultipleDataLinesJoinWithNewlines() {
    var parser = ServerSentEventParser()
    let events = parser.consume("data: first\ndata: second\n\n")
    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events[0].data, "first\nsecond")
  }

  func testCarriageReturnsAreTolerated() throws {
    var parser = ServerSentEventParser()
    let events = parser.consume("id: 7\r\nevent: ping\r\ndata: {}\r\n\r\n")
    let event = try XCTUnwrap(events.first, "a CRLF frame must still parse")
    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(event.id, "7")
    XCTAssertEqual(event.name, "ping")
    XCTAssertEqual(event.data, "{}")
  }

  func testACRLFSplitAcrossPacketsDoesNotFabricateAFrameBoundary() throws {
    var parser = ServerSentEventParser()
    XCTAssertTrue(parser.consume(Array("data: {}\r".utf8)).isEmpty)
    XCTAssertTrue(parser.consume(Array("\n".utf8)).isEmpty)
    let events = parser.consume(Array("\r\n".utf8))
    let event = try XCTUnwrap(events.first)
    XCTAssertEqual(event.data, "{}")
  }

  func testAPartialFrameIsHeldUntilItCompletes() {
    var parser = ServerSentEventParser()
    XCTAssertTrue(parser.consume("data: {\"a\":").isEmpty)
    XCTAssertTrue(parser.consume("1}").isEmpty)
    XCTAssertEqual(parser.consume("\n\n").count, 1)
  }

  // MARK: - Event decoding

  private func events(_ json: String) -> [AgentEvent] {
    guard let frame = try? JSONDecoder().decode(
      OpenCodeDTO.EventFrame.self,
      from: Data(json.utf8)
    ) else {
      XCTFail("payload did not decode")
      return []
    }
    return OpenCodeClient.domainEvents(from: frame, resolver: { _ in UUID() })
  }

  func testTextDeltaBecomesAPartDelta() {
    let mapped = events(
      """
      {"id":"evt_2","type":"message.part.delta","durable":{"aggregateID":"ses_1","seq":9,\
      "version":1},"data":{"sessionID":"ses_1","messageID":"msg_1","partID":"prt_1",\
      "field":"text","delta":"Hel"}}
      """
    )
    XCTAssertEqual(
      mapped,
      [
        .partDelta(
          sessionID: "ses_1",
          messageID: "msg_1",
          partID: "prt_1",
          kind: .text,
          delta: "Hel"
        )
      ]
    )
  }

  func testADeltaForANonRenderedFieldIsDropped() {
    XCTAssertTrue(
      events(
        """
        {"id":"e","type":"message.part.delta","data":{"sessionID":"s","messageID":"m",\
        "partID":"p","field":"input","delta":"{"}}
        """
      ).isEmpty
    )
  }

  func testToolPartBecomesAnActivityWithItsSummary() {
    let mapped = events(
      """
      {"id":"e","type":"message.part.updated","data":{"sessionID":"ses_1","part":{\
      "id":"prt_9","sessionID":"ses_1","messageID":"msg_1","type":"tool","callID":"c1",\
      "tool":"write","state":{"status":"completed","title":"Wrote notes.md",\
      "output":"ok","input":{"filePath":"/tmp/notes.md"}}},"time":1}}
      """
    )
    guard case let .partUpdated(_, _, part)? = mapped.first,
          case let .activity(activity) = part
    else { return XCTFail("expected an activity part, got \(mapped)") }
    XCTAssertEqual(activity.name, "write")
    XCTAssertEqual(activity.summary, "Wrote notes.md")
    XCTAssertEqual(activity.state, .completed)
    XCTAssertEqual(activity.files, ["/tmp/notes.md"])
    XCTAssertEqual(activity.headline, "Wrote notes.md")
  }

  // MARK: - opencode 2.0

  func test20StreamsTextAgainstAnOrdinalRatherThanAPartID() {
    let mapped = events(
      """
      {"id":"e","type":"session.text.delta","data":{"sessionID":"ses_1",      "assistantMessageID":"msg_1","ordinal":0,"delta":"The file "}}
      """
    )
    guard case let .partDelta(_, messageID, partID, kind, delta)? = mapped.first
    else { return XCTFail("expected a delta, got \(mapped)") }
    XCTAssertEqual(messageID, "msg_1")
    XCTAssertEqual(kind, .text)
    XCTAssertEqual(delta, "The file ")
    XCTAssertTrue(partID.contains("msg_1"), "a part is identified within its message: \(partID)")
  }

  func test20KeepsTextAndReasoningApartAtTheSameOrdinal() {
    func partID(_ type: String) -> String {
      let mapped = events(
        """
        {"id":"e","type":"\(type)","data":{"sessionID":"ses_1",        "assistantMessageID":"msg_1","ordinal":0,"delta":"x"}}
        """
      )
      guard case let .partDelta(_, _, partID, _, _)? = mapped.first else { return "" }
      return partID
    }
    XCTAssertNotEqual(partID("session.text.delta"), partID("session.reasoning.delta"))
    XCTAssertFalse(partID("session.text.delta").isEmpty)
  }

  func test20NamesAToolBeforeItsArgumentsArrive() {
    let started = events(
      """
      {"id":"e","type":"session.tool.input.started","data":{"sessionID":"ses_1",      "assistantMessageID":"msg_1","id":"call_1","name":"read"}}
      """
    )
    guard case let .partUpdated(_, _, part)? = started.first,
          case let .activity(activity) = part
    else { return XCTFail("expected an activity, got \(started)") }
    XCTAssertEqual(activity.id, "call_1")
    XCTAssertEqual(activity.name, "read")
    XCTAssertEqual(activity.state, .running)
  }

  func test20CarriesToolArgumentsUnderTheSameCallID() {
    let called = events(
      """
      {"id":"e","type":"session.tool.called","data":{"sessionID":"ses_1",      "assistantMessageID":"msg_1","id":"call_1","input":{"path":"/tmp/x.txt"}}}
      """
    )
    guard case let .partUpdated(_, _, part)? = called.first,
          case let .activity(activity) = part
    else { return XCTFail("expected an activity, got \(called)") }
    XCTAssertEqual(activity.id, "call_1")
    XCTAssertEqual(activity.name, "", "the merge keeps the name input.started gave")
    XCTAssertEqual(activity.files, ["/tmp/x.txt"])
  }

  func test20ReportsAToolResultAgainstItsCall() {
    let mapped = events(
      """
      {"id":"e","type":"session.tool.success","data":{"sessionID":"ses_1",      "assistantMessageID":"msg_1","id":"call_1",      "content":[{"type":"text","text":"hello from boltty"}]}}
      """
    )
    guard case let .partUpdated(_, _, part)? = mapped.first,
          case let .activity(activity) = part
    else { return XCTFail("expected an activity, got \(mapped)") }
    XCTAssertEqual(activity.id, "call_1")
    XCTAssertEqual(activity.state, .completed)
    XCTAssertEqual(activity.detail, "hello from boltty")
  }

  func test20EchoesThePromptFromTheInbox() {
    let mapped = events(
      """
      {"id":"e","type":"session.inbox.enqueued","data":{"sessionID":"ses_1",      "inboxID":"msg_1","item":{"type":"user","payload":{"text":"say ok"}}}}
      """
    )
    guard case let .messageUpdated(_, message)? = mapped.first
    else { return XCTFail("expected the echo, got \(mapped)") }
    XCTAssertEqual(message.id, "msg_1")
    XCTAssertEqual(message.role, .user)
    XCTAssertEqual(message.plainText, "say ok")
  }

  func test20AsksPermissionUnderTheShorterName() {
    let mapped = events(
      """
      {"id":"e","type":"permission.asked","data":{"id":"per_1","sessionID":"ses_1",      "action":"external_directory","resources":["/tmp/*"],      "source":{"type":"tool","messageID":"msg_1","id":"call_1"}}}
      """
    )
    guard case let .interactionAsked(interaction)? = mapped.first
    else { return XCTFail("expected a permission, got \(mapped)") }
    XCTAssertEqual(interaction.id, "per_1")
  }

  func test20EndsATurnOnTheStepThatDoesNotCallATool() {
    XCTAssertTrue(
      events(
        """
        {"id":"e","type":"session.step.ended","data":{"sessionID":"ses_1",        "assistantMessageID":"msg_1","finish":"tool-calls"}}
        """
      ).isEmpty,
      "another step is coming"
    )
    let ended = events(
      """
      {"id":"e","type":"session.step.ended","data":{"sessionID":"ses_1",      "assistantMessageID":"msg_1","finish":"stop"}}
      """
    )
    XCTAssertEqual(ended, [.executionStateChanged(sessionID: "ses_1", state: .idle)])
  }

  func test20DoesNotLetTheStreamFamilySwallowSessionIdle() {
    let mapped = events(#"{"id":"e","type":"session.idle","data":{"sessionID":"ses_1"}}"#)
    XCTAssertEqual(mapped, [.executionStateChanged(sessionID: "ses_1", state: .idle)])
  }

  // MARK: - The 2.0 transcript

  private func decodeMessage(_ json: String) throws -> ConversationMessage? {
    let dto = try JSONDecoder().decode(OpenCodeDTO.Message.self, from: Data(json.utf8))
    return OpenCodeMapper.message(from: dto)
  }

  func testAnAssistantMessageWithNoPartIDsStillReads() throws {
    let message = try XCTUnwrap(decodeMessage("""
      {"id":"msg_1","time":{"created":1790067814610,"completed":1790067816944},      "type":"assistant","agent":"build",      "model":{"id":"mimo-v2.6-flash-free","providerID":"opencode"},      "content":[{"type":"reasoning","text":"They want one word."},      {"type":"text","text":"ok"}],"finish":"stop"}
      """))

    XCTAssertEqual(message.role, .agent)
    XCTAssertEqual(message.plainText, "ok")
    XCTAssertEqual(message.parts.count, 2, "the reasoning is kept, just not in the answer")
  }

  func testPartsWithNoIDsAreNumberedWithinTheirMessage() throws {
    let message = try XCTUnwrap(decodeMessage("""
      {"id":"msg_1","time":{"created":1},"type":"assistant",      "content":[{"type":"text","text":"one"},{"type":"text","text":"two"}]}
      """))

    let ids = message.parts.map(\.id)
    XCTAssertEqual(Set(ids).count, 2, "two parts, two ids: \(ids)")
    XCTAssertTrue(ids.allSatisfy { $0.contains("msg_1") })
  }

  func testAPartKeepsAnIDWhenItIsGivenOne() throws {
    let message = try XCTUnwrap(decodeMessage("""
      {"id":"msg_1","time":{"created":1},"type":"assistant",      "content":[{"type":"text","id":"prt_9","text":"one"}]}
      """))

    XCTAssertEqual(message.parts.first?.id, "prt_9")
  }

  func testAnIdleRowIsNotAMessage() throws {
    XCTAssertNil(try decodeMessage(#"{"id":"msg_1","time":{"created":1},"type":"idle","outcome":"succeeded"}"#))
  }

  // MARK: - Forms, which is what 2.0 made of questions

  func testAFormBecomesTheCardsOwnQuestion() {
    let mapped = events(
      """
      {"id":"e","type":"form.created","data":{"form":{"id":"frm_1","sessionID":"ses_1",      "title":"Which framework?","fields":[{"key":"framework","type":"multiselect",      "title":"Pick one","options":[{"value":"swiftui","label":"SwiftUI",      "description":"Declarative"},{"value":"appkit","label":"AppKit"}],"custom":true}]}}}
      """
    )
    guard case let .interactionAsked(interaction)? = mapped.first,
          case let .question(prompt) = interaction.kind
    else { return XCTFail("expected a question, got \(mapped)") }
    XCTAssertEqual(interaction.id, "frm_1")
    XCTAssertEqual(prompt.items.count, 1)
    XCTAssertEqual(prompt.items[0].key, "framework", "the reply is addressed by key")
    XCTAssertEqual(prompt.items[0].header, "Which framework?")
    XCTAssertEqual(prompt.items[0].question, "Pick one")
    XCTAssertEqual(prompt.items[0].choices.map(\.value), ["swiftui", "appkit"])
    XCTAssertEqual(prompt.items[0].choices.map(\.label), ["SwiftUI", "AppKit"])
    XCTAssertTrue(prompt.items[0].allowsMultiple)
    XCTAssertTrue(prompt.items[0].allowsCustom)
  }

  func testAFormAnswersWithItsValueRatherThanItsLabel() {
    let mapped = events(
      """
      {"id":"e","type":"form.created","data":{"form":{"id":"frm_1","sessionID":"ses_1",      "title":"t","fields":[{"key":"k","type":"string","title":"q",      "options":[{"value":"v1","label":"Nicely Written Label"}]}]}}}
      """
    )
    guard case let .interactionAsked(interaction)? = mapped.first,
          case let .question(prompt) = interaction.kind
    else { return XCTFail("expected a question, got \(mapped)") }
    XCTAssertEqual(prompt.items[0].choices[0].value, "v1")
    XCTAssertEqual(prompt.items[0].choices[0].label, "Nicely Written Label")
    XCTAssertFalse(prompt.items[0].allowsMultiple, "a string field takes one answer")
  }

  func testAFieldWithNoOptionsIsAlwaysTypeable() {
    for type in ["string", "number", "integer"] {
      let mapped = events(
        """
        {"id":"e","type":"form.created","data":{"form":{"id":"frm_1","sessionID":"ses_1",        "title":"t","fields":[{"key":"k","type":"\(type)","title":"q"}]}}}
        """
      )
      guard case let .interactionAsked(interaction)? = mapped.first,
            case let .question(prompt) = interaction.kind
      else { return XCTFail("\(type) produced nothing") }
      XCTAssertTrue(prompt.items[0].allowsCustom, "\(type) must be answerable")
    }
  }

  func testTheQuestionToolsFormAsksItsDescription() {
    let mapped = events(
      """
      {"id":"e","type":"form.created","data":{"form":{"id":"frm_1","sessionID":"ses_1",      "title":"Questions","metadata":{"kind":"question"},"fields":[{"key":"q0",      "title":"Зберігання пароля","description":"Де зберігати облікові дані toloka?",      "type":"string","options":[{"value":"Keychain (macOS)","label":"Keychain (macOS)"},      {"value":"Файл з правами 600","label":"Файл з правами 600"}],"custom":true}]}}}
      """
    )
    guard case let .interactionAsked(interaction)? = mapped.first,
          case let .question(prompt) = interaction.kind
    else { return XCTFail("expected a question, got \(mapped)") }
    XCTAssertEqual(prompt.items[0].question, "Де зберігати облікові дані toloka?")
    XCTAssertEqual(prompt.items[0].header, "Зберігання пароля")
    XCTAssertFalse(prompt.items[0].allowsMultiple)
    XCTAssertTrue(prompt.items[0].allowsCustom, "OpenCode offers a typed answer on every question")
  }

  func testABooleanIsYesOrNoAndAnExternalStepIsDone() {
    let mapped = events(
      """
      {"id":"e","type":"form.created","data":{"form":{"id":"frm_1","sessionID":"ses_1",      "title":"Sign in","fields":[{"key":"ok","type":"boolean","title":"Continue?"},      {"key":"login","type":"external","title":"Sign in","url":"https://example.com/login"}]}}}
      """
    )
    guard case let .interactionAsked(interaction)? = mapped.first,
          case let .question(prompt) = interaction.kind
    else { return XCTFail("expected a question, got \(mapped)") }
    XCTAssertEqual(prompt.items[0].choices.map(\.value), ["true", "false"])
    XCTAssertEqual(prompt.items[0].choices.map(\.label), ["Yes", "No"])
    XCTAssertFalse(prompt.items[0].allowsCustom)
    XCTAssertEqual(prompt.items[1].choices.map(\.label), ["Done"])
    XCTAssertTrue(prompt.items[1].question.contains("https://example.com/login"))
  }

  func testTheCardsPositionalAnswersAreAddressedToTheFormsFields() {
    XCTAssertEqual(
      OpenCodeClient.answer(
        fields: [.init(key: "one", type: "string"), .init(key: "two", type: "multiselect")],
        answers: [["a"], ["b", "c"]]
      ),
      ["one": .text("a"), "two": .selections(["b", "c"])]
    )
  }

  func testEachAnswerIsSentInItsFieldsType() throws {
    let fields: [OpenCodeDTO.FormRequest.Field] = [
      .init(key: "q0", type: "string"),
      .init(key: "many", type: "multiselect"),
      .init(key: "ok", type: "boolean"),
      .init(key: "count", type: "integer"),
      .init(key: "login", type: "external"),
    ]
    let body = OpenCodeDTO.FormReplyRequest(answer: OpenCodeClient.answer(
      fields: fields,
      answers: [["Файл з правами 600"], ["x", "y"], ["false"], ["3"], ["true"]]
    ))
    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any]
    let answer = try XCTUnwrap(json?["answer"] as? [String: Any])
    XCTAssertEqual(answer["q0"] as? String, "Файл з правами 600")
    XCTAssertEqual(answer["many"] as? [String], ["x", "y"])
    XCTAssertEqual(answer["ok"] as? Bool, false)
    XCTAssertEqual(answer["count"] as? Double, 3)
    XCTAssertEqual(answer["login"] as? Bool, true)
  }

  func testAWordThatIsNotTheFieldsTypeIsNotGuessedInto() {
    XCTAssertEqual(OpenCodeClient.value(for: .init(key: "n", type: "number"), ["ten"]), .text("ten"))
    XCTAssertEqual(OpenCodeClient.value(for: .init(key: "b", type: "boolean"), ["maybe"]), .text("maybe"))
    XCTAssertEqual(OpenCodeClient.value(for: .init(key: "n", type: "number"), ["2,5"]), .number(2.5))
  }

  func testAFieldLeftBlankIsNotSent() {
    XCTAssertEqual(
      OpenCodeClient.answer(
        fields: [.init(key: "one", type: "string"), .init(key: "two", type: "string")],
        answers: [[], ["b"]]
      ),
      ["two": .text("b")]
    )
  }

  func testExtraAnswersAreDroppedRatherThanGuessedAHomeFor() {
    XCTAssertEqual(
      OpenCodeClient.answer(fields: [.init(key: "one", type: "string")], answers: [["a"], ["b"]]),
      ["one": .text("a")]
    )
  }

  func testAFormAlreadySettledIsAnAskThatIsGone() async {
    do {
      try await OpenCodeClient.answering {
        throw AgentClientError.transport(#"HTTP 409: {"_tag":"FormAlreadySettledError"}"#)
      }
      XCTFail("expected requestGone")
    } catch AgentClientError.requestGone {
    } catch {
      XCTFail("expected requestGone, got \(error)")
    }
    do {
      try await OpenCodeClient.answering {
        throw AgentClientError.transport(#"HTTP 400: {"_tag":"FormInvalidAnswerError"}"#)
      }
      XCTFail("expected the refusal to stand")
    } catch let AgentClientError.transport(detail) {
      XCTAssertTrue(detail.hasPrefix("HTTP 400"), "a refused answer is retryable, not gone")
    } catch {
      XCTFail("expected transport, got \(error)")
    }
  }

  func testOnlyAFormIDRoutesToTheFormEndpoints() {
    XCTAssertTrue(OpenCodeClient.isForm("frm_0c84"))
    XCTAssertFalse(OpenCodeClient.isForm("que_1"))
    XCTAssertFalse(OpenCodeClient.isForm("per_1"))
  }

  func testAnAnsweredFormResolvesTheAsk() {
    let mapped = events(
      """
      {"id":"e","type":"form.replied","data":{"id":"frm_1","sessionID":"ses_1",      "answer":{"framework":["swiftui"]}}}
      """
    )
    guard case let .interactionResolved(sessionID, requestID, resolution)? = mapped.first
    else { return XCTFail("expected a resolution, got \(mapped)") }
    XCTAssertEqual(sessionID, "ses_1")
    XCTAssertEqual(requestID, "frm_1")
    XCTAssertEqual(resolution, .answered([["swiftui"]]))
  }

  func testACancelledFormReadsAsARejection() {
    let mapped = events(
      #"{"id":"e","type":"form.cancelled","data":{"id":"frm_1","sessionID":"ses_1"}}"#
    )
    XCTAssertEqual(
      mapped,
      [.interactionResolved(sessionID: "ses_1", requestID: "frm_1", resolution: .rejected)]
    )
  }

  func testStepAndSnapshotPartsAreNotDrawn() {
    XCTAssertTrue(
      events(
        """
        {"id":"e","type":"message.part.updated","data":{"sessionID":"s","part":{\
        "id":"prt_1","sessionID":"s","messageID":"m","type":"step-start"},"time":1}}
        """
      ).isEmpty
    )
  }

  func testQuestionKeepsTheProvidersOwnOptionValues() {
    let mapped = events(
      """
      {"id":"e","type":"question.v2.asked","data":{"id":"que_1","sessionID":"ses_1",\
      "questions":[{"question":"Which framework?","header":"Framework","options":[\
      {"label":"SwiftUI","description":"Declarative"},\
      {"label":"AppKit","description":"Classic"}],"multiple":false,"custom":true}],\
      "tool":{"messageID":"msg_1","callID":"call_1"}}}
      """
    )
    guard case let .interactionAsked(interaction)? = mapped.first,
          case let .question(prompt) = interaction.kind
    else { return XCTFail("expected a question, got \(mapped)") }
    XCTAssertEqual(interaction.id, "que_1")
    XCTAssertEqual(prompt.items[0].choices.map(\.value), ["SwiftUI", "AppKit"])
    XCTAssertEqual(prompt.items[0].choices.map(\.label), ["SwiftUI", "AppKit"])
    XCTAssertEqual(prompt.items[0].choices[0].detail, "Declarative")
    XCTAssertTrue(prompt.items[0].allowsCustom)
    XCTAssertEqual(prompt.toolCallID, "call_1")
  }

  func testPermissionCarriesActionAndResources() {
    let mapped = events(
      """
      {"id":"e","type":"permission.v2.asked","data":{"id":"per_1","sessionID":"ses_1",\
      "action":"bash","resources":["rm -rf build"],"save":["bash:rm *"],\
      "source":{"type":"tool","messageID":"msg_1","callID":"c1"}}}
      """
    )
    guard case let .interactionAsked(interaction)? = mapped.first,
          case let .permission(prompt) = interaction.kind
    else { return XCTFail("expected a permission, got \(mapped)") }
    XCTAssertEqual(prompt.action, "bash")
    XCTAssertEqual(prompt.resources, ["rm -rf build"])
    XCTAssertEqual(prompt.savePatterns, ["bash:rm *"])
  }

  func testPermissionReplyFromAnotherClientIsMappedAsADecision() {
    let mapped = events(
      """
      {"id":"e","type":"permission.v2.replied","data":{"sessionID":"ses_1",\
      "requestID":"per_1","reply":"always"}}
      """
    )
    XCTAssertEqual(
      mapped,
      [
        .interactionResolved(
          sessionID: "ses_1",
          requestID: "per_1",
          resolution: .permission(.always)
        )
      ]
    )
  }

  func testSessionStatusMapsBusyToWorking() {
    XCTAssertEqual(
      events(
        """
        {"id":"e","type":"session.status","data":{"sessionID":"s","status":{"type":"busy"}}}
        """
      ),
      [.executionStateChanged(sessionID: "s", state: .working)]
    )
    XCTAssertEqual(
      events(
        """
        {"id":"e","type":"session.status","data":{"sessionID":"s","status":{"type":"idle"}}}
        """
      ),
      [.executionStateChanged(sessionID: "s", state: .idle)]
    )
  }

  func testAnAbortIsRecognisedSoItIsNotShownAsAFailure() {
    let mapped = events(
      """
      {"id":"e","type":"session.error","data":{"sessionID":"s","error":\
      {"name":"MessageAbortedError","data":{"message":"aborted"}}}}
      """
    )
    guard case let .sessionFailed(_, failure)? = mapped.first else {
      return XCTFail("expected a failure, got \(mapped)")
    }
    XCTAssertTrue(failure.isAbort)
  }

  func testAnUnknownEventTypeIsIgnoredRatherThanFatal() {
    XCTAssertTrue(events(#"{"id":"e","type":"pty.created","data":{"id":"x"}}"#).isEmpty)
  }

  func testAMessageEventUsesTheEventProjectionNotTheRestOne() {
    let mapped = events(
      """
      {"id":"e","type":"message.updated","data":{"sessionID":"ses_1","info":{\
      "id":"msg_1","sessionID":"ses_1","role":"assistant",\
      "time":{"created":1757351000000}}}}
      """
    )
    guard case let .messageUpdated(sessionID, message)? = mapped.first else {
      return XCTFail("expected a message, got \(mapped)")
    }
    XCTAssertEqual(sessionID, "ses_1")
    XCTAssertEqual(message.id, "msg_1")
    XCTAssertEqual(message.role, .agent)
  }

  // MARK: - REST projection

  func testRestHistoryDecodesUserAndAssistantMessages() throws {
    let json = """
      {"data":[
        {"id":"msg_1","type":"user","time":{"created":1757351000000},"text":"do it"},
        {"id":"msg_2","type":"assistant","time":{"created":1757351001000,\
      "completed":1757351002000},"content":[\
      {"type":"text","id":"prt_1","text":"done"},\
      {"type":"tool","id":"prt_2","name":"write","state":{"status":"completed",\
      "outputPaths":["/tmp/a.txt"]}}]},
        {"id":"msg_3","type":"agent-switched","time":{"created":1757351003000}}
      ]}
      """
    let decoded = try JSONDecoder().decode(
      OpenCodeDTO.ListEnvelope<OpenCodeDTO.Message>.self,
      from: Data(json.utf8)
    )
    let mapped = decoded.data.compactMap(OpenCodeMapper.message(from:))
    XCTAssertEqual(mapped.count, 2, "bookkeeping message types are not drawn")
    XCTAssertEqual(mapped[0].role, .user)
    XCTAssertEqual(mapped[0].plainText, "do it")
    XCTAssertEqual(mapped[1].role, .agent)
    XCTAssertEqual(mapped[1].plainText, "done")
    XCTAssertNotNil(mapped[1].completedAt)
    guard case let .activity(activity) = mapped[1].parts[1] else {
      return XCTFail("expected a tool activity")
    }
    XCTAssertEqual(activity.files, ["/tmp/a.txt"])
  }

  // MARK: - Server management

  func testThePortIsReadFromTheServersOwnOutput() {
    XCTAssertEqual(
      OpenCodeServer.parsePort(from: "opencode server listening on http://127.0.0.1:65199\n"),
      65199
    )
    XCTAssertEqual(
      OpenCodeServer.parsePort(from: "listening on http://localhost:4096"),
      4096
    )
    XCTAssertNil(OpenCodeServer.parsePort(from: "loading config...\n"))
  }

  func testDiagnosticsNeverCarryTheServerPassword() {
    let line = "starting with OPENCODE_SERVER_PASSWORD=abc123secret and Basic YWJjOjEyMw=="
    let redacted = OpenCodeServer.redact(line)
    XCTAssertFalse(redacted.contains("abc123secret"))
    XCTAssertFalse(redacted.contains("YWJjOjEyMw=="))
  }

  func testTimeoutsAreTreatedAsIndeterminateRatherThanFailed() {
    XCTAssertTrue(OpenCodeClient.isIndeterminate(URLError(.timedOut)))
    XCTAssertTrue(OpenCodeClient.isIndeterminate(URLError(.networkConnectionLost)))
    XCTAssertFalse(OpenCodeClient.isIndeterminate(URLError(.badURL)))
  }
}

final class OpenCodeLiveEventShapeTests: XCTestCase {
  private func events(_ json: String) -> [AgentEvent] {
    guard let frame = try? JSONDecoder().decode(
      OpenCodeDTO.EventFrame.self,
      from: Data(json.utf8)
    ) else {
      XCTFail("payload did not decode")
      return []
    }
    return OpenCodeClient.domainEvents(from: frame, resolver: { _ in UUID() })
  }

  func testPromptedEchoesTheUserMessageUnderTheIdWeSent() {
    let mapped = events(
      """
      {"id":"evt_1","type":"session.next.prompted","durable":{"aggregateID":"ses_1","seq":2,\
      "version":1},"data":{"timestamp":1788886921624,"sessionID":"ses_1",\
      "messageID":"msg_ours","prompt":{"text":"Create a file"},"delivery":"steer"}}
      """
    )
    guard case let .messageUpdated(_, message)? = mapped.first else {
      return XCTFail("expected a user message, got \(mapped)")
    }
    XCTAssertEqual(message.id, "msg_ours", "reconciles with the bubble already drawn")
    XCTAssertEqual(message.role, .user)
    XCTAssertEqual(message.plainText, "Create a file")
    XCTAssertTrue(mapped.contains(.executionStateChanged(sessionID: "ses_1", state: .working)))
  }

  func testPromptAdmissionAlsoReconcilesTheUserMessage() {
    let mapped = events(
      """
      {"id":"evt_admitted","type":"session.next.prompt.admitted","data":{
      "timestamp":1789725485359,"sessionID":"ses_1","messageID":"msg_ours",
      "prompt":{"text":"Reply with OK."},"delivery":"normal"}}
      """
    )
    guard case let .messageUpdated(_, message)? = mapped.first else {
      return XCTFail("expected the admitted user message, got \(mapped)")
    }
    XCTAssertEqual(message.id, "msg_ours")
    XCTAssertEqual(message.plainText, "Reply with OK.")
    XCTAssertTrue(mapped.contains(.executionStateChanged(sessionID: "ses_1", state: .working)))
  }

  func testStepFailureEndsThinkingWithTheProviderError() {
    let mapped = events(
      """
      {"id":"evt_failed","type":"session.next.step.failed","data":{
      "timestamp":1789725486073,"sessionID":"ses_1","assistantMessageID":"msg_agent",
      "error":{"type":"unknown","message":"Provider request failed with HTTP 401"}}}
      """
    )
    XCTAssertEqual(
      mapped,
      [
        .sessionFailed(
          sessionID: "ses_1",
          failure: MessageFailure(
            name: "unknown",
            message: "Provider request failed with HTTP 401"
          )
        )
      ],
      "a provider refusal must end the working state instead of leaving the panel thinking"
    )
  }

  func testTextDeltaNamesTheAssistantMessageAndTextID() {
    let mapped = events(
      """
      {"id":"evt_2","type":"session.next.text.delta","data":{"timestamp":1788886925907,\
      "sessionID":"ses_1","assistantMessageID":"msg_a","textID":"txt_1",\
      "delta":"Creating your hello file."}}
      """
    )
    XCTAssertEqual(
      mapped,
      [
        .partDelta(
          sessionID: "ses_1",
          messageID: "msg_a",
          partID: "txt_1",
          kind: .text,
          delta: "Creating your hello file."
        )
      ]
    )
  }

  func testTextEndedReplacesTheAccumulatedDeltasWithTheFinalText() {
    let mapped = events(
      """
      {"id":"evt_3","type":"session.next.text.ended","data":{"sessionID":"ses_1",\
      "assistantMessageID":"msg_a","textID":"txt_1","text":"Creating your hello file."}}
      """
    )
    guard case let .partUpdated(_, _, part)? = mapped.first,
          case let .text(text) = part
    else { return XCTFail("expected a text part, got \(mapped)") }
    XCTAssertEqual(text.id, "txt_1")
    XCTAssertEqual(text.text, "Creating your hello file.")
  }

  func testToolCallAndResultCombineIntoOneActivity() {
    var message = ConversationMessage(id: "msg_a", role: .agent, createdAt: Date())

    let called = events(
      """
      {"id":"evt_4","type":"session.next.tool.called","data":{"sessionID":"ses_1",\
      "assistantMessageID":"msg_a","callID":"call_1","tool":"write",\
      "input":{"content":"Boltty works.\\n","path":"hello.txt"}}}
      """
    )
    guard case let .partUpdated(_, _, callPart)? = called.first else {
      return XCTFail("expected the call, got \(called)")
    }
    message.upsert(callPart)

    let succeeded = events(
      """
      {"id":"evt_5","type":"session.next.tool.success","data":{"sessionID":"ses_1",\
      "assistantMessageID":"msg_a","callID":"call_1","structured":{"operation":"write",\
      "target":"/tmp/work/hello.txt","resource":"hello.txt","existed":false},\
      "content":[{"type":"text","text":"Created file successfully: hello.txt"}],\
      "outputPaths":[]}}
      """
    )
    guard case let .partUpdated(_, _, resultPart)? = succeeded.first else {
      return XCTFail("expected the result, got \(succeeded)")
    }
    message.upsert(resultPart)

    XCTAssertEqual(message.parts.count, 1, "one call is one row, not two")
    guard case let .activity(activity) = message.parts[0] else {
      return XCTFail("expected an activity")
    }
    XCTAssertEqual(activity.state, .completed)
    XCTAssertEqual(
      activity.name,
      "write",
      "the result event does not name the tool, so the name has to survive the merge"
    )
    XCTAssertEqual(activity.summary, "Write hello.txt")
    XCTAssertEqual(activity.files, ["/tmp/work/hello.txt"])
    XCTAssertEqual(activity.detail, "Created file successfully: hello.txt")
  }

  func testAToolCallsStepDoesNotEndTheTurnButAStopDoes() {
    XCTAssertTrue(
      events(
        """
        {"id":"evt_6","type":"session.next.step.ended","data":{"sessionID":"ses_1",\
        "assistantMessageID":"msg_a","finish":"tool-calls"}}
        """
      ).isEmpty,
      "another step is coming; going idle here would drop the spinner mid-task"
    )
    XCTAssertEqual(
      events(
        """
        {"id":"evt_7","type":"session.next.step.ended","data":{"sessionID":"ses_1",\
        "assistantMessageID":"msg_b","finish":"stop"}}
        """
      ),
      [.executionStateChanged(sessionID: "ses_1", state: .idle)],
      "this stream has no session.idle, so step.ended is the only place idle is learned"
    )
  }

  func testReasoningIsMappedSeparatelyFromTheAnswer() {
    let mapped = events(
      """
      {"id":"evt_8","type":"session.next.reasoning.delta","data":{"sessionID":"ses_1",\
      "assistantMessageID":"msg_a","reasoningID":"rs_1","delta":"thinking"}}
      """
    )
    XCTAssertEqual(
      mapped,
      [
        .partDelta(
          sessionID: "ses_1",
          messageID: "msg_a",
          partID: "rs_1",
          kind: .reasoning,
          delta: "thinking"
        )
      ]
    )
  }

  func testBookkeepingEventsAreIgnored() {
    for type in [
      "session.next.tool.input.delta", "session.next.context.updated",
      "session.next.step.started.unknown", "plugin.added"
    ] {
      XCTAssertTrue(
        events(#"{"id":"e","type":"\#(type)","data":{"sessionID":"ses_1"}}"#).isEmpty,
        "\(type) should not reach the transcript"
      )
    }
  }

  // MARK: - Model catalog from the CLI

  func testCLICatalogIsParsedAsProviderSlashModel() {
    let models = OpenCodeMapper.models(fromCLILines: [
      "opencode/big-pickle",
      "google/gemini-2.5-flash",
      "anthropic/claude-opus-5"
    ])

    XCTAssertEqual(models.count, 3)
    XCTAssertEqual(models[0].selection.providerID, "opencode")
    XCTAssertEqual(models[0].selection.modelID, "big-pickle")
    XCTAssertTrue(models[0].isDefault, "the first line is the default, as with the served catalog")
    XCTAssertEqual(models[1].selection.providerID, "google")
    XCTAssertEqual(models[1].selection.modelID, "gemini-2.5-flash")
    XCTAssertFalse(models[1].isDefault)
  }

  func testCLICatalogDropsAnythingThatIsNotAModelID() {
    let models = OpenCodeMapper.models(fromCLILines: [
      "Fetching available models...",
      "",
      "google/gemini-2.5-flash",
      "warning: two/slashes/here",
      "noslash",
      "/leading",
      "trailing/"
    ])

    XCTAssertEqual(models.map(\.selection.modelID), ["gemini-2.5-flash"])
  }
}

final class OpenCodeAllowancesTests: XCTestCase {
  func testAlwaysGoesOutAsOnceAndCoversTheChatsLaterAsks() {
    var allowances = OpenCodeAllowances()
    XCTAssertFalse(allowances.ask("p1", saving: ["bash:rm *"], in: "ses_a"))
    XCTAssertEqual(allowances.decide(.always, requestID: "p1", sessionID: "ses_a"), .once)
    XCTAssertTrue(allowances.ask("p2", saving: ["bash:rm *"], in: "ses_a"), "covered in this chat")
    XCTAssertFalse(allowances.ask("p3", saving: ["bash:rm *"], in: "ses_b"), "not in another")
    XCTAssertFalse(allowances.ask("p4", saving: ["bash:rm *", "bash:git push *"], in: "ses_a"),
                   "a pattern not allowed still asks")
    XCTAssertFalse(allowances.ask("p5", saving: [], in: "ses_a"), "an ask that saves nothing always asks")
    XCTAssertEqual(allowances.decide(.reject, requestID: "p4", sessionID: "ses_a"), .reject)
  }
}
