import Foundation

/// Internal helper that frames a batch of host-encoded event payload
/// bytes into the wire shape Axiom's HTTP ingest API expects: a
/// single JSON array whose elements are the host-side event values
/// in input order.
///
/// The helper does **no event encoding itself**; it only frames bytes
/// the host-side encoder produced. Each input element is a single
/// JSON value (object, array, quoted string, number, ...) that
/// becomes one element of the framed array:
///
///     [<event_1>,<event_2>,...,<event_n>]
///
/// Bytes must be a valid JSON value. JSON tolerates inter-token
/// whitespace (including `0x0A` newlines) outside JSON string escapes,
/// so newline-free JSON is recommended for hosts but not required by
/// the framing helper. `JSONSerialization.data(withJSONObject:)`
/// produces newline-free JSON by default.
enum AxiomIngestRequestBody {
    /// Builds the framed Axiom ingest request body for `events`.
    ///
    /// Layout:
    ///
    ///     [<event_1>,<event_2>,...,<event_n>]
    ///
    /// No envelope is wrapped around each event; Axiom's ingest API
    /// reads each array element as a top-level event document.
    ///
    /// Capacity is reserved exactly when every per-event byte sum
    /// fits inside `Int`; the helper falls back to the `Data` default
    /// growth strategy on overflow so a pathological caller cannot
    /// trap the process inside `reserveCapacity`. The returned bytes
    /// are identical regardless of which path the reservation takes.
    ///
    /// - Parameter events: Ordered host-encoded event payload bytes.
    ///   Each element MUST be a valid JSON value; the helper does not
    ///   validate the bytes. An empty `events` array returns an empty
    ///   `Data` so the caller can skip the HTTP dispatch entirely.
    /// - Returns: The framed Axiom ingest request body bytes.
    static func make(events: [Data]) -> Data {
        guard !events.isEmpty else {
            return Data()
        }
        var body = Data()
        if let capacity = reservedTotalCapacity(events: events) {
            body.reserveCapacity(capacity)
        }
        body.append(openingBracket)
        var first = true
        for event in events {
            if first {
                first = false
            } else {
                body.append(comma)
            }
            body.append(event)
        }
        body.append(closingBracket)
        return body
    }

    /// `[` byte prepended to the body.
    private static let openingBracket = Data([0x5B])
    /// `]` byte appended to the body.
    private static let closingBracket = Data([0x5D])
    /// `,` byte appended between consecutive events.
    private static let comma = Data([0x2C])

    /// Computes the exact `Int` capacity needed for the framed body,
    /// or `nil` when the per-event arithmetic overflows `Int`. Every
    /// intermediate sum is checked through `addingReportingOverflow`
    /// so a pathological caller (event payload byte counts that sum
    /// past `Int.max`) cannot reach `reserveCapacity` with a wrapped
    /// value or trap the process.
    ///
    /// - Parameter events: Ordered host-encoded event payload bytes.
    ///   The helper expects a non-empty array; an empty array short-
    ///   circuits in ``make(events:)`` before this helper runs.
    /// - Returns: The exact body byte count when every sum fits in
    ///   `Int`, otherwise `nil` so the caller can skip
    ///   `reserveCapacity` entirely and let `Data` grow under its
    ///   default strategy.
    private static func reservedTotalCapacity(events: [Data]) -> Int? {
        // `[` + `]` framing bytes.
        var total = openingBracket.count + closingBracket.count
        // (events.count - 1) commas between elements.
        let (separatorTotal, separatorOverflow) = (events.count - 1)
            .multipliedReportingOverflow(by: comma.count)
        if separatorOverflow {
            return nil
        }
        let (afterSeparators, separatorAddOverflow) = total
            .addingReportingOverflow(separatorTotal)
        if separatorAddOverflow {
            return nil
        }
        total = afterSeparators
        for event in events {
            let (next, overflow) = total.addingReportingOverflow(event.count)
            if overflow {
                return nil
            }
            total = next
        }
        return total
    }
}
