import Foundation
import XCTest
@testable import RAPPVoiceCore

final class FormattingTests: XCTestCase {
    struct Fixture: Decodable {
        let name: String
        let raw: String
        let app: String
        let dictionary: String?
        let expected: String
    }
    func testLuaRegressionFixtures() throws {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: Self.self)
        #endif
        let url = try XCTUnwrap(bundle.url(forResource: "formatting", withExtension: "json", subdirectory: "Fixtures")
                                ?? bundle.url(forResource: "formatting", withExtension: "json"))
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
        XCTAssertGreaterThan(fixtures.count, 20)
        for fixture in fixtures {
            XCTAssertEqual(
                TextProcessor.process(fixture.raw, rawMode: TextProcessor.isRawApp(name: fixture.app, bundleID: fixture.app),
                                      dictionary: .init(fixture.dictionary ?? "")),
                fixture.expected, fixture.name
            )
        }
    }
    func testWeightedDictionaryTermsAreUniqueAndRepeatedExactlyTwice() {
        let dictionary = VoiceDictionary("# comment\nOpenRappter\n\nOpenRappter\nopen raptor => OpenRappter\nGPT-4\n")
        XCTAssertEqual(dictionary.weightedPrompt, "OpenRappter. OpenRappter. GPT-4. GPT-4.")
        XCTAssertEqual(dictionary.rewrites.first?.from, "open raptor")
        XCTAssertNil(VoiceDictionary().weightedPrompt)
    }
    func testTriggerIsFirstWordAndNotAPrefix() {
        XCTAssertEqual(TextProcessor.polishRemainder("  POLISH, hello there", trigger: "polish"), "hello there")
        XCTAssertEqual(TextProcessor.polishRemainder("polish", trigger: "polish"), "")
        XCTAssertNil(TextProcessor.polishRemainder("polished furniture", trigger: "polish"))
        XCTAssertNil(TextProcessor.polishRemainder("we should polish this", trigger: "polish"))
    }
    func testUnicodeSpeechIsNotMisclassifiedAsSilence() {
        XCTAssertEqual(TextProcessor.process("你好世界", rawMode: false), "你好世界.")
        XCTAssertEqual(TextProcessor.process("écrire ceci", rawMode: false), "Écrire ceci.")
    }
}
