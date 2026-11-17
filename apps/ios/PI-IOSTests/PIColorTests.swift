import XCTest
import SwiftUI
import UIKit
import Foundation
@testable import PI_IOS

final class PIColorTests: XCTestCase {
    private struct RGBA {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double

        init(red: Double, green: Double, blue: Double, alpha: Double) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }

        init(hex: UInt32, alpha: Double = 1) {
            self.init(
                red: Double((hex >> 16) & 0xFF) / 255,
                green: Double((hex >> 8) & 0xFF) / 255,
                blue: Double(hex & 0xFF) / 255,
                alpha: alpha
            )
        }
    }

    private struct TokenExpectation {
        let name: String
        let color: Color
        let light: RGBA
        let dark: RGBA
        let highLight: RGBA?
        let highDark: RGBA?

        init(
            name: String,
            color: Color,
            lightHex: UInt32,
            darkHex: UInt32,
            lightAlpha: Double = 1,
            darkAlpha: Double = 1,
            highLight: RGBA? = nil,
            highDark: RGBA? = nil
        ) {
            self.name = name
            self.color = color
            self.light = RGBA(hex: lightHex, alpha: lightAlpha)
            self.dark = RGBA(hex: darkHex, alpha: darkAlpha)
            self.highLight = highLight
            self.highDark = highDark
        }
    }

    private struct TestVariant {
        let name: String
        let style: UIUserInterfaceStyle
        let contrast: UIAccessibilityContrast
    }

    private let colorAccuracy = 0.0001

    private var variants: [TestVariant] {
        [
            TestVariant(name: "light/normal", style: .light, contrast: .normal),
            TestVariant(name: "light/high", style: .light, contrast: .high),
            TestVariant(name: "dark/normal", style: .dark, contrast: .normal),
            TestVariant(name: "dark/high", style: .dark, contrast: .high)
        ]
    }

    private var tokenExpectations: [TokenExpectation] {
        [
            TokenExpectation(name: "page", color: PIColor.page, lightHex: 0xF4F6F9, darkHex: 0x0F141B),
            TokenExpectation(name: "surface", color: PIColor.surface, lightHex: 0xFFFFFF, darkHex: 0x171E27),
            TokenExpectation(name: "surface2", color: PIColor.surface2, lightHex: 0xEDF1F5, darkHex: 0x202936),
            TokenExpectation(name: "surface3", color: PIColor.surface3, lightHex: 0xE3E9F0, darkHex: 0x2B3542),
            TokenExpectation(
                name: "separator", color: PIColor.separator,
                lightHex: 0xD9E0E8, darkHex: 0x303B49,
                highLight: RGBA(hex: 0xB4C0CE), highDark: RGBA(hex: 0x536377)
            ),
            TokenExpectation(
                name: "separatorStrong", color: PIColor.separatorStrong,
                lightHex: 0x748295, darkHex: 0x899AAF,
                highLight: RGBA(hex: 0x5E6B7C), highDark: RGBA(hex: 0xA7B7CA)
            ),
            TokenExpectation(name: "text", color: PIColor.text, lightHex: 0x18202B, darkHex: 0xF0F3F7),
            TokenExpectation(
                name: "text2", color: PIColor.text2,
                lightHex: 0x4B5667, darkHex: 0xB4BECB,
                highLight: RGBA(hex: 0x323C49), highDark: RGBA(hex: 0xD5DCE5)
            ),
            TokenExpectation(
                name: "text3", color: PIColor.text3,
                lightHex: 0x5F6B7A, darkHex: 0x96A3B4,
                highLight: RGBA(hex: 0x465160), highDark: RGBA(hex: 0xC0CAD6)
            ),
            TokenExpectation(name: "accent", color: PIColor.accent, lightHex: 0x315FD5, darkHex: 0x9DB8FF),
            TokenExpectation(name: "onAccent", color: PIColor.onAccent, lightHex: 0xFFFFFF, darkHex: 0x101623),
            TokenExpectation(name: "accentSoft", color: PIColor.accentSoft, lightHex: 0xE8EEFC, darkHex: 0x223454),
            TokenExpectation(name: "danger", color: PIColor.danger, lightHex: 0xA92835, darkHex: 0xFF918B),
            TokenExpectation(name: "warning", color: PIColor.warning, lightHex: 0x754500, darkHex: 0xE7B96A),
            TokenExpectation(name: "success", color: PIColor.success, lightHex: 0x146344, darkHex: 0x72C9A5),
            TokenExpectation(name: "dangerSoft", color: PIColor.dangerSoft, lightHex: 0xFCECEF, darkHex: 0x3B2329),
            TokenExpectation(name: "warningSoft", color: PIColor.warningSoft, lightHex: 0xFAF0DC, darkHex: 0x382E1E),
            TokenExpectation(name: "successSoft", color: PIColor.successSoft, lightHex: 0xE7F3ED, darkHex: 0x1D352D),
            TokenExpectation(
                name: "scrim", color: PIColor.scrim,
                lightHex: 0x000000, darkHex: 0x000000, lightAlpha: 0.36, darkAlpha: 0.52
            ),
            TokenExpectation(
                name: "floatingShadow", color: PIColor.floatingShadow,
                lightHex: 0x101923, darkHex: 0x000000, lightAlpha: 0.10, darkAlpha: 0.28
            ),
            TokenExpectation(
                name: "cardShadow", color: PIColor.cardShadow,
                lightHex: 0x000000, darkHex: 0x000000, lightAlpha: 0, darkAlpha: 0
            )
        ]
    }

    func testAllColorTokensResolveExactlyInEveryVariant() {
        for expectation in tokenExpectations {
            for variant in variants {
                let expected: RGBA
                if variant.contrast == .high {
                    expected = variant.style == .dark
                        ? expectation.highDark ?? expectation.dark
                        : expectation.highLight ?? expectation.light
                } else {
                    expected = variant.style == .dark ? expectation.dark : expectation.light
                }
                assertColor(
                    expectation.color,
                    equals: expected,
                    traits: makeTraits(variant),
                    label: "\(expectation.name) [\(variant.name)]"
                )
            }
        }
    }

    func testAliasesMatchTheirCanonicalTokensInEveryVariant() {
        let aliases: [(String, Color, String, Color)] = [
            ("bg", PIColor.bg, "page", PIColor.page),
            ("accentBright", PIColor.accentBright, "accent", PIColor.accent),
            ("accentBorder", PIColor.accentBorder, "accent", PIColor.accent)
        ]
        for variant in variants {
            let traits = makeTraits(variant)
            for (aliasName, alias, canonicalName, canonical) in aliases {
                assertSameColor(
                    alias, firstTraits: traits,
                    canonical, secondTraits: traits,
                    label: "\(aliasName) == \(canonicalName) [\(variant.name)]"
                )
            }
        }
    }

    func testUnchangedTokensFallBackToNormalContrastColors() {
        let unchanged: [(String, Color)] = [
            ("page", PIColor.page), ("surface", PIColor.surface),
            ("surface2", PIColor.surface2), ("surface3", PIColor.surface3),
            ("text", PIColor.text), ("accent", PIColor.accent),
            ("onAccent", PIColor.onAccent), ("accentSoft", PIColor.accentSoft),
            ("danger", PIColor.danger), ("warning", PIColor.warning),
            ("success", PIColor.success), ("dangerSoft", PIColor.dangerSoft),
            ("warningSoft", PIColor.warningSoft), ("successSoft", PIColor.successSoft),
            ("scrim", PIColor.scrim), ("floatingShadow", PIColor.floatingShadow),
            ("cardShadow", PIColor.cardShadow), ("bg", PIColor.bg),
            ("accentBright", PIColor.accentBright), ("accentBorder", PIColor.accentBorder)
        ]
        for style in [UIUserInterfaceStyle.light, .dark] {
            let normal = makeTraits(TestVariant(name: "normal", style: style, contrast: .normal))
            let high = makeTraits(TestVariant(name: "high", style: style, contrast: .high))
            for (name, color) in unchanged {
                assertSameColor(
                    color, firstTraits: normal,
                    color, secondTraits: high,
                    label: "\(name) normal fallback [style=\(style.rawValue)]"
                )
            }
        }
    }

    func testNormalTextContrastMeetsFourPointFiveToOne() {
        let foregrounds: [(String, Color)] = [
            ("text", PIColor.text), ("text2", PIColor.text2), ("text3", PIColor.text3),
            ("accent", PIColor.accent), ("danger", PIColor.danger),
            ("warning", PIColor.warning), ("success", PIColor.success)
        ]
        let backgrounds: [(String, Color)] = [
            ("page", PIColor.page), ("surface", PIColor.surface), ("surface2", PIColor.surface2)
        ]
        let softPairs: [(String, Color, String, Color)] = [
            ("accent", PIColor.accent, "accentSoft", PIColor.accentSoft),
            ("danger", PIColor.danger, "dangerSoft", PIColor.dangerSoft),
            ("warning", PIColor.warning, "warningSoft", PIColor.warningSoft),
            ("success", PIColor.success, "successSoft", PIColor.successSoft)
        ]
        for variant in variants {
            let traits = makeTraits(variant)
            for (foregroundName, foreground) in foregrounds {
                for (backgroundName, background) in backgrounds {
                    assertContrast(
                        foreground, background, traits: traits, minimum: 4.5,
                        label: "\(foregroundName)/\(backgroundName) [\(variant.name)]"
                    )
                }
            }
            assertContrast(
                PIColor.text, PIColor.surface3, traits: traits, minimum: 4.5,
                label: "text/surface3 [\(variant.name)]"
            )
            assertContrast(
                PIColor.onAccent, PIColor.accent, traits: traits, minimum: 4.5,
                label: "onAccent/accent [\(variant.name)]"
            )
            for (foregroundName, foreground, backgroundName, background) in softPairs {
                assertContrast(
                    foreground, background, traits: traits, minimum: 4.5,
                    label: "\(foregroundName)/\(backgroundName) [\(variant.name)]"
                )
            }
        }
    }

    func testRequiredNonTextContrastMeetsThreeToOne() {
        let backgrounds: [(String, Color)] = [
            ("page", PIColor.page), ("surface", PIColor.surface),
            ("surface2", PIColor.surface2), ("surface3", PIColor.surface3)
        ]
        for variant in variants {
            let traits = makeTraits(variant)
            for (backgroundName, background) in backgrounds {
                assertContrast(
                    PIColor.separatorStrong, background,
                    traits: traits, minimum: 3.0,
                    label: "separatorStrong/\(backgroundName) [\(variant.name)]"
                )
            }
            assertContrast(
                PIColor.accentBorder, PIColor.accentSoft,
                traits: traits, minimum: 3.0,
                label: "accentBorder/accentSoft [\(variant.name)]"
            )
        }
    }

    private func makeTraits(_ variant: TestVariant) -> UITraitCollection {
        UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: variant.style),
            UITraitCollection(accessibilityContrast: variant.contrast)
        ])
    }

    private func resolvedRGBA(
        _ color: Color,
        traits: UITraitCollection,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> RGBA? {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        let resolved = UIColor(color).resolvedColor(with: traits)
        guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            XCTFail("\(label): unable to extract sRGB components", file: file, line: line)
            return nil
        }
        return RGBA(red: Double(red), green: Double(green), blue: Double(blue), alpha: Double(alpha))
    }

    private func assertColor(
        _ color: Color,
        equals expected: RGBA,
        traits: UITraitCollection,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actual = resolvedRGBA(color, traits: traits, label: label, file: file, line: line) else { return }
        assertRGBA(actual, equals: expected, label: label, file: file, line: line)
    }

    private func assertSameColor(
        _ first: Color,
        firstTraits: UITraitCollection,
        _ second: Color,
        secondTraits: UITraitCollection,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let firstRGBA = resolvedRGBA(first, traits: firstTraits, label: label, file: file, line: line),
              let secondRGBA = resolvedRGBA(second, traits: secondTraits, label: label, file: file, line: line) else { return }
        assertRGBA(firstRGBA, equals: secondRGBA, label: label, file: file, line: line)
    }

    private func assertRGBA(
        _ actual: RGBA,
        equals expected: RGBA,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.red, expected.red, accuracy: colorAccuracy, "\(label): red", file: file, line: line)
        XCTAssertEqual(actual.green, expected.green, accuracy: colorAccuracy, "\(label): green", file: file, line: line)
        XCTAssertEqual(actual.blue, expected.blue, accuracy: colorAccuracy, "\(label): blue", file: file, line: line)
        XCTAssertEqual(actual.alpha, expected.alpha, accuracy: colorAccuracy, "\(label): alpha", file: file, line: line)
    }

    private func assertContrast(
        _ foreground: Color,
        _ background: Color,
        traits: UITraitCollection,
        minimum: Double,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let foregroundRGBA = resolvedRGBA(foreground, traits: traits, label: label, file: file, line: line),
              let backgroundRGBA = resolvedRGBA(background, traits: traits, label: label, file: file, line: line) else { return }
        guard abs(foregroundRGBA.alpha - 1) <= colorAccuracy,
              abs(backgroundRGBA.alpha - 1) <= colorAccuracy else {
            XCTFail("\(label): contrast tokens must be opaque; no alpha compositing is applied", file: file, line: line)
            return
        }
        let foregroundLuminance = relativeLuminance(foregroundRGBA)
        let backgroundLuminance = relativeLuminance(backgroundRGBA)
        let lighter = max(foregroundLuminance, backgroundLuminance)
        let darker = min(foregroundLuminance, backgroundLuminance)
        let ratio = (lighter + 0.05) / (darker + 0.05)
        XCTAssertGreaterThanOrEqual(
            ratio, minimum,
            "\(label): contrast \(ratio) is below \(minimum):1",
            file: file, line: line
        )
    }

    private func relativeLuminance(_ color: RGBA) -> Double {
        func linearized(_ component: Double) -> Double {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearized(color.red)
            + 0.7152 * linearized(color.green)
            + 0.0722 * linearized(color.blue)
    }
}
