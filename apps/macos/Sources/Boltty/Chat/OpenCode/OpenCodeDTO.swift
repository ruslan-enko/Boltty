import Foundation

enum OpenCodeDTO {
  // MARK: - Envelopes

  struct DataEnvelope<T: Decodable>: Decodable {
    let data: T
  }

  struct ListEnvelope<T: Decodable>: Decodable {
    let data: [T]
    var cursor: PageCursor?

    struct PageCursor: Decodable {
      var next: String?
      var previous: String?
    }
  }

  struct HistoryEnvelope: Decodable {
    let data: [EventFrame]
    var hasMore: Bool?
  }

  // MARK: - Sessions

  struct LocationRef: Codable, Equatable {
    var directory: String
    var workspaceID: String?
  }

  struct ModelRef: Codable, Equatable {
    var id: String
    var providerID: String
    var variant: String?
  }

  struct SessionInfo: Decodable {
    let id: String
    var title: String?
    var location: LocationRef?
    var model: ModelRef?
    var agent: String?
  }

  struct CreateSessionRequest: Encodable {
    var id: String?
    var location: LocationRef
    var model: ModelRef?
  }

  struct PromptRequest: Encodable {
    var id: String
    var text: String
    var files: [FileAttachment]?
    var delivery: String?

    struct FileAttachment: Encodable {
      var uri: String
      var name: String?
    }
  }

  // MARK: - Messages

  struct Message: Decodable {
    let id: String
    let type: String
    var time: Time?
    var text: String?
    var files: [FileRef]?
    var content: [ContentPart]?
    var error: ErrorInfo?

    struct Time: Decodable {
      var created: Double?
      var completed: Double?
    }

    struct FileRef: Decodable {
      var uri: String?
      var name: String?
      var mime: String?
    }

    struct ErrorInfo: Decodable {
      var type: String?
      var name: String?
      var message: String?

      var identifier: String { name ?? type ?? "UnknownError" }
    }

    struct ContentPart: Decodable {
      let type: String
      var id: String?
      var text: String?
      var name: String?
      var state: ToolState?
      var time: Time?
    }

    struct ToolState: Decodable {
      var status: String?
      var content: [ToolContent]?
      var outputPaths: [String]?
      var error: ErrorInfo?
      var input: JSONValue?
    }

    struct ToolContent: Decodable {
      var type: String?
      var text: String?
      var path: String?
    }
  }

  // MARK: - Event projections

  struct EventMessage: Decodable {
    let id: String
    let sessionID: String
    let role: String
    var time: Time?
    var error: Message.ErrorInfo?

    struct Time: Decodable {
      var created: Double?
      var completed: Double?
    }
  }

  struct EventPart: Decodable {
    let id: String
    let sessionID: String
    let messageID: String
    let type: String
    var text: String?
    var tool: String?
    var callID: String?
    var state: EventToolState?
    var filename: String?
    var url: String?
    var mime: String?
  }

  struct EventToolState: Decodable {
    var status: String?
    var title: String?
    var output: String?
    var error: StringOrObject?
    var input: JSONValue?
    var attachments: [EventPart]?
  }

  struct StringOrObject: Decodable {
    let text: String?

    init(from decoder: Decoder) throws {
      let container = try decoder.singleValueContainer()
      if let value = try? container.decode(String.self) {
        text = value
      } else if let value = try? container.decode(JSONValue.self) {
        text = value["message"]?.stringValue ?? value["error"]?.stringValue
      } else {
        text = nil
      }
    }
  }

  // MARK: - Questions and permissions

  struct FormRequest: Decodable {
    let id: String
    let sessionID: String
    var title: String
    var fields: [Field]

    struct Field: Decodable, Equatable, Sendable {
      let key: String
      let type: String
      var title: String?
      var description: String?
      var options: [Option]?
      var custom: Bool?
      var minItems: Int?
      var maxItems: Int?
      var placeholder: String?
      var url: String?
    }

    struct Option: Decodable, Equatable, Sendable {
      var value: String
      var label: String
      var description: String?
    }
  }

  struct FormReplyRequest: Encodable {
    var answer: [String: FormValue]
  }

  /// Typed per field: a string field refuses an array (FormInvalidAnswerError).
  enum FormValue: Encodable, Equatable, Sendable {
    case text(String)
    case selections([String])
    case flag(Bool)
    case number(Double)

    func encode(to encoder: Encoder) throws {
      var container = encoder.singleValueContainer()
      switch self {
      case let .text(value): try container.encode(value)
      case let .selections(values): try container.encode(values)
      case let .flag(value): try container.encode(value)
      case let .number(value): try container.encode(value)
      }
    }
  }

  struct QuestionRequest: Decodable {
    let id: String
    let sessionID: String
    var questions: [QuestionInfo]
    var tool: ToolRef?

    struct QuestionInfo: Decodable {
      var question: String
      var header: String
      var options: [Option]
      var multiple: Bool?
      var custom: Bool?
    }

    struct Option: Decodable {
      var label: String
      var description: String?
    }

    struct ToolRef: Decodable {
      var messageID: String?
      var callID: String?
    }
  }

  struct PermissionRequest: Decodable {
    let id: String
    let sessionID: String
    var action: String
    var resources: [String]
    var save: [String]?
    var source: Source?

    struct Source: Decodable {
      var type: String?
      var messageID: String?
      var callID: String?
    }
  }

  struct QuestionReplyRequest: Encodable {
    var answers: [[String]]
  }

  struct PermissionReplyRequest: Encodable {
    var decision: String
    var message: String?
  }

  struct LegacyPermissionReplyRequest: Encodable {
    var reply: String
    var message: String?
  }

  // MARK: - Models

  struct ModelInfo: Decodable {
    let id: String
    let providerID: String
    var name: String?
  }

  // MARK: - Events

  struct EventFrame: Decodable {
    let id: String?
    let type: String
    var durable: Durable?
    var location: LocationRef?
    var data: JSONValue?

    struct Durable: Decodable {
      var aggregateID: String?
      var seq: Int?
      var version: Int?
    }
  }
}

indirect enum JSONValue: Decodable, Equatable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case object([String: JSONValue])
  case array([JSONValue])
  case null

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else if let value = try? container.decode([String: JSONValue].self) {
      self = .object(value)
    } else {
      self = .null
    }
  }

  subscript(key: String) -> JSONValue? {
    guard case let .object(dictionary) = self else { return nil }
    return dictionary[key]
  }

  var stringValue: String? {
    if case let .string(value) = self { return value }
    return nil
  }

  var doubleValue: Double? {
    if case let .number(value) = self { return value }
    return nil
  }

  var intValue: Int? {
    if case let .number(value) = self { return Int(value) }
    return nil
  }

  var boolValue: Bool? {
    if case let .bool(value) = self { return value }
    return nil
  }

  var arrayValue: [JSONValue]? {
    if case let .array(value) = self { return value }
    return nil
  }

  var objectValue: [String: JSONValue]? {
    if case let .object(value) = self { return value }
    return nil
  }

  func decode<T: Decodable>(as type: T.Type) -> T? {
    guard let data = try? JSONEncoder().encode(self) else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
  }
}

extension JSONValue: Encodable {
  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case let .string(value): try container.encode(value)
    case let .number(value): try container.encode(value)
    case let .bool(value): try container.encode(value)
    case let .object(value): try container.encode(value)
    case let .array(value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }
}

struct OpenCodeStatsDTO: Decodable {
  struct Stats: Decodable {
    struct Day: Decodable {
      var date: String?
      var steps: Double?
    }
    var activity: [Day]?
    var streak: Int?
    var sessions: Int?
    var prompts: Int?
  }
  var data: Stats?
}
