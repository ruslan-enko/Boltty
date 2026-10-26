import Foundation

enum BolttyAIAnnouncement {
  static func forTransition(
    from previous: BolttyAISessionPreview?,
    to current: BolttyAISessionPreview
  ) -> String? {
    guard previous?.id == current.id else { return nil }
    guard previous?.state != current.state || previous?.question != current.question else {
      return nil
    }

    if current.question != nil, previous?.question == nil {
      return "Waiting for your answer. " + current.question!.prompt
    }
    switch current.state {
    case .failed:
      return AgentFailureReport.universalSentence
    case .finished:
      let opening = firstSentence(of: current.displayBody)
      return opening.isEmpty ? "Answer ready." : "Answer ready. " + opening
    case .running, .blocked, .none:
      return nil
    }
  }

  static func firstSentence(of body: String, limit: Int = 180) -> String {
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    var first: String?
    (trimmed as NSString).enumerateSubstrings(
      in: NSRange(location: 0, length: (trimmed as NSString).length),
      options: [.bySentences, .substringNotRequired]
    ) { _, range, _, stop in
      first = (trimmed as NSString).substring(with: range)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      stop.pointee = true
    }
    let sentence = first ?? trimmed
    guard sentence.count > limit else { return sentence }
    return String(sentence.prefix(limit)) + "…"
  }
}
