import Testing
@testable import NooVeuCore

@Suite("UpgradePolicy")
struct UpgradePolicyTests {
    // A 12240 px source shown from a 3060 px texture (1/4 size): sharp up to 0.25 zoom.
    private func decide(texture: Int = 3060, source: Int = 12240, zoom: Double, custom: Bool = true) -> Bool {
        UpgradePolicy.shouldUpgrade(textureLongestSide: texture, sourceLongestSide: source,
                                    zoom: zoom, isCustomZoom: custom)
    }

    @Test func staysOnTheSmallTextureWhileItIsStillSharp() {
        #expect(!decide(zoom: 0.2))
        #expect(!decide(zoom: 0.26))  // within 5% of the texture's own resolution
    }

    @Test func upgradesOnceZoomExceedsWhatTheTextureCanShow() {
        #expect(decide(zoom: 0.3))
        #expect(decide(zoom: 1))
    }

    @Test func aFittedViewNeverUpgrades() {
        #expect(!decide(zoom: 1, custom: false))
    }

    @Test func neverUpgradesWhenThereIsNothingSharper() {
        #expect(!decide(texture: 12240, source: 12240, zoom: 4), "already full size")
        // A 20000 px source decodes to at most 16384 whatever is requested, so asking again
        // would loop forever.
        #expect(!decide(texture: 16384, source: 20000, zoom: 1))
    }
}
