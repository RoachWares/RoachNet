@preconcurrency import AVFoundation
import Accelerate
import CoreML
import CryptoKit
import Foundation

struct RoachWhisperNativeAttribution: Equatable {
    static let upstreamProject = "ggml-org/whisper.cpp"
    static let upstreamLicense = "MIT"
    static let upstreamRepository = "https://github.com/ggml-org/whisper.cpp"
    static let modelFamily = "OpenAI Whisper"
    static let portName = "RoachWhisper"

    var summary: String {
        "\(Self.portName) is RoachNet's Swift/Core ML port of the \(Self.modelFamily) ASR path, adapted from \(Self.upstreamProject) under the \(Self.upstreamLicense) license."
    }
}

enum RoachWhisperNativeError: LocalizedError, Equatable {
    case missingReleaseReadyAssets
    case missingStagedAssets
    case missingAudioSamples
    case unsupportedAudioFormat
    case modelLoadFailed(String)
    case modelExecutionGated(String)
    case modelExecutionFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingReleaseReadyAssets:
            return "RoachWhisper can't transcribe yet: its Core ML pack isn't ready."
        case .missingStagedAssets:
            return "Some of RoachWhisper's Core ML files aren't installed, so it can't run yet."
        case .missingAudioSamples:
            return "RoachWhisper couldn't read usable audio from this file. Try a different file."
        case .unsupportedAudioFormat:
            return
                "RoachWhisper couldn't convert this audio to 16 kHz mono PCM for transcription. Try a different file."
        case .modelLoadFailed(let detail):
            return "RoachWhisper could not load the Core ML model pack: \(detail)"
        case .modelExecutionGated(let detail):
            return "RoachWhisper can't run yet: \(detail)"
        case .modelExecutionFailed(let detail):
            return "RoachWhisper couldn't finish transcribing: \(detail)"
        }
    }
}

struct RoachWhisperAudioWindow: Equatable, Identifiable {
    var id: Int { index }
    var index: Int
    var sampleRange: Range<Int>
    var startTime: TimeInterval
    var duration: TimeInterval
}

struct RoachWhisperNativePlan: Equatable {
    var audioURL: URL
    var sampleRate: Double
    var totalSamples: Int
    var windows: [RoachWhisperAudioWindow]
    var attribution: RoachWhisperNativeAttribution

    var totalDuration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(totalSamples) / sampleRate
    }

    var isReadyForModelExecution: Bool {
        !windows.isEmpty
    }
}

struct RoachWhisperCoreMLSmokeResult: Equatable {
    var melSpectrogramShape: [Int]
    var encoderOutputShape: [Int]
    var decoderLogitsShape: [Int]
    var keyCacheUpdateShape: [Int]
}

struct RoachWhisperNativeTranscript: Equatable {
    var text: String
    var tokens: [Int]
}

struct RoachWhisperTokenizer: Equatable {
    private struct TokenizerJSON: Decodable {
        struct Model: Decodable {
            var vocab: [String: Int]
        }

        var model: Model
        var addedTokens: [AddedToken]

        enum CodingKeys: String, CodingKey {
            case model
            case addedTokens = "added_tokens"
        }
    }

    private struct AddedToken: Decodable {
        var id: Int
        var content: String
    }

    static let endOfTextToken = 50_256
    static let specialTokenBegin = 50_257

    var idToToken: [Int: String]
    var byteDecoder: [Character: UInt8]

    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        let tokenizer = try JSONDecoder().decode(TokenizerJSON.self, from: data)
        var idToToken = Dictionary(uniqueKeysWithValues: tokenizer.model.vocab.map { ($0.value, $0.key) })
        for token in tokenizer.addedTokens {
            idToToken[token.id] = token.content
        }
        self.idToToken = idToToken
        self.byteDecoder = Self.makeByteDecoder()
    }

    func decode(tokens: [Int]) -> String {
        var bytes: [UInt8] = []
        for tokenID in tokens where tokenID < Self.specialTokenBegin && tokenID != Self.endOfTextToken {
            guard let token = idToToken[tokenID] else { continue }
            for character in token {
                if let byte = byteDecoder[character] {
                    bytes.append(byte)
                } else {
                    bytes.append(contentsOf: String(character).utf8)
                }
            }
        }
        return String(decoding: bytes, as: UTF8.self)
            .replacingOccurrences(of: "\u{fffd}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func makeByteDecoder() -> [Character: UInt8] {
        let visibleRanges = [
            33...126,
            161...172,
            174...255,
        ]
        var bytes = visibleRanges.flatMap { $0.map(UInt8.init) }
        var codePoints = bytes.map(Int.init)
        var nextCodePoint = 0
        for byte in UInt8.min...UInt8.max where !bytes.contains(byte) {
            bytes.append(byte)
            codePoints.append(256 + nextCodePoint)
            nextCodePoint += 1
        }

        var decoder: [Character: UInt8] = [:]
        for (byte, codePoint) in zip(bytes, codePoints) {
            guard let scalar = UnicodeScalar(codePoint) else { continue }
            decoder[Character(scalar)] = byte
        }
        return decoder
    }
}

struct RoachWhisperCoreMLModelHost {
    var assets: RoachWhisperAssets
    var configuration: MLModelConfiguration = {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        return configuration
    }()

    var isReleaseReady: Bool {
        assets.isReleaseReady
    }

    var isStagedForModelSmoke: Bool {
        assets.isStaged
            && assets.melSpectrogramModelURL != nil
            && assets.melSpectrogramHasModelFiles
    }

    func loadEncoder() throws -> MLModel {
        try loadModel(at: assets.encoderModelURL, label: "encoder")
    }

    func loadDecoder() throws -> MLModel {
        try loadModel(at: assets.decoderModelURL, label: "decoder")
    }

    func loadMelSpectrogramModel() throws -> MLModel? {
        guard let url = assets.melSpectrogramModelURL else {
            return nil
        }
        return try loadModel(at: url, label: "mel spectrogram")
    }

    private func loadModel(at url: URL?, label: String) throws -> MLModel {
        guard let url else {
            throw RoachWhisperNativeError.modelLoadFailed("missing \(label) model")
        }
        do {
            return try MLModel(contentsOf: url, configuration: configuration)
        } catch {
            throw RoachWhisperNativeError.modelLoadFailed("\(label): \(error.localizedDescription)")
        }
    }
}

struct RoachWhisperAudioFrontend {
    static let sampleRate: Double = 16_000
    static let windowDuration: TimeInterval = 30
    static let windowStride: TimeInterval = 30
    static let nFFT = 400
    static let hopLength = 160
    static let melBinCount = 80

    func loadMonoPCM16k(from url: URL) throws -> [Float] {
        let sourceFile = try AVAudioFile(forReading: url)
        guard
            let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Self.sampleRate,
                channels: 1,
                interleaved: false
            )
        else {
            throw RoachWhisperNativeError.unsupportedAudioFormat
        }

        guard let converter = AVAudioConverter(from: sourceFile.processingFormat, to: targetFormat) else {
            throw RoachWhisperNativeError.unsupportedAudioFormat
        }

        let estimatedFrames = max(
            1,
            AVAudioFrameCount(
                (Double(sourceFile.length) / sourceFile.processingFormat.sampleRate) * targetFormat.sampleRate) + 4096
        )
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: estimatedFrames) else {
            throw RoachWhisperNativeError.unsupportedAudioFormat
        }

        guard
            let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: sourceFile.processingFormat,
                frameCapacity: AVAudioFrameCount(sourceFile.length)
            )
        else {
            throw RoachWhisperNativeError.unsupportedAudioFormat
        }
        try sourceFile.read(into: inputBuffer)

        let inputProvider = RoachWhisperAudioInputProvider(buffer: inputBuffer)
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            inputProvider.nextBuffer(outStatus: outStatus)
        }

        if let conversionError {
            throw conversionError
        }
        guard status != .error, let channel = outputBuffer.floatChannelData?[0] else {
            throw RoachWhisperNativeError.unsupportedAudioFormat
        }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(outputBuffer.frameLength)))
        guard !samples.isEmpty else {
            throw RoachWhisperNativeError.missingAudioSamples
        }
        return Self.normalized(samples)
    }

    static func normalized(_ samples: [Float]) -> [Float] {
        guard let peak = samples.map(abs).max(), peak > 1 else {
            return samples
        }
        return samples.map { $0 / peak }
    }

    static func paddedOrTrimmed(_ samples: [Float], targetCount: Int) -> [Float] {
        if samples.count == targetCount {
            return samples
        }
        if samples.count > targetCount {
            return Array(samples.prefix(targetCount))
        }
        return samples + Array(repeating: 0, count: targetCount - samples.count)
    }

    static func windows(
        sampleCount: Int,
        sampleRate: Double = Self.sampleRate,
        windowDuration: TimeInterval = Self.windowDuration,
        stride: TimeInterval = Self.windowStride
    ) -> [RoachWhisperAudioWindow] {
        guard sampleCount > 0, sampleRate > 0, windowDuration > 0, stride > 0 else {
            return []
        }
        let windowSamples = max(1, Int((windowDuration * sampleRate).rounded()))
        let strideSamples = max(1, Int((stride * sampleRate).rounded()))
        var result: [RoachWhisperAudioWindow] = []
        var start = 0
        var index = 0
        while start < sampleCount {
            let end = min(sampleCount, start + windowSamples)
            result.append(
                RoachWhisperAudioWindow(
                    index: index,
                    sampleRange: start..<end,
                    startTime: Double(start) / sampleRate,
                    duration: Double(end - start) / sampleRate
                )
            )
            guard end < sampleCount else { break }
            start += strideSamples
            index += 1
        }
        return result
    }

    static func hannWindow(length: Int) -> [Float] {
        guard length > 0 else { return [] }
        var window = Array(repeating: Float(0), count: length)
        vDSP_hann_window(&window, vDSP_Length(length), Int32(vDSP_HANN_NORM))
        return window
    }

    static func fingerprint(samples: [Float]) -> String {
        var hasher = SHA256()
        samples.withUnsafeBufferPointer { buffer in
            if let baseAddress = buffer.baseAddress {
                hasher.update(
                    bufferPointer: UnsafeRawBufferPointer(
                        start: baseAddress, count: buffer.count * MemoryLayout<Float>.stride))
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private final class RoachWhisperAudioInputProvider: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private let lock = NSLock()
    private var didRead = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func nextBuffer(outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }

        guard !didRead else {
            outStatus.pointee = .endOfStream
            return nil
        }

        didRead = true
        outStatus.pointee = .haveData
        return buffer
    }
}

struct RoachWhisperNativeEngine {
    static let decoderStartTokenID: Int32 = 50_257
    static let englishLanguageTokenID = 50_258
    static let transcribeTaskTokenID = 50_358
    static let noTimestampsTokenID = 50_362
    static let silencePeakThreshold: Float = 0.000_001
    static let decoderKVCacheEmbedDimension = 3_072
    static let decoderKVCacheMaxSequenceLength = 224
    static let defaultMaximumDecodeTokens = 96
    static let suppressedTokens: Set<Int> = [
        1, 2, 7, 8, 9, 10, 14, 25, 26, 27, 28, 29, 31, 58, 59, 60, 61, 62, 63,
        90, 91, 92, 93, 357, 366, 438, 532, 685, 705, 796, 930, 1058, 1220, 1267,
        1279, 1303, 1343, 1377, 1391, 1635, 1782, 1875, 2162, 2361, 2488, 3467,
        4008, 4211, 4600, 4808, 5299, 5855, 6329, 7203, 9609, 9959, 10563,
        10786, 11420, 11709, 11907, 13163, 13697, 13700, 14808, 15306, 16410,
        16791, 17992, 19203, 19510, 20724, 22305, 22935, 27007, 30109, 30420,
        33409, 34949, 40283, 40493, 40549, 47282, 49146, 50257, 50357, 50358,
        50359, 50360, 50361,
    ]
    static let firstTokenSuppressedTokens: Set<Int> = [220, 50_256]
    static let transcriptionPromptTokens = [
        Int(decoderStartTokenID),
        englishLanguageTokenID,
        transcribeTaskTokenID,
        noTimestampsTokenID,
    ]

    var modelHost: RoachWhisperCoreMLModelHost
    var audioFrontend = RoachWhisperAudioFrontend()

    init(assets: RoachWhisperAssets) {
        self.modelHost = RoachWhisperCoreMLModelHost(assets: assets)
    }

    var attribution: RoachWhisperNativeAttribution {
        RoachWhisperNativeAttribution()
    }

    var canExecuteNativeInference: Bool {
        modelHost.isReleaseReady
    }

    func makePlan(for audioURL: URL) throws -> RoachWhisperNativePlan {
        let samples = try audioFrontend.loadMonoPCM16k(from: audioURL)
        return makePlan(for: audioURL, sampleCount: samples.count)
    }

    func makePlan(for audioURL: URL, sampleCount: Int) -> RoachWhisperNativePlan {
        RoachWhisperNativePlan(
            audioURL: audioURL,
            sampleRate: RoachWhisperAudioFrontend.sampleRate,
            totalSamples: sampleCount,
            windows: RoachWhisperAudioFrontend.windows(sampleCount: sampleCount),
            attribution: attribution
        )
    }

    func smokeTestCoreMLPipeline(samples: [Float]) throws -> RoachWhisperCoreMLSmokeResult {
        guard modelHost.isStagedForModelSmoke else {
            throw RoachWhisperNativeError.missingStagedAssets
        }

        let models = try loadPipelineModels()
        let encoderEmbeds = try runEncoder(samples: samples, models: models)
        let decoderOutput = try models.decoder.prediction(
            from: firstDecoderStepInput(encoderOutputEmbeds: encoderEmbeds)
        )
        guard let logits = decoderOutput.featureValue(for: "logits")?.multiArrayValue else {
            throw RoachWhisperNativeError.modelExecutionFailed("decoder did not return logits")
        }
        guard let keyCacheUpdates = decoderOutput.featureValue(for: "key_cache_updates")?.multiArrayValue else {
            throw RoachWhisperNativeError.modelExecutionFailed("decoder did not return key_cache_updates")
        }

        return RoachWhisperCoreMLSmokeResult(
            melSpectrogramShape: models.lastMelShape,
            encoderOutputShape: intShape(encoderEmbeds),
            decoderLogitsShape: intShape(logits),
            keyCacheUpdateShape: intShape(keyCacheUpdates)
        )
    }

    func transcribeWindow(samples: [Float], maximumTokenCount: Int = defaultMaximumDecodeTokens) throws
        -> RoachWhisperNativeTranscript
    {
        guard modelHost.isStagedForModelSmoke else {
            throw RoachWhisperNativeError.missingStagedAssets
        }
        guard let tokenizerURL = modelHost.assets.tokenizerURL else {
            throw RoachWhisperNativeError.modelLoadFailed("missing tokenizer")
        }
        if Self.isEffectivelySilent(samples) {
            return RoachWhisperNativeTranscript(
                text: "",
                tokens: Self.transcriptionPromptTokens
            )
        }
        let tokenizer = try RoachWhisperTokenizer(url: tokenizerURL)
        let models = try loadPipelineModels()
        let encoderEmbeds = try runEncoder(samples: samples, models: models)
        let state = try makeDecoderState()
        let promptTokens = Self.transcriptionPromptTokens
        var generatedTokens: [Int] = []
        var sampledToken = promptTokens[0]
        let maximumGeneratedTokens = min(
            max(1, maximumTokenCount),
            Self.decoderKVCacheMaxSequenceLength - promptTokens.count
        )
        let loopCount = promptTokens.count + maximumGeneratedTokens

        for tokenIndex in 0..<loopCount {
            let isPromptToken = tokenIndex < promptTokens.count
            let isFirstGeneratedToken = tokenIndex == promptTokens.count - 1
            let inputToken = isPromptToken ? promptTokens[tokenIndex] : sampledToken
            state.inputIDs[0] = NSNumber(value: inputToken)
            state.cacheLength[0] = NSNumber(value: tokenIndex)

            let output = try models.decoder.prediction(
                from: decoderInput(
                    state: state,
                    encoderOutputEmbeds: encoderEmbeds
                )
            )
            guard let logits = output.featureValue(for: "logits")?.multiArrayValue else {
                throw RoachWhisperNativeError.modelExecutionFailed("decoder did not return logits")
            }
            sampledToken = greedyToken(
                logits: logits,
                isFirstGeneratedToken: isFirstGeneratedToken
            )

            try updateDecoderState(state, from: output, tokenIndex: tokenIndex)

            if tokenIndex >= promptTokens.count - 1 {
                if sampledToken == RoachWhisperTokenizer.endOfTextToken {
                    break
                }
                generatedTokens.append(sampledToken)
            }
        }

        return RoachWhisperNativeTranscript(
            text: tokenizer.decode(tokens: generatedTokens),
            tokens: promptTokens + generatedTokens
        )
    }

    private final class PipelineModels {
        var mel: MLModel
        var encoder: MLModel
        var decoder: MLModel
        var lastMelShape: [Int] = []

        init(mel: MLModel, encoder: MLModel, decoder: MLModel) {
            self.mel = mel
            self.encoder = encoder
            self.decoder = decoder
        }
    }

    private final class DecoderState {
        var inputIDs: MLMultiArray
        var cacheLength: MLMultiArray
        var keyCache: MLMultiArray
        var valueCache: MLMultiArray
        var kvCacheUpdateMask: MLMultiArray
        var decoderKeyPaddingMask: MLMultiArray

        init(
            inputIDs: MLMultiArray,
            cacheLength: MLMultiArray,
            keyCache: MLMultiArray,
            valueCache: MLMultiArray,
            kvCacheUpdateMask: MLMultiArray,
            decoderKeyPaddingMask: MLMultiArray
        ) {
            self.inputIDs = inputIDs
            self.cacheLength = cacheLength
            self.keyCache = keyCache
            self.valueCache = valueCache
            self.kvCacheUpdateMask = kvCacheUpdateMask
            self.decoderKeyPaddingMask = decoderKeyPaddingMask
        }
    }

    private func loadPipelineModels() throws -> PipelineModels {
        let melModel = try modelHost.loadMelSpectrogramModel()
        guard let melModel else {
            throw RoachWhisperNativeError.modelLoadFailed("missing mel spectrogram model")
        }
        let encoderModel = try modelHost.loadEncoder()
        let decoderModel = try modelHost.loadDecoder()
        return PipelineModels(mel: melModel, encoder: encoderModel, decoder: decoderModel)
    }

    private func runEncoder(samples: [Float], models: PipelineModels) throws -> MLMultiArray {
        let audioSamples = RoachWhisperAudioFrontend.paddedOrTrimmed(
            samples,
            targetCount: Int(RoachWhisperAudioFrontend.sampleRate * RoachWhisperAudioFrontend.windowDuration)
        )

        do {
            let audioArray = try multiArray(shape: [audioSamples.count], dataType: .float16, fill: 0)
            for (index, sample) in audioSamples.enumerated() {
                audioArray[index] = NSNumber(value: sample)
            }

            let melOutput = try models.mel.prediction(
                from: MLDictionaryFeatureProvider(dictionary: [
                    "audio": MLFeatureValue(multiArray: audioArray)
                ])
            )
            guard let melFeatures = melOutput.featureValue(for: "melspectrogram_features")?.multiArrayValue else {
                throw RoachWhisperNativeError.modelExecutionFailed("mel model did not return melspectrogram_features")
            }
            models.lastMelShape = intShape(melFeatures)

            let encoderOutput = try models.encoder.prediction(
                from: MLDictionaryFeatureProvider(dictionary: [
                    "melspectrogram_features": MLFeatureValue(multiArray: melFeatures)
                ])
            )
            guard let encoderEmbeds = encoderOutput.featureValue(for: "encoder_output_embeds")?.multiArrayValue else {
                throw RoachWhisperNativeError.modelExecutionFailed("encoder did not return encoder_output_embeds")
            }
            return encoderEmbeds
        } catch let error as RoachWhisperNativeError {
            throw error
        } catch {
            throw RoachWhisperNativeError.modelExecutionFailed(error.localizedDescription)
        }
    }

    func assertReadyForNativeInference() throws {
        guard canExecuteNativeInference else {
            throw RoachWhisperNativeError.missingReleaseReadyAssets
        }
    }

    private func firstDecoderStepInput(encoderOutputEmbeds: MLMultiArray) throws -> MLDictionaryFeatureProvider {
        try decoderInput(state: makeDecoderState(), encoderOutputEmbeds: encoderOutputEmbeds)
    }

    private func makeDecoderState() throws -> DecoderState {
        let inputIDs = try multiArray(shape: [1], dataType: .int32, fill: NSNumber(value: Self.decoderStartTokenID))
        let cacheLength = try multiArray(shape: [1], dataType: .int32, fill: 0)
        let keyCache = try multiArray(
            shape: [1, Self.decoderKVCacheEmbedDimension, 1, Self.decoderKVCacheMaxSequenceLength],
            dataType: .float16,
            fill: 0
        )
        let valueCache = try multiArray(
            shape: [1, Self.decoderKVCacheEmbedDimension, 1, Self.decoderKVCacheMaxSequenceLength],
            dataType: .float16,
            fill: 0
        )
        let kvCacheUpdateMask = try multiArray(
            shape: [1, Self.decoderKVCacheMaxSequenceLength], dataType: .float16, fill: 0)
        let decoderKeyPaddingMask = try multiArray(
            shape: [1, Self.decoderKVCacheMaxSequenceLength],
            dataType: .float16,
            fill: -10_000
        )
        kvCacheUpdateMask[0] = 1
        decoderKeyPaddingMask[0] = 0

        return DecoderState(
            inputIDs: inputIDs,
            cacheLength: cacheLength,
            keyCache: keyCache,
            valueCache: valueCache,
            kvCacheUpdateMask: kvCacheUpdateMask,
            decoderKeyPaddingMask: decoderKeyPaddingMask
        )
    }

    private func decoderInput(state: DecoderState, encoderOutputEmbeds: MLMultiArray) throws
        -> MLDictionaryFeatureProvider
    {
        return try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: state.inputIDs),
            "cache_length": MLFeatureValue(multiArray: state.cacheLength),
            "key_cache": MLFeatureValue(multiArray: state.keyCache),
            "value_cache": MLFeatureValue(multiArray: state.valueCache),
            "kv_cache_update_mask": MLFeatureValue(multiArray: state.kvCacheUpdateMask),
            "encoder_output_embeds": MLFeatureValue(multiArray: encoderOutputEmbeds),
            "decoder_key_padding_mask": MLFeatureValue(multiArray: state.decoderKeyPaddingMask),
        ])
    }

    private func updateDecoderState(_ state: DecoderState, from output: MLFeatureProvider, tokenIndex: Int) throws {
        guard tokenIndex + 1 < Self.decoderKVCacheMaxSequenceLength else {
            return
        }
        guard let keyUpdates = output.featureValue(for: "key_cache_updates")?.multiArrayValue,
            let valueUpdates = output.featureValue(for: "value_cache_updates")?.multiArrayValue
        else {
            throw RoachWhisperNativeError.modelExecutionFailed("decoder cache updates missing")
        }

        for embeddingIndex in 0..<Self.decoderKVCacheEmbedDimension {
            let cacheIndex = embeddingIndex * Self.decoderKVCacheMaxSequenceLength + tokenIndex
            state.keyCache[cacheIndex] = keyUpdates[embeddingIndex]
            state.valueCache[cacheIndex] = valueUpdates[embeddingIndex]
        }
        state.decoderKeyPaddingMask[tokenIndex + 1] = 0
        state.kvCacheUpdateMask[tokenIndex] = 0
        state.kvCacheUpdateMask[tokenIndex + 1] = 1
    }

    private func greedyToken(logits: MLMultiArray, isFirstGeneratedToken: Bool) -> Int {
        var bestToken = RoachWhisperTokenizer.endOfTextToken
        var bestScore = -Float.greatestFiniteMagnitude
        let lastDimension = logits.shape.last?.intValue ?? logits.count
        for token in 0..<lastDimension {
            if Self.suppressedTokens.contains(token) { continue }
            if isFirstGeneratedToken && Self.firstTokenSuppressedTokens.contains(token) { continue }
            let score = logits[token].floatValue
            if score > bestScore {
                bestScore = score
                bestToken = token
            }
        }
        return bestToken
    }

    private static func isEffectivelySilent(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return true }
        let peak = samples.map(abs).max() ?? 0
        return peak <= silencePeakThreshold
    }

    private func multiArray(shape: [Int], dataType: MLMultiArrayDataType, fill value: NSNumber) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape.map(NSNumber.init(value:)), dataType: dataType)
        for index in 0..<array.count {
            array[index] = value
        }
        return array
    }

    private func intShape(_ array: MLMultiArray) -> [Int] {
        array.shape.map(\.intValue)
    }
}
