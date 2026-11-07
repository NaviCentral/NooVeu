import Foundation
import Testing
@testable import NooVeuBench

/// `--enforce` is only worth having if its verdicts are right: these pin the rules.
@Suite("Benchmark enforcement")
struct EnforcementTests {
    private func target(measured: Double?, budget: Double = 100, knownMiss: String? = nil, ceiling: Double? = nil) -> TargetResult {
        TargetResult(name: "t", budget: budget, unit: "ms", measured: measured, basis: "", knownMiss: knownMiss, knownMissCeiling: ceiling)
    }

    @Test func aTargetWithinBudgetPasses() {
        #expect(!target(measured: 99).failsEnforcement)
        #expect(!target(measured: 100).failsEnforcement, "exactly the budget is a pass")
    }

    @Test func aTargetOverBudgetFails() {
        #expect(target(measured: 100.1).failsEnforcement)
    }

    @Test func aTargetThatCouldNotBeMeasuredFails() {
        #expect(target(measured: nil).failsEnforcement)
    }

    @Test func anInvalidMeasurementFails() {
        #expect(target(measured: .nan).failsEnforcement)
        #expect(target(measured: .infinity).failsEnforcement)
    }

    @Test func aKnownMissIsToleratedOnlyUpToItsCeiling() {
        #expect(!target(measured: 150, knownMiss: "slow format", ceiling: 300).failsEnforcement)
        #expect(!target(measured: 300, knownMiss: "slow format", ceiling: 300).failsEnforcement)
        #expect(target(measured: 301, knownMiss: "slow format", ceiling: 300).failsEnforcement, "it must not get worse unnoticed")
    }

    @Test func aKnownMissWithoutACeilingIsNotTolerated() {
        #expect(target(measured: 150, knownMiss: "slow format", ceiling: nil).failsEnforcement)
    }

    @Test func aKnownMissThatNowPassesStillPasses() {
        #expect(!target(measured: 50, knownMiss: "slow format", ceiling: 300).failsEnforcement)
    }

    @Test func aUnmeasuredKnownMissStillFails() {
        #expect(target(measured: nil, knownMiss: "slow format", ceiling: 300).failsEnforcement)
    }
}
