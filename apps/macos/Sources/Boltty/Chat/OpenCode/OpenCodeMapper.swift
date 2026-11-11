import Foundation

enum OpenCodeMapper {
  // MARK: - Messages

  static func message(from dto: OpenCodeDTO.Message) -> ConversationMessage? {
    switch dto.type {
    case "user":
      var message = ConversationMessage(
        id: dto.id,
        role: .user,
        createdAt: date(dto.time?.created),
        completedAt: date(dto.time?.created)
      )
      if let text = dto.text, !text.isEmpty {
        message.parts.append(.text(TextPart(id: "\(dto.id)-text", kind: .text, text: text)))
      }
      for (index, file) in (dto.files ?? []).enumerated() {
        message.parts.append(
          .attachment(
            ConversationAttachment(
              id: "\(dto.id)-file-\(index)",
              displayName: file.name ?? (file.uri.map { ($0 as NSString).lastPathComponent }
                ?? "Attachment"),
              url: file.uri.flatMap(URL.init(string:)),
              mimeType: file.mime
            )
          )
        )
      }
      return message

    case "assistant":
      var message = ConversationMessage(
        id: dto.id,
        role: .agent,
        createdAt: date(dto.time?.created),
        completedAt: dto.time?.completed.map { Date(timeIntervalSince1970: $0 / 1000) }
      )
      message.parts = (dto.content ?? []).enumerated().compactMap { index, content in
        part(fromContent: content, in: dto.id, at: index)
      }
      if let error = dto.error {
        message.failure = MessageFailure(
          name: error.identifier,
          message: error.message ?? error.identifier
        )
      }
      return message

    default:
      return nil
    }
  }

  private static func part(
    fromContent content: OpenCodeDTO.Message.ContentPart,
    in messageID: String,
    at index: Int
  ) -> ConversationPart? {
    let partID = content.id ?? "\(messageID)#\(content.type)-\(index)"
    switch content.type {
    case "text":
      guard let text = content.text else { return nil }
      return .text(TextPart(id: partID, kind: .text, text: text))
    case "reasoning":
      guard let text = content.text, !text.isEmpty else { return nil }
      return .reasoning(TextPart(id: partID, kind: .reasoning, text: text))
    case "tool":
      let state = content.state
      let outputs = state?.content?.compactMap(\.text).joined(separator: "\n")
      return .activity(
        AgentActivity(
          id: partID,
          name: content.name ?? "tool",
          summary: nil,
          state: activityState(state?.status, errorType: state?.error?.type),
          detail: (isInterruption(state?.error?.type) ? nil : state?.error?.message)
            ?? (outputs?.isEmpty == false ? outputs : nil),
          files: state?.outputPaths ?? [],
          startedAt: date(content.time?.created),
          endedAt: content.time?.completed.map { Date(timeIntervalSince1970: $0 / 1000) }
        )
      )
    default:
      return nil
    }
  }

  static func part(fromEvent dto: OpenCodeDTO.EventPart) -> ConversationPart? {
    switch dto.type {
    case "text":
      guard let text = dto.text else { return nil }
      return .text(TextPart(id: dto.id, kind: .text, text: text))
    case "reasoning":
      guard let text = dto.text, !text.isEmpty else { return nil }
      return .reasoning(TextPart(id: dto.id, kind: .reasoning, text: text))
    case "tool":
      let state = dto.state
      return .activity(
        AgentActivity(
          id: dto.id,
          name: dto.tool ?? "tool",
          summary: state?.title,
          state: activityState(state?.status, errorType: state?.error?.type),
          detail: (isInterruption(state?.error?.type) ? nil : state?.error?.text) ?? state?.output,
          files: filePaths(from: state)
        )
      )
    case "file":
      return .attachment(
        ConversationAttachment(
          id: dto.id,
          displayName: dto.filename ?? "Attachment",
          url: dto.url.flatMap(URL.init(string:)),
          mimeType: dto.mime
        )
      )
    default:
      return nil
    }
  }

  static func message(fromEvent dto: OpenCodeDTO.EventMessage) -> ConversationMessage {
    var message = ConversationMessage(
      id: dto.id,
      role: dto.role == "user" ? .user : .agent,
      createdAt: date(dto.time?.created),
      completedAt: dto.time?.completed.map { Date(timeIntervalSince1970: $0 / 1000) }
    )
    if let error = dto.error {
      message.failure = MessageFailure(
        name: error.identifier,
        message: error.message ?? error.identifier
      )
    }
    return message
  }

  private static func filePaths(from state: OpenCodeDTO.EventToolState?) -> [String] {
    guard let state else { return [] }
    var paths: [String] = []
    for key in ["filePath", "path", "file"] {
      if let value = state.input?[key]?.stringValue { paths.append(value) }
    }
    for attachment in state.attachments ?? [] {
      if let name = attachment.filename { paths.append(name) }
    }
    return Array(Set(paths)).sorted()
  }

  /// A tool cut off with its turn did not fail: the turn's own "Stopped" says it,
  /// so its line ("Tool execution interrupted") is not shown as an error.
  static func isInterruption(_ errorType: String?) -> Bool { errorType == "aborted" }

  private static func activityState(_ status: String?, errorType: String?) -> AgentActivity.State {
    switch status {
    case "running": return .running
    case "completed": return .completed
    case "error": return isInterruption(errorType) ? .interrupted : .failed
    default: return .pending
    }
  }

  private static func date(_ milliseconds: Double?) -> Date {
    guard let milliseconds else { return Date() }
    return Date(timeIntervalSince1970: milliseconds / 1000)
  }

  // MARK: - Interactions

  static func interaction(
    from dto: OpenCodeDTO.QuestionRequest,
    conversationID: UUID
  ) -> PendingInteraction {
    PendingInteraction(
      id: dto.id,
      conversationID: conversationID,
      remoteSessionID: dto.sessionID,
      kind: .question(
        QuestionPrompt(
          items: dto.questions.map { item in
            QuestionItem(
              header: item.header,
              question: item.question,
              choices: item.options.map {
                AgentChoice(value: $0.label, label: $0.label, detail: $0.description)
              },
              allowsMultiple: item.multiple ?? false,
              allowsCustom: item.custom ?? false
            )
          },
          toolCallID: dto.tool?.callID
        )
      )
    )
  }

  static func interaction(
    from dto: OpenCodeDTO.FormRequest,
    conversationID: UUID
  ) -> PendingInteraction {
    PendingInteraction(
      id: dto.id,
      conversationID: conversationID,
      remoteSessionID: dto.sessionID,
      kind: .question(
        QuestionPrompt(
          items: dto.fields.map { questionItem(for: $0, in: dto) },
          toolCallID: nil
        )
      )
    )
  }

  private static func questionItem(
    for field: OpenCodeDTO.FormRequest.Field,
    in form: OpenCodeDTO.FormRequest
  ) -> QuestionItem {
    let question = field.description ?? field.title ?? form.title
    let header = field.description == nil ? form.title : (field.title ?? form.title)
    switch field.type {
    case "boolean":
      return QuestionItem(
        key: field.key, header: header, question: question,
        choices: [
          AgentChoice(value: "true", label: "Yes"),
          AgentChoice(value: "false", label: "No"),
        ],
        allowsMultiple: false, allowsCustom: false
      )
    case "external":
      return QuestionItem(
        key: field.key, header: header,
        question: [question, field.url].compactMap { $0 }.joined(separator: "\n\n"),
        choices: [AgentChoice(value: "true", label: "Done")],
        allowsMultiple: false, allowsCustom: false
      )
    default:
      let options = field.options ?? []
      return QuestionItem(
        key: field.key, header: header, question: question,
        choices: options.map {
          AgentChoice(value: $0.value, label: $0.label, detail: $0.description)
        },
        allowsMultiple: field.type == "multiselect",
        allowsCustom: options.isEmpty || field.custom == true
      )
    }
  }

  static func interaction(
    from dto: OpenCodeDTO.PermissionRequest,
    conversationID: UUID
  ) -> PendingInteraction {
    PendingInteraction(
      id: dto.id,
      conversationID: conversationID,
      remoteSessionID: dto.sessionID,
      kind: .permission(
        PermissionPrompt(
          action: dto.action,
          resources: dto.resources,
          savePatterns: dto.save ?? [],
          toolCallID: dto.source?.callID
        )
      )
    )
  }

  // MARK: - Session state

  static func executionState(fromStatus status: JSONValue?) -> ConversationExecutionState? {
    switch status?["type"]?.stringValue {
    case "idle": return .idle
    case "busy", "retry": return .working
    default: return nil
    }
  }

  static func failure(fromError error: JSONValue?) -> MessageFailure {
    let name = error?["name"]?.stringValue
      ?? error?["type"]?.stringValue
      ?? "UnknownError"
    let message = error?["data"]?["message"]?.stringValue
      ?? error?["message"]?.stringValue
      ?? name
    return unwrapProviderEnvelope(MessageFailure(name: name, message: message))
  }

  private static func unwrapProviderEnvelope(_ failure: MessageFailure) -> MessageFailure {
    guard let start = failure.message.firstIndex(of: "{"),
          let inner = try? JSONSerialization.jsonObject(
            with: Data(failure.message[start...].utf8)
          ) as? [String: Any]
    else { return failure }
    let payload = (inner["error"] as? [String: Any]) ?? inner
    guard let innerMessage = (payload["message"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !innerMessage.isEmpty
    else { return failure }
    let innerName = (payload["name"] as? String) ?? (payload["type"] as? String)
    return MessageFailure(
      name: innerName.map { $0 == "error" ? failure.name : $0 } ?? failure.name,
      message: innerMessage
    )
  }

  static func models(fromCLILines lines: [String]) -> [AgentModelOption] {
    lines.enumerated().compactMap { index, line in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard !trimmed.contains(" ") else { return nil }
      let fields = trimmed.split(separator: "/", omittingEmptySubsequences: false)
      guard fields.count == 2, !fields[0].isEmpty, !fields[1].isEmpty else { return nil }
      return model(
        from: OpenCodeDTO.ModelInfo(
          id: String(fields[1]),
          providerID: String(fields[0]),
          name: nil
        ),
        isDefault: index == 0
      )
    }
  }

  static func efforts(from variants: JSONValue?) -> [AgentEffortOption] {
    (variants?.arrayValue ?? []).compactMap { variant in
      guard let id = variant["id"]?.stringValue, !id.isEmpty else { return nil }
      return AgentEffortOption(value: id, label: id == "none" ? "None" : nil)
    }
  }

  static func model(from dto: OpenCodeDTO.ModelInfo, isDefault: Bool) -> AgentModelOption {
    AgentModelOption(
      selection: ModelSelection(
        providerID: dto.providerID,
        modelID: dto.id,
        displayName: dto.name ?? dto.id
      ),
      isDefault: isDefault
    )
  }
}

// MARK: - Plan limits

extension OpenCodeMapper {
  /// `/api/experimental/usage/limits` (2.2.6): OpenCode Go's meters and the
  /// Console's budgets, `data: null` until OpenCode is signed in to the Console.
  /// The free models' line comes from the database (`OpenCodeFreeUsage`).
  static func usage(
    limits: JSONValue?,
    free: OpenCodeFreeUsage?,
    now: Date = Date()
  ) -> AgentUsage {
    var windows: [AgentUsageWindow] = []
    var notes: [String] = []
    let data = limits?["data"]

    func date(_ value: JSONValue?) -> Date? {
      value?.doubleValue.map { Date(timeIntervalSince1970: $0 / 1_000) }
    }

    if let go = data?["go"] {
      let meters: [(String, AgentUsageWindow.Kind)] = [
        ("rolling", .named("Rolling", order: 0)),
        ("weekly", .weekly),
        ("monthly", .named("Monthly", order: 3)),
      ]
      for (key, kind) in meters {
        guard let meter = go[key], let percent = meter["percent"]?.doubleValue else { continue }
        let used = meter["limited"]?.boolValue == true ? 100 : Int(percent.rounded())
        windows.append(AgentUsageWindow(kind: kind, usedPercent: used, resetsAt: date(meter["resetsAt"]), label: "Go"))
      }
    }
    for budget in data?["budgets"]?.arrayValue ?? [] {
      guard let limit = budget["limit"]?.doubleValue, limit > 0,
            let spent = budget["spent"]?.doubleValue
      else { continue }
      windows.append(AgentUsageWindow(
        kind: .named("\(dollars(spent)) of \(dollars(limit))", order: 4),
        usedPercent: Int((spent / limit * 100).rounded()),
        resetsAt: date(budget["resetsAt"]),
        label: "Console"
      ))
    }

    if let free {
      if let backAt = free.backAt, backAt > now {
        windows.append(AgentUsageWindow(
          kind: .named("Daily", order: 1), usedPercent: 100, resetsAt: backAt, label: "Free models"))
      } else if free.steps > 0 {
        notes.append("Free models: \(free.steps) \(free.steps == 1 ? "step" : "steps") since \(clock(free.since)). OpenCode does not say how many a day allows.")
      }
    }
    if windows.isEmpty, data == nil || data == .null {
      notes.append("Go and Console limits show once OpenCode is signed in to its Console.")
    }
    return AgentUsage(windows: windows, notes: notes)
  }

  private static func dollars(_ amount: Double) -> String {
    amount == amount.rounded() ? "$\(Int(amount))" : String(format: "$%.2f", amount)
  }

  private static func clock(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("jmm")
    return formatter.string(from: date)
  }
}
