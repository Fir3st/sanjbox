import Foundation

/// Native Messages SSE, constrained to one text block. All client-visible
/// fields are reconstructed; no upstream headers, IDs, errors or extensions pass.
struct ModelAPIStream {
    private enum Phase { case initial, message, block, afterBlock, delta, stopped }
    private var phase = Phase.initial
    private let model: String
    private let maximumTokens: Int
    private let key: Data
    private let configuration: ModelAPIConfiguration
    private let localID = "msg_sanjbox_" + UUID().uuidString.lowercased()
    private var pending = Data()
    private var events = 0
    private var outputBytes = 0
    private var lastOutputTokens = 0

    init(request: ModelAPIRequest, key: ModelAPITestKey, configuration: ModelAPIConfiguration) {
        model = request.model; maximumTokens = request.maximumTokens
        self.key = Data(key.value.utf8); self.configuration = configuration
    }

    mutating func accept(_ event: SSEEvent) throws -> [SSEEvent] {
        try Task.checkCancellation()
        events += 1
        guard events <= configuration.maximumEvents, phase != .stopped, event.id == nil else { throw ModelAPIFailure.limit }
        let value = try ModelJSON.parse(Data(event.data.utf8), maximumBytes: 16_384)
        try rejectEcho(value)
        guard let object = value.object, let type = object["type"]?.string, event.event == type else { throw ModelAPIFailure.schema }
        var output: [SSEEvent] = []
        switch type {
        case "ping":
            _ = try modelObject(value, required: ["type"])
        case "message_start":
            guard phase == .initial else { throw ModelAPIFailure.schema }
            _ = try modelObject(value, required: ["type", "message"])
            let message = try modelObject(object["message"], required: ["id", "type", "role", "model", "content", "stop_reason", "stop_sequence", "usage"])
            guard let id = message["id"]?.string, id.utf8.count <= 256,
                  message["type"] == .string("message"), message["role"] == .string("assistant"),
                  message["model"] == .string(model), message["content"] == .array([]),
                  message["stop_reason"] == .null, message["stop_sequence"] == .null else { throw ModelAPIFailure.schema }
            let usage = try modelObject(message["usage"], required: ["input_tokens", "output_tokens"], optional: ["cache_creation_input_tokens", "cache_read_input_tokens"])
            guard let input = usage["input_tokens"]?.integer, input <= 1_000_000,
                  let count = usage["output_tokens"]?.integer, count <= maximumTokens else { throw ModelAPIFailure.limit }
            for field in ["cache_creation_input_tokens", "cache_read_input_tokens"] {
                if let value = usage[field], value.integer != 0 { throw ModelAPIFailure.schema }
            }
            lastOutputTokens = count; phase = .message
            output.append(try make(type, ["message": .object([
                "id": .string(localID), "type": .string("message"), "role": .string("assistant"),
                "model": .string(model), "content": .array([]), "stop_reason": .null, "stop_sequence": .null,
                "usage": .object(["input_tokens": .int(input), "output_tokens": .int(count)])])]))
        case "content_block_start":
            guard phase == .message else { throw ModelAPIFailure.schema }
            _ = try modelObject(value, required: ["type", "index", "content_block"])
            let block = try modelObject(object["content_block"], required: ["type", "text"])
            guard object["index"]?.integer == 0, block["type"] == .string("text"), block["text"] == .string("") else { throw ModelAPIFailure.schema }
            phase = .block
            output.append(try make(type, ["index": .int(0), "content_block": .object(["type": .string("text"), "text": .string("")])]))
        case "content_block_delta":
            guard phase == .block else { throw ModelAPIFailure.schema }
            _ = try modelObject(value, required: ["type", "index", "delta"])
            let delta = try modelObject(object["delta"], required: ["type", "text"])
            guard object["index"]?.integer == 0, delta["type"] == .string("text_delta"), let text = delta["text"]?.string else { throw ModelAPIFailure.schema }
            pending.append(Data(text.utf8))
            guard pending.range(of: key) == nil else { throw ModelAPIFailure.secretEcho }
            // Retain enough bytes to detect an exact key split across arbitrary
            // event/TCP boundaries. Do not cut in the middle of UTF-8 scalars.
            var release = max(0, pending.count - (key.count - 1))
            while release > 0, release < pending.count, pending[pending.startIndex + release] & 0xc0 == 0x80 { release -= 1 }
            if release > 0 {
                guard let text = String(data: pending.prefix(release), encoding: .utf8) else { throw ModelAPIFailure.schema }
                pending = Data(pending.dropFirst(release))
                output.append(try textEvent(text))
            }
        case "content_block_stop":
            guard phase == .block else { throw ModelAPIFailure.schema }
            _ = try modelObject(value, required: ["type", "index"])
            guard object["index"]?.integer == 0 else { throw ModelAPIFailure.schema }
            if !pending.isEmpty {
                guard let text = String(data: pending, encoding: .utf8) else { throw ModelAPIFailure.schema }
                output.append(try textEvent(text)); pending.removeAll()
            }
            phase = .afterBlock
            output.append(try make(type, ["index": .int(0)]))
        case "message_delta":
            guard phase == .afterBlock else { throw ModelAPIFailure.schema }
            _ = try modelObject(value, required: ["type", "delta", "usage"])
            let delta = try modelObject(object["delta"], required: ["stop_reason", "stop_sequence"])
            let usage = try modelObject(object["usage"], required: ["output_tokens"])
            guard let reason = delta["stop_reason"]?.string, ["end_turn", "max_tokens"].contains(reason),
                  delta["stop_sequence"] == .null, let count = usage["output_tokens"]?.integer,
                  (lastOutputTokens...maximumTokens).contains(count) else { throw ModelAPIFailure.schema }
            phase = .delta
            output.append(try make(type, ["delta": .object(["stop_reason": .string(reason), "stop_sequence": .null]),
                                         "usage": .object(["output_tokens": .int(count)])]))
        case "message_stop":
            guard phase == .delta else { throw ModelAPIFailure.schema }
            _ = try modelObject(value, required: ["type"])
            phase = .stopped // withheld until D1 confirms complete HTTP framing
        default: throw ModelAPIFailure.upstream // includes error, tools, thinking, unknown extensions
        }
        return output
    }

    mutating func finish() throws -> SSEEvent {
        guard phase == .stopped, pending.isEmpty else { throw ModelAPIFailure.upstream }
        return try make("message_stop", [:])
    }

    private func rejectEcho(_ value: ModelJSON) throws {
        switch value {
        case .string(let text):
            if Data(text.utf8).range(of: key) != nil { throw ModelAPIFailure.secretEcho }
        case .object(let values):
            for (name, value) in values { try rejectEcho(.string(name)); try rejectEcho(value) }
        case .array(let values): for value in values { try rejectEcho(value) }
        default: break
        }
    }
    private mutating func textEvent(_ text: String) throws -> SSEEvent {
        try make("content_block_delta", ["index": .int(0), "delta": .object(["type": .string("text_delta"), "text": .string(text)])])
    }
    private mutating func make(_ type: String, _ fields: [String: ModelJSON]) throws -> SSEEvent {
        var fields = fields; fields["type"] = .string(type)
        let data = try ModelJSON.object(fields).encoded()
        let event = SSEEvent(data: String(decoding: data, as: UTF8.self), event: type)
        let size = try event.encoded().count
        guard size <= configuration.maximumOutputBytes - outputBytes else { throw ModelAPIFailure.limit }
        outputBytes += size
        return event
    }
}
