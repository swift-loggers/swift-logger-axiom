import Testing

@testable import LoggerAxiom

/// Structural coverage for ``AxiomLogger/MinimumLevel``: the nested
/// threshold enum locks the cross-adapter rule that a thresholded
/// logger exposes exactly the seven `LoggerLevel` severities and
/// cannot accept `LoggerLevel.disabled` as a threshold value.
@Suite("AxiomLogger.MinimumLevel")
struct AxiomLoggerMinimumLevelTests {
    @Test(
        "MinimumLevel exposes exactly the seven LoggerLevel severities and is CaseIterable + Sendable",
        .tags(.axm33)
    )
    func minimumLevelEnumExposesSevenSeverities() {
        let allCases = AxiomLogger.MinimumLevel.allCases
        #expect(allCases.count == 7)
        let expected = Set([
            "trace", "debug", "info", "notice", "warning", "error", "critical"
        ])
        let rawValues = Set(allCases.map(\.rawValue))
        #expect(rawValues == expected)
        #expect(!rawValues.contains("disabled"))
    }
}
