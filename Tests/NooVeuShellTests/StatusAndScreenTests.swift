import CoreGraphics
import NooVeuCore
import Testing
@testable import NooVeuShell

@Suite("SubtitleFormatter")
struct SubtitleFormatterTests {
    private let shown = ShownImageInfo(sourceSize: PixelSize(width: 6000, height: 4000),
                                       textureSize: PixelSize(width: 3000, height: 2000),
                                       decodeDuration: .milliseconds(27), uploadDuration: .milliseconds(5))

    @Test func anImageShowsItsPositionSizeZoomAndTimings() {
        let text = SubtitleFormatter.text(position: (3, 120), shown: shown, zoom: 0.256, error: nil)

        #expect(text == "3 / 120  ·  6000×4000  ·  26%  ·  decode 27 ms, upload 5 ms")
    }

    @Test func withoutAnImageTheErrorIsShownInstead() {
        #expect(SubtitleFormatter.text(position: nil, shown: nil, zoom: 1, error: "Can't open this file") == "Can't open this file")
        #expect(SubtitleFormatter.text(position: (2, 5), shown: nil, zoom: 1, error: "Can't open this file")
                == "2 / 5  ·  Can't open this file")
    }

    @Test func anImageHidesAnOldError() {
        let text = SubtitleFormatter.text(position: nil, shown: shown, zoom: 1, error: "Can't open this file")

        #expect(!text.contains("Can't"))
    }

    @Test func nothingToSayIsEmpty() {
        #expect(SubtitleFormatter.text(position: nil, shown: nil, zoom: 1, error: nil) == "")
    }

    @Test func zoomIsAWholePercent() {
        #expect(SubtitleFormatter.text(position: nil, shown: shown, zoom: 1, error: nil).contains("100%"))
        #expect(SubtitleFormatter.text(position: nil, shown: shown, zoom: 0.004, error: nil).contains(" 0%"))
        #expect(SubtitleFormatter.text(position: nil, shown: shown, zoom: 64, error: nil).contains("6400%"))
    }
}

@Suite("ScreenMath")
struct ScreenMathTests {
    @Test func theLongestSideIsInPixels() {
        #expect(ScreenMath.longestSide(of: CGSize(width: 1728, height: 1117), scale: 2) == 3456)
        #expect(ScreenMath.longestSide(of: CGSize(width: 1117, height: 1728), scale: 2) == 3456, "portrait")
        #expect(ScreenMath.longestSide(of: CGSize(width: 2560, height: 1440), scale: 1) == 2560)
    }

    @Test func noUsableDisplayGivesTheFallback() {
        #expect(ScreenMath.longestSide(of: nil, scale: 2) == 3840)
        #expect(ScreenMath.longestSide(of: CGSize(width: 0, height: 0), scale: 2) == 3840)
        #expect(ScreenMath.longestSide(of: CGSize(width: 100, height: 100), scale: 0) == 3840)
        #expect(ScreenMath.longestSide(of: nil, scale: 2, fallback: 1234) == 1234)
    }
}

@Suite("ProbeSettings")
struct ProbeSettingsTests {
    @Test func theProbeIsOnForAnyRealValue() {
        #expect(ProbeSettings.isEnabled("1"))
        #expect(ProbeSettings.isEnabled("yes"))
    }

    @Test func unsetEmptyOrZeroMeansOff() {
        #expect(!ProbeSettings.isEnabled(nil))
        #expect(!ProbeSettings.isEnabled(""))
        #expect(!ProbeSettings.isEnabled("0"))
    }

    @Test func theSettleTimeFallsBackOnNonsense() {
        #expect(ProbeSettings.settleSeconds("0.5") == 0.5)
        #expect(ProbeSettings.settleSeconds("0") == 0)
        #expect(ProbeSettings.settleSeconds(nil) == 3)
        #expect(ProbeSettings.settleSeconds("soon") == 3)
        #expect(ProbeSettings.settleSeconds("-2") == 3)
        #expect(ProbeSettings.settleSeconds("inf") == 3)
        #expect(ProbeSettings.settleSeconds(nil, default: 9) == 9)
    }
}
