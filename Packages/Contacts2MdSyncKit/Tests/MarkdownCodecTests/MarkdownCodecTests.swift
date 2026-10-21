import MarkdownCodec
import Testing

@Suite("MarkdownCodec")
struct MarkdownCodecTests {
    @Test("Yams dependency round-trips YAML")
    func yamlSmoke() throws {
        #expect(try MarkdownCodec.yamlSmokeTest())
    }
}
