import Foundation

enum AgentPlan {
  static let codexToolName = "update_plan"
  static let activityName = "plan"

  static func activity(id: String, steps: [PlanStep], at date: Date = Date()) -> AgentActivity {
    let done = steps.filter { $0.status == .completed }.count
    return AgentActivity(
      id: id,
      name: activityName,
      summary: "Plan · \(done) of \(steps.count) done",
      state: done == steps.count ? .completed : .running,
      startedAt: date,
      plan: steps
    )
  }

  static func codexLive(_ params: JSONObject) -> [PlanStep] {
    params.array("plan").compactMap { step in
      guard let text = step.string("step"), !text.isEmpty else { return nil }
      return PlanStep(text: text, status: status(step.string("status")))
    }
  }

  static func codexArguments(_ arguments: String?) -> [PlanStep] {
    guard let arguments, let object = JSONObject(line: arguments) else { return [] }
    return codexLive(object)
  }

  static func status(_ raw: String?) -> PlanStep.Status {
    switch raw {
    case "completed": .completed
    case "inProgress", "in_progress": .inProgress
    default: .pending
    }
  }

  static func fold(_ messages: [ConversationMessage]) -> [ConversationMessage] {
    var result = messages
    var first: (message: Int, part: Int)?
    for index in result.indices {
      if result[index].role == .user {
        first = nil
        continue
      }
      var kept: [ConversationPart] = []
      for part in result[index].parts {
        guard case let .activity(row) = part, row.plan != nil else {
          kept.append(part)
          continue
        }
        if let first {
          if first.message == index {
            kept[first.part] = .activity(retitled(row, as: kept[first.part].id))
          } else {
            result[first.message].parts[first.part] = .activity(
              retitled(row, as: result[first.message].parts[first.part].id))
          }
        } else {
          first = (index, kept.count)
          kept.append(part)
        }
      }
      result[index].parts = kept
    }
    return result
  }

  private static func retitled(_ row: AgentActivity, as id: String) -> AgentActivity {
    activity(id: id, steps: row.plan ?? [], at: row.startedAt ?? Date())
  }
}
