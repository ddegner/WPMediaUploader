import Foundation
import XCTest
@testable import WordpressMediaUploaderApp

final class AvifPluginSettingsTests: XCTestCase {

    // MARK: - Option-fetch expression

    func testOptionFetchExpressionQueriesEveryOptionWithPluginDefaults() {
        let expression = AvifPluginSettings.optionFetchExpression

        XCTAssertTrue(expression.hasPrefix("echo json_encode(array("))
        XCTAssertTrue(expression.contains("\"quality\"=>(int)get_option(\"aviflosu_quality\",85)"))
        XCTAssertTrue(expression.contains("\"speed\"=>(int)get_option(\"aviflosu_speed\",6)"))
        XCTAssertTrue(expression.contains("\"subsampling\"=>(string)get_option(\"aviflosu_subsampling\",\"420\")"))
        XCTAssertTrue(expression.contains("\"bit_depth\"=>(string)get_option(\"aviflosu_bit_depth\",\"8\")"))
    }

    func testOptionFetchExpressionAvoidsSingleQuotes() {
        // The expression travels through two layers of single-quote shell
        // wrapping (wp eval + bash -lc); keeping it apostrophe-free means it
        // never depends on nested quote escaping.
        XCTAssertFalse(AvifPluginSettings.optionFetchExpression.contains("'"))
    }

    func testOptionFetchExpressionDefaultsMatchTypeDefaults() {
        // The PHP fallbacks and the Swift defaults must describe the same
        // configuration, or a failed option read would silently change output.
        let defaults = AvifPluginSettings()
        let expression = AvifPluginSettings.optionFetchExpression
        XCTAssertTrue(expression.contains("aviflosu_quality\",\(defaults.quality)"))
        XCTAssertTrue(expression.contains("aviflosu_speed\",\(defaults.speed)"))
        XCTAssertTrue(expression.contains("aviflosu_subsampling\",\"\(defaults.chroma)\""))
        XCTAssertTrue(expression.contains("aviflosu_bit_depth\",\"\(defaults.bitDepth)\""))
    }

    // MARK: - Parsing

    func testParseReadsAllFieldsFromCleanJSON() {
        let parsed = AvifPluginSettings.parse(
            from: #"{"quality":70,"speed":3,"subsampling":"444","bit_depth":"12"}"#
        )
        XCTAssertEqual(parsed, AvifPluginSettings(quality: 70, speed: 3, chroma: "444", bitDepth: 12))
    }

    func testParseRecoversJSONWrappedInPHPNoise() {
        let raw = """
        PHP Notice: Undefined index in /var/www/html/wp-content/plugins/thing.php on line 12
        Warning: session already started
        {"quality":90,"speed":8,"subsampling":"422","bit_depth":"10"}
        Deprecated: trailing noise
        """
        let parsed = AvifPluginSettings.parse(from: raw)
        XCTAssertEqual(parsed, AvifPluginSettings(quality: 90, speed: 8, chroma: "422", bitDepth: 10))
    }

    func testParseKeepsDefaultsForOutOfRangeValues() {
        let parsed = AvifPluginSettings.parse(
            from: #"{"quality":101,"speed":11,"subsampling":"421","bit_depth":"9"}"#
        )
        XCTAssertEqual(parsed, AvifPluginSettings())
    }

    func testParseKeepsDefaultsForMistypedValues() {
        // The plugin stores subsampling/bit_depth as strings; numbers or
        // string-typed integers in the wrong slot must not be accepted.
        let parsed = AvifPluginSettings.parse(
            from: #"{"quality":"80","speed":"4","subsampling":420,"bit_depth":10}"#
        )
        XCTAssertEqual(parsed, AvifPluginSettings())
    }

    func testParseKeepsDefaultsWhenNoJSONPresent() {
        XCTAssertEqual(AvifPluginSettings.parse(from: "command not found: wp"), AvifPluginSettings())
        XCTAssertEqual(AvifPluginSettings.parse(from: ""), AvifPluginSettings())
    }

    func testParseAcceptsPartialJSON() {
        let parsed = AvifPluginSettings.parse(from: #"{"quality":100}"#)
        XCTAssertEqual(parsed, AvifPluginSettings(quality: 100))
    }

    // MARK: - Encoder summary

    func testEncoderSummaryForEmbeddedEncoderListsEverySetting() {
        let settings = AvifPluginSettings(quality: 70, speed: 5, chroma: "444", bitDepth: 10)
        XCTAssertEqual(
            settings.encoderSummary(usingEmbeddedEncoder: true, uploadsBaseDir: "/srv/uploads"),
            "AVIF sideloading enabled (embedded aom encoder: quality 70, speed 5, "
                + "chroma 444, 10-bit; uploads dir /srv/uploads)."
        )
    }

    func testEncoderSummaryMarksLosslessAtQuality100() {
        let settings = AvifPluginSettings(quality: 100)
        let summary = settings.encoderSummary(usingEmbeddedEncoder: true, uploadsBaseDir: "/srv/uploads")
        XCTAssertTrue(summary.contains(", lossless"), "Unexpected summary: \(summary)")
    }

    func testEncoderSummaryForSystemEncoderOnlyMentionsQuality() {
        let settings = AvifPluginSettings(quality: 85, speed: 9, chroma: "422", bitDepth: 12)
        XCTAssertEqual(
            settings.encoderSummary(usingEmbeddedEncoder: false, uploadsBaseDir: "/srv/uploads"),
            "AVIF sideloading enabled (system encoder: quality 85; uploads dir /srv/uploads)."
        )
    }

    // MARK: - Uploads basedir parsing

    func testParseUploadsBaseDirTakesLastLine() {
        XCTAssertEqual(
            parseUploadsBaseDir(fromStdoutLines: ["motd banner", "/var/www/html/wp-content/uploads"]),
            "/var/www/html/wp-content/uploads"
        )
    }

    func testParseUploadsBaseDirTrimsWhitespace() {
        XCTAssertEqual(
            parseUploadsBaseDir(fromStdoutLines: ["  /srv/uploads  "]),
            "/srv/uploads"
        )
    }

    func testParseUploadsBaseDirRejectsRelativePathsAndEmptyOutput() {
        XCTAssertNil(parseUploadsBaseDir(fromStdoutLines: ["wp-content/uploads"]))
        XCTAssertNil(parseUploadsBaseDir(fromStdoutLines: ["PHP Warning: broken"]))
        XCTAssertNil(parseUploadsBaseDir(fromStdoutLines: []))
    }
}
