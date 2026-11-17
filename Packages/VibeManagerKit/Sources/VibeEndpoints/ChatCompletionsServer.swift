import Foundation

/// The OpenAI Chat Completions protocol as a harness speaks it to the gateway (#538).
///
/// Antigravity's `agy` reaches an "enterprise model gateway" this way when told
/// `AGY_LLM_GATEWAY_WIRE_PROTOCOL=openai`: a streamed `POST v1/chat/completions` with
/// `stream_options.include_usage`, a system message first, `function` tools, assistant
/// `tool_calls` and `tool` results. The reader is the mirror of `ChatCompletionsClient`.
///
/// What is dropped: `reasoning_content` coming back (it belongs to the model that wrote it), audio,
/// `n`, `logprobs`, `response_format` and the sampling parameters other than the temperature.
public enum ChatCompletionsServer {
  public static func decodeRequest(_ body: JSONValue) throws -> CanonicalRequest {
    guard let model = body["model"]?.stringValue else {
      throw EndpointProtocolError.missingField("model")
    }
    guard let items = body["messages"]?.arrayValue else {
      throw EndpointProtocolError.missingField("messages")
    }
    var system: [String] = []
    var messages: [CanonicalMessage] = []
    func add(_ role: CanonicalMessage.Role, _ block: CanonicalBlock) {
      if let last = messages.last, last.role == role {
        messages[messages.count - 1].content.append(block)
      } else {
        messages.append(CanonicalMessage(role: role, content: [block]))
      }
    }
    for item in items {
      switch item["role"]?.stringValue {
      case "system", "developer":
        let text = Self.text(item["content"])
        guard !text.isEmpty else { continue }
        // The instructions before the conversation are its system prompt; later ones are kept in
        // place, as the harness put them.
        if messages.isEmpty {
          system.append(text)
        } else {
          add(.system, .text(text))
        }
      case "assistant":
        if case .array(let parts) = item["content"] {
          for part in parts where ["text", "output_text"].contains(part["type"]?.stringValue) {
            if let text = part["text"]?.stringValue, !text.isEmpty { add(.assistant, .text(text)) }
          }
        } else if let text = item["content"]?.stringValue, !text.isEmpty {
          add(.assistant, .text(text))
        }
        for call in item["tool_calls"]?.arrayValue ?? [] {
          guard let id = call["id"]?.stringValue, let name = call["function"]?["name"]?.stringValue
          else { throw EndpointProtocolError.invalidField("tool_calls") }
          add(
            .assistant,
            .toolCall(
              id: id, name: name, arguments: call["function"]?["arguments"]?.stringValue ?? "{}"))
        }
      case "tool":
        guard let callID = item["tool_call_id"]?.stringValue else {
          throw EndpointProtocolError.invalidField("tool_call_id")
        }
        add(.user, .toolResult(callID: callID, content: result(item["content"]), isError: false))
      default:
        for block in content(item["content"]) { add(.user, block) }
      }
    }
    var tools: [CanonicalTool] = []
    for tool in body["tools"]?.arrayValue ?? [] where tool["type"]?.stringValue == "function" {
      guard let function = tool["function"], let name = function["name"]?.stringValue else {
        continue
      }
      tools.append(
        CanonicalTool(
          name: name, description: function["description"]?.stringValue,
          inputSchema: function["parameters"] ?? ["type": "object", "properties": [:]]))
    }
    return CanonicalRequest(
      model: model,
      system: system.isEmpty ? nil : system.joined(separator: "\n\n"),
      messages: messages,
      tools: tools,
      toolChoice: toolChoice(body["tool_choice"]),
      maxOutputTokens: body["max_completion_tokens"]?.intValue ?? body["max_tokens"]?.intValue,
      temperature: body["temperature"]?.numberValue,
      stream: body["stream"]?.boolValue ?? false)
  }

  private static func toolChoice(_ value: JSONValue?) -> CanonicalToolChoice {
    switch value {
    case .string("none"): return .none
    case .string("required"): return .required
    case .object:
      return value?["function"]?["name"]?.stringValue.map(CanonicalToolChoice.tool) ?? .auto
    default: return .auto
    }
  }

  /// The text of a content that may be a string or parts.
  private static func text(_ value: JSONValue?) -> String {
    switch value {
    case .string(let text): return text
    case .array(let parts):
      return parts.compactMap { $0["text"]?.stringValue }.joined(separator: "\n\n")
    default: return ""
    }
  }

  private static func content(_ value: JSONValue?) -> [CanonicalBlock] {
    switch value {
    case .string(let text):
      return [.text(text)]
    case .array(let parts):
      return parts.compactMap { part in
        switch part["type"]?.stringValue {
        case "text":
          return .text(part["text"]?.stringValue ?? "")
        case "image_url":
          return image(part).map { .image(mediaType: $0.mediaType, base64: $0.base64) }
        default:
          return nil
        }
      }
    default:
      return []
    }
  }

  private static func result(_ value: JSONValue?) -> [CanonicalResultPart] {
    content(value).compactMap { block in
      switch block {
      case .text(let text): return .text(text)
      case .image(let mediaType, let base64): return .image(mediaType: mediaType, base64: base64)
      default: return nil
      }
    }
  }

  /// Only inline images: a URL would make the gateway fetch it, which no harness expects of it.
  private static func image(_ part: JSONValue) -> (mediaType: String, base64: String)? {
    let url = part["image_url"]?["url"]?.stringValue ?? part["image_url"]?.stringValue
    return url.flatMap(ResponsesServer.dataURL)
  }

  // MARK: - Answers

  static func usage(_ usage: CanonicalUsage?) -> JSONValue {
    let usage = usage ?? CanonicalUsage()
    let prompt = usage.inputTokens + usage.cacheReadTokens + usage.cacheWriteTokens
    return [
      "prompt_tokens": .number(Double(prompt)),
      "completion_tokens": .number(Double(usage.outputTokens)),
      "total_tokens": .number(Double(prompt + usage.outputTokens)),
      "prompt_tokens_details": ["cached_tokens": .number(Double(usage.cacheReadTokens))],
      "completion_tokens_details": ["reasoning_tokens": .number(Double(usage.reasoningTokens))],
    ]
  }

  static func finishReason(_ reason: CanonicalStopReason) -> String {
    switch reason {
    case .endTurn, .stopSequence: return "stop"
    case .toolUse: return "tool_calls"
    case .maxTokens: return "length"
    case .refusal: return "content_filter"
    }
  }

  /// A whole answer, for a request that did not stream.
  public static func encodeResponse(_ answer: CanonicalResponse, created: Int) -> JSONValue {
    var text = ""
    var reasoning = ""
    var calls: [JSONValue] = []
    for block in answer.content {
      switch block {
      case .text(let part): text += part
      case .reasoning(let part, _): reasoning += part
      case .toolCall(let id, let name, let arguments):
        calls.append(
          [
            "id": .string(id), "type": "function",
            "function": ["name": .string(name), "arguments": .string(arguments)],
          ])
      case .image, .toolResult:
        continue
      }
    }
    var message: [String: JSONValue] = [
      "role": "assistant", "content": text.isEmpty && !calls.isEmpty ? .null : .string(text),
    ]
    if !reasoning.isEmpty { message["reasoning_content"] = .string(reasoning) }
    if !calls.isEmpty { message["tool_calls"] = .array(calls) }
    return [
      "id": .string(answer.id), "object": "chat.completion", "created": .number(Double(created)),
      "model": .string(answer.model),
      "choices": [
        [
          "index": 0, "message": .object(message),
          "finish_reason": .string(finishReason(answer.stopReason)),
        ]
      ],
      "usage": usage(answer.usage),
    ]
  }

  /// The OpenAI error shape, the same as the Responses protocol's.
  public static func errorBody(_ failure: EndpointFailure) -> JSONValue {
    ResponsesServer.errorBody(failure)
  }

  public static func status(for failure: EndpointFailure) -> Int {
    ResponsesServer.status(for: failure)
  }
}

/// Writes canonical events as the Chat Completions stream a harness reads: `chat.completion.chunk`
/// objects, the finish reason, the usage in a last chunk without choices, then `[DONE]`.
public struct ChatCompletionsStreamEncoder: Sendable {
  private let id: String
  private let model: String
  private let created: Int
  private var started = false
  /// Canonical block index → index among the tool calls, which the protocol numbers apart.
  private var toolIndices: [Int: Int] = [:]
  private var usage: CanonicalUsage?
  private var stopReason: CanonicalStopReason?
  private var sawToolCall = false

  public init(id: String, model: String, created: Int = Int(Date().timeIntervalSince1970)) {
    self.id = id
    self.model = model
    self.created = created
  }

  public mutating func encode(_ event: CanonicalStreamEvent) -> [ServerSentEvent] {
    var out: [ServerSentEvent] = []
    if !started {
      started = true
      out.append(chunk(delta: ["role": "assistant", "content": ""]))
    }
    switch event {
    case .start, .textStart, .reasoningStart, .reasoningSignature, .blockStop, .serverStep:
      break
    case .textDelta(_, let text):
      out.append(chunk(delta: ["content": .string(text)]))
    case .reasoningDelta(_, let text):
      out.append(chunk(delta: ["reasoning_content": .string(text)]))
    case .toolCallStart(let index, let callID, let name):
      let position = toolIndices.count
      toolIndices[index] = position
      sawToolCall = true
      out.append(
        chunk(delta: [
          "tool_calls": [
            [
              "index": .number(Double(position)), "id": .string(callID), "type": "function",
              "function": ["name": .string(name), "arguments": ""],
            ]
          ]
        ]))
    case .toolCallArgumentsDelta(let index, let fragment):
      guard let position = toolIndices[index], !fragment.isEmpty else { break }
      out.append(
        chunk(delta: [
          "tool_calls": [
            ["index": .number(Double(position)), "function": ["arguments": .string(fragment)]]
          ]
        ]))
    case .usage(let usage):
      self.usage = usage
    case .stop(let reason):
      stopReason = reason
    }
    return out
  }

  public mutating func finish() -> [ServerSentEvent] {
    var out: [ServerSentEvent] = []
    if !started {
      started = true
      out.append(chunk(delta: ["role": "assistant", "content": ""]))
    }
    let reason = stopReason ?? (sawToolCall ? .toolUse : .endTurn)
    out.append(
      chunk(delta: [:], finishReason: ChatCompletionsServer.finishReason(reason)))
    out.append(
      ServerSentEvent(
        data: JSONValue.object([
          "id": .string(id), "object": "chat.completion.chunk",
          "created": .number(Double(created)), "model": .string(model), "choices": [],
          "usage": ChatCompletionsServer.usage(usage),
        ]).text()))
    out.append(ServerSentEvent(data: "[DONE]"))
    return out
  }

  /// An error after part of the answer went out: an `error` object in the stream, as OpenAI
  /// sends one, and no `[DONE]`, so the harness does not take the partial answer as whole.
  public mutating func fail(_ failure: EndpointFailure) -> [ServerSentEvent] {
    [ServerSentEvent(data: ChatCompletionsServer.errorBody(failure).text())]
  }

  private func chunk(delta: [String: JSONValue], finishReason: String? = nil) -> ServerSentEvent {
    let choice: JSONValue = [
      "index": 0, "delta": .object(delta),
      "finish_reason": finishReason.map(JSONValue.string) ?? .null,
    ]
    return ServerSentEvent(
      data: JSONValue.object([
        "id": .string(id), "object": "chat.completion.chunk", "created": .number(Double(created)),
        "model": .string(model), "choices": [choice],
      ]).text())
  }
}
