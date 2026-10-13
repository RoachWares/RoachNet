import XCTest
@testable import RoachNetRuntime

/// RoachNet and a person's own Ollama never share a port, and RoachNet never
/// starts an Ollama (ROA-74).
final class ModelServerAddressTests: XCTestCase {
    private var roots: [String] = []

    override func tearDownWithError() throws {
        for root in roots { Files.remove(root) }
    }

    private func runtime(_ environment: [String: String]) -> NativeRuntime {
        let root = NSTemporaryDirectory() + "roachnet-model-address-" + JS.randomHex(6)
        roots.append(root)
        var environment = environment
        environment["ROACHNET_STORAGE_PATH"] = root
        environment["ROACHNET_CLUSTER_BONJOUR"] = "0"
        return NativeRuntime(config: RuntimeConfiguration(environment: environment))
    }

    func testRoachInferenceNeverTakesOllamasPort() {
        let own = "http://127.0.0.1:36434"
        XCTAssertEqual(runtime([:]).roachInferenceURL, own)
        XCTAssertEqual(runtime(["OLLAMA_BASE_URL": "http://127.0.0.1:11434"]).roachInferenceURL, own)
        XCTAssertEqual(runtime(["OLLAMA_BASE_URL": "http://localhost:11434"]).roachInferenceURL, own)
        XCTAssertEqual(runtime(["OLLAMA_BASE_URL": "http://127.0.0.1"]).roachInferenceURL, own, "no port used to mean 11434")
        XCTAssertEqual(runtime(["OLLAMA_BASE_URL": "http://127.0.0.1:40123"]).roachInferenceURL, "http://127.0.0.1:40123",
                       "a port somebody chose is kept")
        XCTAssertEqual(runtime(["OLLAMA_BASE_URL": "http://127.0.0.1:40123", "ROACHNET_INFERENCE_ENGINE": "ollama"]).roachInferenceURL, own,
                       "with Ollama picked, the configured address may be that Ollama")
    }

    func testModelTrafficNeverStartsOutOnOllamasPort() {
        // Before anything is checked, RoachNet's model traffic points where
        // RoachInference would listen, not at whatever holds 11434.
        XCTAssertEqual(runtime(["OLLAMA_BASE_URL": "http://127.0.0.1:11434"]).modelServerBaseUrl, "http://127.0.0.1:36434")
        XCTAssertEqual(runtime([:]).modelServerBaseUrl, "http://127.0.0.1:36434")
        XCTAssertFalse(runtime([:]).modelServerIsOllama)
        XCTAssertEqual(runtime(["ROACHNET_INFERENCE_ENGINE": "ollama"]).modelServerBaseUrl, "http://127.0.0.1:11434")
    }

    func testThePersonsOllamaIsFoundWhereItListens() {
        let ollama = ["ROACHNET_INFERENCE_ENGINE": "ollama"]
        XCTAssertEqual(runtime(ollama).personsOllamaURL, "http://127.0.0.1:11434")
        XCTAssertEqual(runtime(ollama.merging(["ROACHNET_OLLAMA_URL": " http://127.0.0.1:11500 "]) { $1 }).personsOllamaURL, "http://127.0.0.1:11500")
        XCTAssertEqual(runtime(ollama.merging(["OLLAMA_BASE_URL": "http://127.0.0.1:11600"]) { $1 }).personsOllamaURL, "http://127.0.0.1:11600")
        XCTAssertEqual(runtime(ollama.merging(["OLLAMA_BASE_URL": "http://127.0.0.1:36434"]) { $1 }).personsOllamaURL, "http://127.0.0.1:11434",
                       "RoachNet's own address isn't the person's Ollama")
    }

    func testRoachNetsOwnModelAddressIsLoopbackOn36434() {
        for url in ["http://127.0.0.1:36434", "http://localhost:36434", "http://[::1]:36434"] {
            XCTAssertTrue(NativeRuntime.isRoachNetOwnModelURL(url), url)
        }
        for url in ["http://127.0.0.1:11434", "http://10.0.0.2:36434", "http://127.0.0.1", "not a url"] {
            XCTAssertFalse(NativeRuntime.isRoachNetOwnModelURL(url), url)
        }
    }

    func testRoachInferenceRefusesOllamasPortAndOtherHosts() {
        let subject = runtime([:])
        XCTAssertFalse(subject.startNativeModelServer(at: "http://127.0.0.1:11434"))
        XCTAssertFalse(subject.startNativeModelServer(at: "http://localhost:11434"))
        XCTAssertFalse(subject.startNativeModelServer(at: "http://10.0.0.2:40000"), "loopback only")
        XCTAssertNil(subject.roachInferenceAddress.value)
        XCTAssertNil(subject.modelServerAddress.value)
    }
}
