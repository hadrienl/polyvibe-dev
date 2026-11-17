import Foundation
import Testing

@testable import VibeEndpoints

/// Antigravity's `agy` as a harness of the gateway (#538), from the requests it was seen to send.
@Suite("The gateway between Antigravity and an endpoint")
struct ChatCompletionsHarnessTests {
  static let token = "agy70k"

  /// The shape `agy` 1.5.6 sends with `AGY_LLM_GATEWAY_WIRE_PROTOCOL=openai`, shortened.
  static let agyBody = #"""
    {"model":"qwen_qwen3-coder","stream":true,"stream_options":{"include_usage":true},
     "max_completion_tokens":4096,
     "messages":[
      {"role":"system","content":[{"type":"text","text":"You are Antigravity."}]},
      {"role":"user","content":"<USER_REQUEST>\nread a.txt\n</USER_REQUEST>"},
      {"role":"assistant","content":null,"tool_calls":[
        {"id":"call_1","type":"function","function":{"name":"read_file","arguments":"{\"File\":\"a.txt\"}"}}]},
      {"role":"tool","tool_call_id":"call_1","content":"hello"},
      {"role":"system","content":"A reminder."}
     ],
     "tools":[{"type":"function","function":{"name":"read_file","description":"Read a file.",
       "parameters":{"type":"object","properties":{"File":{"type":"string"}}}}}]}
    """#

  @Test("agy's request reads into the canonical shape")
  func decodes() throws {
    let request = try ChatCompletionsServer.decodeRequest(JSONValue(parsing: Data(Self.agyBody.utf8)))
    #expect(request.model == "qwen_qwen3-coder")
    #expect(request.system == "You are Antigravity.")
    #expect(request.stream)
    #expect(request.maxOutputTokens == 4096)
    #expect(request.tools.map(\.name) == ["read_file"])
    #expect(request.tools.first?.description == "Read a file.")
    #expect(request.messages.map(\.role) == [.user, .assistant, .user, .system])
    #expect(
      request.messages[1].content == [
        .toolCall(id: "call_1", name: "read_file", arguments: #"{"File":"a.txt"}"#)
      ])
    #expect(
      request.messages[2].content == [
        .toolResult(callID: "call_1", content: [.text("hello")], isError: false)
      ])
    #expect(request.messages[3].content == [.text("A reminder.")])
  }

  private func gateway(_ transport: ScriptedTransport, protocol wire: EndpointWireProtocol)
    async throws -> Gateway
  {
    let routes = GatewayRouteTable()
    await routes.register(
      GatewayRoute(
        endpoint: EndpointConfiguration(
          baseURL: try #require(URL(string: "https://llm.example/api/v1")), wireProtocol: wire),
        secret: "sk-secret", model: "qwen/qwen3-coder"),
      token: Self.token)
    return Gateway(
      routes: routes, transport: transport, retryPolicy: GatewayRetryPolicy(maximumAttempts: 1),
      sleep: { _ in })
  }

  private func request(stream: Bool = true) -> GatewayHTTPRequest {
    var body = Self.agyBody
    if !stream { body = body.replacingOccurrences(of: #""stream":true"#, with: #""stream":false"#) }
    return GatewayHTTPRequest(
      method: "POST", path: "/s/\(Self.token)/v1/chat/completions",
      headers: ["authorization": "Bearer \(Self.token)"], body: Data(body.utf8))
  }

  /// The chunks' objects, without `[DONE]`.
  private func chunks(_ writer: RecordingWriter) async -> [JSONValue] {
    await writer.events.compactMap { try? JSONValue(parsing: Data($0.data.utf8)) }
  }

  @Test("A Messages endpoint's stream comes back as Chat Completions chunks agy reads")
  func translatesStream() async throws {
    let upstream = [
      #"{"type":"message_start","message":{"id":"msg_1","model":"up","usage":{"input_tokens":10,"output_tokens":0}}}"#,
      #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
      #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Reading"}}"#,
      #"{"type":"content_block_stop","index":0}"#,
      #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"read_file","input":{}}}"#,
      #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"File\":"}}"#,
      #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\"a.txt\"}"}}"#,
      #"{"type":"content_block_stop","index":1}"#,
      #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":5}}"#,
      #"{"type":"message_stop"}"#,
    ].map { "data: \($0)\n\n" }
    let transport = ScriptedTransport([
      .answer(status: 200, headers: [:], chunks: upstream, thenFail: nil)
    ])
    let writer = RecordingWriter()
    try await gateway(transport, protocol: .messages).handle(request(), writer: writer)

    #expect(await writer.status == 200)
    #expect(await writer.headers["content-type"] == "text/event-stream")
    #expect(await writer.events.last?.data == "[DONE]")
    let chunks = await chunks(writer)
    #expect(chunks.allSatisfy { $0["object"] == "chat.completion.chunk" })
    #expect(chunks.allSatisfy { $0["model"] == "qwen/qwen3-coder" })
    let deltas = chunks.compactMap { $0["choices"]?.arrayValue?.first?["delta"] }
    #expect(deltas.first?["role"] == "assistant")
    #expect(deltas.compactMap { $0["content"]?.stringValue }.joined() == "Reading")
    let calls = deltas.flatMap { $0["tool_calls"]?.arrayValue ?? [] }
    #expect(calls.first?["id"] == "toolu_1")
    #expect(calls.first?["function"]?["name"] == "read_file")
    #expect(calls.allSatisfy { $0["index"] == 0 })
    #expect(
      calls.compactMap { $0["function"]?["arguments"]?.stringValue }.joined()
        == #"{"File":"a.txt"}"#)
    let finish = chunks.compactMap { $0["choices"]?.arrayValue?.first?["finish_reason"]?.stringValue }
    #expect(finish == ["tool_calls"])
    #expect(chunks.last?["usage"]?["prompt_tokens"] == 10)
    #expect(chunks.last?["usage"]?["completion_tokens"] == 5)

    // What the endpoint was asked: agy's conversation, in its protocol, with its model and key.
    let sent = try transport.sentBody(0)
    #expect(transport.requests[0].url.absoluteString == "https://llm.example/api/v1/messages")
    #expect(sent["model"] == "qwen/qwen3-coder")
    #expect(sent["system"] != nil)
    #expect(sent["tools"]?.arrayValue?.first?["name"] == "read_file")
  }

  @Test("A Chat Completions endpoint gets agy's body with its own model, answered byte for byte")
  func passThrough() async throws {
    let upstream = #"data: {"choices":[{"delta":{"content":"Hi"}}]}"# + "\n\ndata: [DONE]\n\n"
    let transport = ScriptedTransport([
      .answer(
        status: 200, headers: ["content-type": "text/event-stream"], chunks: [upstream],
        thenFail: nil)
    ])
    let writer = RecordingWriter()
    try await gateway(transport, protocol: .chatCompletions).handle(request(), writer: writer)
    #expect(String(decoding: await writer.body, as: UTF8.self) == upstream)
    #expect(
      transport.requests[0].url.absoluteString == "https://llm.example/api/v1/chat/completions")
    #expect(transport.requests[0].headers["Authorization"] == "Bearer sk-secret")
    #expect(try transport.sentBody(0)["model"] == "qwen/qwen3-coder")
    #expect(try transport.sentBody(0)["tools"]?.arrayValue?.first?["function"]?["name"] == "read_file")
  }

  @Test("A turn that does not stream gets a whole chat.completion")
  func whole() async throws {
    let transport = ScriptedTransport([
      .answer(
        status: 200, headers: [:],
        chunks: [
          #"{"id":"r","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done"}]}],"status":"completed","usage":{"input_tokens":3,"output_tokens":1}}"#
        ], thenFail: nil)
    ])
    let writer = RecordingWriter()
    try await gateway(transport, protocol: .responses).handle(request(stream: false), writer: writer)
    let json = try #require(await writer.json)
    #expect(json["object"] == "chat.completion")
    #expect(json["choices"]?.arrayValue?.first?["message"]?["content"] == "Done")
    #expect(json["choices"]?.arrayValue?.first?["finish_reason"] == "stop")
    #expect(json["usage"]?["completion_tokens"] == 1)
  }

  @Test("A refused key goes back to agy as an OpenAI error, before any byte")
  func failure() async throws {
    let transport = ScriptedTransport([
      .answer(
        status: 401, headers: [:], chunks: [#"{"error":{"message":"bad key"}}"#], thenFail: nil)
    ])
    let writer = RecordingWriter()
    try await gateway(transport, protocol: .messages).handle(request(), writer: writer)
    #expect(await writer.status == 401)
    #expect(try #require(await writer.json)["error"]?["code"] == "invalid_api_key")
  }

  @Test("An unknown session is refused in agy's protocol")
  func unknownToken() async throws {
    let writer = RecordingWriter()
    let request = GatewayHTTPRequest(
      method: "POST", path: "/s/nope/v1/chat/completions",
      headers: ["authorization": "Bearer nope"], body: Data(Self.agyBody.utf8))
    try await gateway(ScriptedTransport([]), protocol: .messages).handle(request, writer: writer)
    #expect(await writer.status == 401)
    #expect(try #require(await writer.json)["error"]?["message"] != nil)
  }

  @Test("Cut after the first words: an error object and no [DONE]")
  func cutMidStream() async throws {
    let upstream = [
      #"{"type":"message_start","message":{"id":"msg_1","model":"up"}}"#,
      #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
      #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}"#,
    ].map { "data: \($0)\n\n" }
    let transport = ScriptedTransport([
      .answer(
        status: 200, headers: [:], chunks: upstream,
        thenFail: EndpointFailure(kind: .network, message: "lost"))
    ])
    let writer = RecordingWriter()
    try await gateway(transport, protocol: .messages).handle(request(), writer: writer)
    let events = await writer.events
    #expect(!events.contains { $0.data == "[DONE]" })
    #expect(events.last?.data.contains(#""error""#) == true)
  }
}
