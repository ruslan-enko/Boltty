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
          state: activityState(state?.status),
          detail: state?.error?.message ?? (outputs?.isEmpty == false ? outputs : nil),
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
          state: activityState(state?.status),
          detail: state?.error?.text ?? state?.output,
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

  private static func activityState(_ status: String?) -> AgentActivity.State {
    switch status {
    case "running": return .running
    case "completed": return .completed
    case "error": return .failed
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
