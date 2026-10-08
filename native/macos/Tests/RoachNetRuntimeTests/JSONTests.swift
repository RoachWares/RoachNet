import XCTest
@testable import RoachNetRuntime

final class JSONTests: XCTestCase {
    func testNumberFormattingMatchesJavaScript() {
        XCTAssertEqual(JSCoercion.format(number: 1), "1")
        XCTAssertEqual(JSCoercion.format(number: 0.85), "0.85")
        XCTAssertEqual(JSCoercion.format(number: 1e21), "1e+21")
        XCTAssertEqual(JSCoercion.format(number: 1e-7), "1e-7")
        XCTAssertEqual(JSCoercion.format(number: 0.000001), "0.000001")
        XCTAssertEqual(JSCoercion.format(number: 123456789012), "123456789012")
        XCTAssertEqual(JSCoercion.format(number: -2.5), "-2.5")
        XCTAssertEqual(JSCoercion.format(number: 1.5e300), "1.5e+300")
    }

    func testRoundTripPreservesOrderAndEscapes() throws {
        let text = #"{"b":1,"a":[true,null,"x\n\"y"],"c":{"z":0.5}}"#
        let value = try JSON.parse(text)
        XCTAssertEqual(value.serialized(), text)
        XCTAssertEqual(value["a"][2].stringValue, "x\n\"y")
    }

    func testPrettyMatchesStringify() {
        let value: JSON = ["a": [], "b": ["c": 1], "d": [1, 2]]
        XCTAssertEqual(value.prettySerialized(), "{\n  \"a\": [],\n  \"b\": {\n    \"c\": 1\n  },\n  \"d\": [\n    1,\n    2\n  ]\n}")
    }

    func testCoercions() {
        XCTAssertTrue(JSON.number(Double.nan).jsNumber.isNaN)
        XCTAssertEqual(JSON.null.jsNumber, 0)
        XCTAssertTrue(JSON.undefined.jsNumber.isNaN)
        XCTAssertEqual(JSON.string(" 12 ").jsNumber, 12)
        XCTAssertEqual(JSON.array(["a", 1]).jsString, "a,1")
        XCTAssertEqual(JS.compactString(JSON.string("  a \n\t b  ")), "a b")
        XCTAssertEqual(JS.compactStringList(JSON.string("a, b,,c")), ["a", "b", "c"])
        XCTAssertEqual((JSON.string("") || "fallback").stringValue, "fallback")
        XCTAssertEqual((JSON.bool(false) ?? true).boolValue, false)
    }

    func testWebURLNormalization() {
        XCTAssertEqual(WebURL("HTTP://Example.COM:80/a/../b?x=1#y")?.description, "http://example.com/b?x=1#y")
        XCTAssertEqual(WebURL("https://api.openai.com/v1")?.description, "https://api.openai.com/v1")
        XCTAssertEqual(WebURL("http://127.0.0.1:36434")?.description, "http://127.0.0.1:36434/")
        XCTAssertEqual(WebURL("local://roachbrain")?.description, "local://roachbrain")
        XCTAssertNil(WebURL("not a url"))
        let base = WebURL("http://127.0.0.1:36434")!
        XCTAssertEqual(WebURL("/api/tags", base: base)?.description, "http://127.0.0.1:36434/api/tags")
        XCTAssertEqual(WebURL("http://[::1]:8080/x")?.hostname, "[::1]")
    }

    func testSHA256() {
        XCTAssertEqual(SHA256Digest.hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256Digest.hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testLocaleCompare() {
        XCTAssertEqual(JS.sortedLocale(["b", "A", "a", "_x", "1"]), ["_x", "1", "a", "A", "b"])
    }

    func testPaths() {
        XCTAssertEqual(Path.join("/a/b", "../c", "d.json"), "/a/c/d.json")
        XCTAssertEqual(Path.dirname("/a/b/c"), "/a/b")
        XCTAssertEqual(Path.dirname("/a"), "/")
        XCTAssertEqual(Path.basename("/a/b.zim"), "b.zim")
        XCTAssertEqual(Path.relative(from: "/a/b", to: "/a/b/c/d"), "c/d")
    }
}
