//
//  ServerSentEvents.swift
//  VoltaSDK
//
//  Minimal parser for the Server-Sent Events wire format, shared by the three
//  cloud providers' streaming paths (D16). Feed it lines as delivered by
//  `URLSession.AsyncBytes.lines` (already stripped of newlines); it emits one
//  event per blank-line dispatch, per the SSE spec: `data:` lines accumulate
//  (joined with \n), an optional `event:` line names the event, `:` comment
//  lines and unknown fields are ignored.
//

struct ServerSentEvent: Equatable {
    var event: String?
    var data: String
}

struct SSEParser {
    private var eventName: String?
    private var dataLines: [String] = []

    /// Consumes one line; returns a completed event when the line is the
    /// blank dispatch line and data was accumulated, `nil` otherwise.
    mutating func consume(_ line: String) -> ServerSentEvent? {
        if line.isEmpty {
            defer {
                eventName = nil
                dataLines = []
            }
            guard !dataLines.isEmpty else { return nil }
            return ServerSentEvent(event: eventName, data: dataLines.joined(separator: "\n"))
        }
        if line.hasPrefix(":") { return nil }
        if let value = value(of: "data", in: line) {
            dataLines.append(value)
        } else if let value = value(of: "event", in: line) {
            eventName = value
        }
        return nil
    }

    private func value(of field: String, in line: String) -> String? {
        guard line.hasPrefix(field) else { return nil }
        var rest = line.dropFirst(field.count)
        guard rest.first == ":" else { return nil }
        rest = rest.dropFirst()
        if rest.first == " " { rest = rest.dropFirst() }
        return String(rest)
    }
}
