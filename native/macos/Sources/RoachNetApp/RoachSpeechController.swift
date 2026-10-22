@preconcurrency import AVFoundation
import Foundation
import Speech

enum RoachSpeechModelPackKind: String, Codable, Equatable {
    case roachWhisper
    case roachVoice
}

enum RoachSpeechModelPackNativeFormat: String, Codable, Equatable {
    case coreML
}

enum RoachSpeechModelPackFeature: String, Codable, Equatable {
    case speechToText
    case customVoiceSynthesis
    case voiceCloning
    case paralinguisticTags
    case watermarking
    case transcriptSidecars
    case lyricExtraction
}

struct RoachSpeechModelPackProvenance: Codable, Equatable {
    var upstreamProject: String
    var upstreamModelName: String
    var sourceFormat: String
    var conversionCommand: String
    var upstreamCommit: String?
    var importedAt: String?
    var referenceProject: String?

    init(
        upstreamProject: String,
        upstreamModelName: String,
        sourceFormat: String,
        conversionCommand: String,
        upstreamCommit: String? = nil,
        importedAt: String? = nil,
        referenceProject: String? = nil
    ) {
        self.upstreamProject = upstreamProject
        self.upstreamModelName = upstreamModelName
        self.sourceFormat = sourceFormat
        self.conversionCommand = conversionCommand
        self.upstreamCommit = upstreamCommit
        self.importedAt = importedAt
        self.referenceProject = referenceProject
    }
}

struct RoachSpeechModelPackManifest: Codable, Equatable {
    var packID: String
    var displayName: String
    var version: String
    var kind: RoachSpeechModelPackKind
    var nativeFormat: RoachSpeechModelPackNativeFormat
    var features: [RoachSpeechModelPackFeature]
    var noNetwork: Bool
    var noPackagedBinary: Bool
    var nativeInferenceReady: Bool
    var parityValidated: Bool
    var provenance: RoachSpeechModelPackProvenance?

    init(
        packID: String,
        displayName: String,
        version: String,
        kind: RoachSpeechModelPackKind,
        nativeFormat: RoachSpeechModelPackNativeFormat,
        features: [RoachSpeechModelPackFeature],
        noNetwork: Bool = true,
        noPackagedBinary: Bool = true,
        nativeInferenceReady: Bool,
        parityValidated: Bool,
        provenance: RoachSpeechModelPackProvenance? = nil
    ) {
        self.packID = packID
        self.displayName = displayName
        self.version = version
        self.kind = kind
        self.nativeFormat = nativeFormat
        self.features = features
        self.noNetwork = noNetwork
        self.noPackagedBinary = noPackagedBinary
        self.nativeInferenceReady = nativeInferenceReady
        self.parityValidated = parityValidated
        self.provenance = provenance
    }

    var guaranteesNoNetworkOrPackagedBinary: Bool {
        noNetwork && noPackagedBinary
    }

    var isRoachNetOwnedNativePack: Bool {
        provenance?.upstreamProject == "RoachWares/RoachNet"
            && nativeFormat == .coreML
            && guaranteesNoNetworkOrPackagedBinary
    }
}

struct RoachWhisperAssets: Equatable {
    var encoderModelURL: URL? = nil
    var decoderModelURL: URL? = nil
    var melSpectrogramModelURL: URL? = nil
    var tokenizerURL: URL? = nil
    var parityManifestURL: URL? = nil
    var manifest: RoachSpeechModelPackManifest? = nil
    var encoderHasModelFiles: Bool = false
    var decoderHasModelFiles: Bool = false
    var melSpectrogramHasModelFiles: Bool = false
    var tokenizerHasContent: Bool = false
    var parityManifestHasContent: Bool = false

    var isStaged: Bool {
        hasUsableEncoderModel
            && hasUsableDecoderModel
            && tokenizerURL != nil
            && tokenizerHasContent
            && parityManifestURL != nil
            && parityManifestHasContent
    }

    var hasUsableEncoderModel: Bool {
        encoderModelURL != nil && encoderHasModelFiles
    }

    var hasUsableDecoderModel: Bool {
        decoderModelURL != nil && decoderHasModelFiles
    }

    var isReleaseReady: Bool {
        guard let manifest else { return false }
        return isStaged
            && manifest.kind == .roachWhisper
            && manifest.nativeFormat == .coreML
            && manifest.features.contains(.speechToText)
            && manifest.guaranteesNoNetworkOrPackagedBinary
            && manifest.isRoachNetOwnedNativePack
            && manifest.nativeInferenceReady
            && manifest.parityValidated
    }

    var statusLabel: String {
        if isReleaseReady {
            return "RoachWhisper pack ready"
        }
        if isStaged {
            return "RoachWhisper installed; it can't transcribe yet"
        }
        if hasUsableEncoderModel {
            return "RoachWhisper pack is incomplete; it can't transcribe yet"
        }
        return "RoachWhisper pack not installed"
    }
}

struct RoachVoiceAssets: Equatable {
    var acousticModelURL: URL? = nil
    var vocoderModelURL: URL? = nil
    var narratorModelURL: URL? = nil
    var languageModelURL: URL? = nil
    var conditionalDecoderURL: URL? = nil
    var speechEncoderURL: URL? = nil
    var embedTokensURL: URL? = nil
    var tokenizerURL: URL? = nil
    var voiceEmbeddingURL: URL? = nil
    var manifest: RoachSpeechModelPackManifest? = nil
    var acousticModelHasFiles: Bool = false
    var vocoderModelHasFiles: Bool = false
    var narratorModelHasFiles: Bool = false
    var languageModelHasFiles: Bool = false
    var conditionalDecoderHasFiles: Bool = false
    var speechEncoderHasFiles: Bool = false
    var embedTokensHasFiles: Bool = false
    var tokenizerHasContent: Bool = false
    var embeddingHasContent: Bool = false

    var hasSplitSynthesisModels: Bool {
        acousticModelURL != nil
            && acousticModelHasFiles
            && vocoderModelURL != nil
            && vocoderModelHasFiles
    }

    var hasCombinedNarratorModel: Bool {
        narratorModelURL != nil && narratorModelHasFiles
    }

    var hasChatterboxTurboStack: Bool {
        languageModelURL != nil
            && languageModelHasFiles
            && conditionalDecoderURL != nil
            && conditionalDecoderHasFiles
            && speechEncoderURL != nil
            && speechEncoderHasFiles
            && embedTokensURL != nil
            && embedTokensHasFiles
            && tokenizerURL != nil
            && tokenizerHasContent
    }

    var isStaged: Bool {
        (hasSplitSynthesisModels || hasCombinedNarratorModel || hasChatterboxTurboStack)
            && voiceEmbeddingURL != nil
            && embeddingHasContent
    }

    var isSynthesisReady: Bool {
        guard let manifest else { return false }
        return isStaged
            && manifest.kind == .roachVoice
            && manifest.nativeFormat == .coreML
            && manifest.features.contains(.customVoiceSynthesis)
            && manifest.guaranteesNoNetworkOrPackagedBinary
            && manifest.isRoachNetOwnedNativePack
            && manifest.nativeInferenceReady
    }

    var isVoiceCloningReady: Bool {
        guard let manifest else { return false }
        return isSynthesisReady
            && hasChatterboxTurboStack
            && manifest.features.contains(.voiceCloning)
    }

    var statusLabel: String {
        if isVoiceCloningReady {
            return "RoachVoice cloning pack ready"
        }
        if isSynthesisReady {
            return "Custom voice pack ready"
        }
        if isStaged {
            return "Custom voice pack installed; it can't speak yet"
        }
        return "Custom voice pack is missing files"
    }
}

struct RoachSpeechRuntimeInventory: Equatable {
    var whisperPack: RoachSpeechModelPack?
    var voicePacks: [RoachSpeechModelPack]

    var whisperAssets: RoachWhisperAssets? {
        whisperPack?.whisperAssets
    }

    var primaryVoiceAssets: RoachVoiceAssets? {
        voicePacks.first { $0.voiceAssets.isVoiceCloningReady }?.voiceAssets
            ?? voicePacks.first { $0.voiceAssets.isSynthesisReady }?.voiceAssets
            ?? voicePacks.first?.voiceAssets
    }

    var voicePackCount: Int {
        voicePacks.count
    }

    var hasReleaseReadyVoicePack: Bool {
        voicePacks.contains { $0.voiceAssets.isSynthesisReady }
    }
}

struct RoachSpeechModelPack: Equatable {
    static let manifestFileName = "RoachSpeechPack.json"

    var rootURL: URL
    var manifest: RoachSpeechModelPackManifest
    var whisperAssets: RoachWhisperAssets
    var voiceAssets: RoachVoiceAssets

    var guaranteesNoNetworkOrPackagedBinary: Bool {
        manifest.guaranteesNoNetworkOrPackagedBinary
    }

    static func load(rootURL: URL, fileManager: FileManager = .default) throws -> RoachSpeechModelPack {
        let manifestURL = rootURL.appendingPathComponent(manifestFileName)
        let manifest = try JSONDecoder().decode(
            RoachSpeechModelPackManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        let whisperRoot = rootURL.appendingPathComponent("RoachWhisper", isDirectory: true)
        let voiceRoot = rootURL.appendingPathComponent("RoachVoice", isDirectory: true)
        return RoachSpeechModelPack(
            rootURL: rootURL,
            manifest: manifest,
            whisperAssets: RoachWhisperAssets(
                encoderModelURL: existingURL(
                    whisperRoot.appendingPathComponent("RoachWhisperEncoder.mlmodelc", isDirectory: true),
                    fileManager: fileManager
                ),
                decoderModelURL: existingURL(
                    whisperRoot.appendingPathComponent("RoachWhisperDecoder.mlmodelc", isDirectory: true),
                    fileManager: fileManager
                ),
                melSpectrogramModelURL: existingURL(
                    whisperRoot.appendingPathComponent("RoachWhisperMelSpectrogram.mlmodelc", isDirectory: true),
                    fileManager: fileManager
                ),
                tokenizerURL: existingURL(
                    whisperRoot.appendingPathComponent("RoachWhisperTokenizer.json"),
                    fileManager: fileManager
                ),
                parityManifestURL: existingURL(
                    whisperRoot.appendingPathComponent("RoachWhisperParity.json"),
                    fileManager: fileManager
                ),
                manifest: manifest,
                encoderHasModelFiles: compiledModelBundleHasPayload(
                    whisperRoot.appendingPathComponent("RoachWhisperEncoder.mlmodelc", isDirectory: true),
                    fileManager: fileManager
                ),
                decoderHasModelFiles: compiledModelBundleHasPayload(
                    whisperRoot.appendingPathComponent("RoachWhisperDecoder.mlmodelc", isDirectory: true),
                    fileManager: fileManager
                ),
                melSpectrogramHasModelFiles: compiledModelBundleHasPayload(
                    whisperRoot.appendingPathComponent("RoachWhisperMelSpectrogram.mlmodelc", isDirectory: true),
                    fileManager: fileManager
                ),
                tokenizerHasContent: fileHasContent(
                    whisperRoot.appendingPathComponent("RoachWhisperTokenizer.json"),
                    fileManager: fileManager
                ),
                parityManifestHasContent: fileHasContent(
                    whisperRoot.appendingPathComponent("RoachWhisperParity.json"),
                    fileManager: fileManager
                )
            ),
            voiceAssets: RoachVoiceAssets(
                acousticModelURL: existingURL(
                    voiceRoot.appendingPathComponent("RoachVoiceAcoustic.mlmodelc", isDirectory: true),
                    fileManager: fileManager
                ),
                vocoderModelURL: existingURL(
                    voiceRoot.appendingPathComponent("RoachVoiceVocoder.mlmodelc", isDirectory: true),
                    fileManager: fileManager
                ),
                narratorModelURL: existingURL(
                    voiceRoot.appendingPathComponent("RoachVoiceNarrator.mlmodelc", isDirectory: true),
                    fileManager: fileManager
                ),
                languageModelURL: existingURL(
                    voiceRoot.appendingPathComponent("RoachVoiceLanguageModel.mlmodelc", isDirectory: true),
                    fileManager: fileManager
                ),
                conditionalDecoderURL: existingURL(
                    voiceRoot.appendingPathComponent("RoachVoiceConditionalDecoder.mlmodelc", isDirectory: true),
                    fileManager: fileManager
                ),
                speechEncoderURL: existingURL(
                    voiceRoot.appendingPathComponent("RoachVoiceSpeechEncoder.mlmodelc", isDirectory: true),
                    fileManager: fileManager
                ),
                embedTokensURL: existingURL(
                    voiceRoot.appendingPathComponent("RoachVoiceEmbedTokens.mlmodelc", isDirectory: true),
                    fileManager: fileManager
                ),
                tokenizerURL: existingURL(
                    voiceRoot.appendingPathComponent("RoachVoiceTokenizer.json"),
                    fileManager: fileManager
                ),
                voiceEmbeddingURL: existingURL(
                    voiceRoot.appendingPathComponent("RoachVoiceEmbedding.json"),
                    fileManager: fileManager
                ),
                manifest: manifest,
                acousticModelHasFiles: compiledModelBundleHasPayload(
                    voiceRoot.appendingPathComponent("RoachVoiceAcoustic.mlmodelc", isDirectory: true),
                    fileManager: fileManager
                ),
                vocoderModelHasFiles: compiledModelBundleHasPayload(
                    voiceRoot.appendingPathComponent("RoachVoiceVocoder.mlmodelc", isDirectory: true),
                    fileManager: fileManager
                ),
                narratorModelHasFiles: compiledModelBundleHasPayload(
                    voiceRoot.appendingPathComponent("RoachVoiceNarrator.mlmodelc", isDirectory: true),
                    fileManager: fileManager
                ),
                languageModelHasFiles: compiledModelBundleHasPayload(
                    voiceRoot.appendingPathComponent("RoachVoiceLanguageModel.mlmodelc", isDirectory: true),
                    fileManager: fileManager
                ),
                conditionalDecoderHasFiles: compiledModelBundleHasPayload(
                    voiceRoot.appendingPathComponent("RoachVoiceConditionalDecoder.mlmodelc", isDirectory: true),
                    fileManager: fileManager
                ),
                speechEncoderHasFiles: compiledModelBundleHasPayload(
                    voiceRoot.appendingPathComponent("RoachVoiceSpeechEncoder.mlmodelc", isDirectory: true),
                    fileManager: fileManager
                ),
                embedTokensHasFiles: compiledModelBundleHasPayload(
                    voiceRoot.appendingPathComponent("RoachVoiceEmbedTokens.mlmodelc", isDirectory: true),
                    fileManager: fileManager
                ),
                tokenizerHasContent: fileHasContent(
                    voiceRoot.appendingPathComponent("RoachVoiceTokenizer.json"),
                    fileManager: fileManager
                ),
                embeddingHasContent: fileHasContent(
                    voiceRoot.appendingPathComponent("RoachVoiceEmbedding.json"),
                    fileManager: fileManager
                )
            )
        )
    }

    static func discover(in roots: [URL], fileManager: FileManager = .default) -> [RoachSpeechModelPack] {
        roots.flatMap { root -> [RoachSpeechModelPack] in
            let packRoots = [
                root.appendingPathComponent("RoachSpeech/ModelPacks", isDirectory: true),
                root.appendingPathComponent("EmbeddedRuntime/roachspeech/model-packs", isDirectory: true),
            ]
            return packRoots.flatMap { packRoot -> [RoachSpeechModelPack] in
                guard
                    let entries = try? fileManager.contentsOfDirectory(
                        at: packRoot,
                        includingPropertiesForKeys: [.isDirectoryKey],
                        options: [.skipsHiddenFiles]
                    )
                else {
                    return []
                }
                return entries.compactMap { try? load(rootURL: $0, fileManager: fileManager) }
            }
        }
    }

    private static func existingURL(_ url: URL, fileManager: FileManager) -> URL? {
        fileManager.fileExists(atPath: url.path) ? url : nil
    }

    static func fileHasContent(_ url: URL, fileManager: FileManager) -> Bool {
        guard fileManager.fileExists(atPath: url.path),
            let attributes = try? fileManager.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? NSNumber
        else {
            return false
        }
        return size.intValue > 0
    }

    static func compiledModelBundleHasPayload(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        guard
            let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return false
        }
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true, (values?.fileSize ?? 0) > 0 {
                return true
            }
        }
        return false
    }
}

enum RoachSpeechCustomVoiceSampleSource: String, Codable, Equatable {
    case microphone
    case importedFile
}

struct RoachSpeechCustomVoiceSample: Codable, Equatable {
    var id: String
    var source: RoachSpeechCustomVoiceSampleSource
    var urlPath: String
    var durationSeconds: Double
    var localOnly: Bool

    var url: URL {
        URL(fileURLWithPath: urlPath)
    }
}

enum RoachSpeechCustomVoicePreparationStatus: Codable, Equatable {
    case collectingSamples
    case preparing
    case prepared(modelPackRootPath: String)
}

struct RoachSpeechCustomVoiceProject: Codable, Equatable {
    static let requiredMinimumSampleDurationSeconds: Double = 30
    static let recommendedSampleDurationSeconds: Double = 180

    var id: String
    var displayName: String
    var samples: [RoachSpeechCustomVoiceSample]
    var preparationStatus: RoachSpeechCustomVoicePreparationStatus

    static func microphoneProject(displayName: String, sampleURL: URL, durationSeconds: Double)
        -> RoachSpeechCustomVoiceProject
    {
        RoachSpeechCustomVoiceProject(
            id: stableProjectID(displayName: displayName),
            displayName: displayName,
            samples: [
                sample(source: .microphone, sampleURL: sampleURL, durationSeconds: durationSeconds)
            ],
            preparationStatus: .collectingSamples
        )
    }

    static func importedProject(displayName: String, sampleURL: URL, durationSeconds: Double)
        -> RoachSpeechCustomVoiceProject
    {
        RoachSpeechCustomVoiceProject(
            id: stableProjectID(displayName: displayName),
            displayName: displayName,
            samples: [
                sample(source: .importedFile, sampleURL: sampleURL, durationSeconds: durationSeconds)
            ],
            preparationStatus: .collectingSamples
        )
    }

    func addingSample(source: RoachSpeechCustomVoiceSampleSource, sampleURL: URL, durationSeconds: Double)
        -> RoachSpeechCustomVoiceProject
    {
        var copy = self
        copy.samples.append(Self.sample(source: source, sampleURL: sampleURL, durationSeconds: durationSeconds))
        return copy
    }

    var totalSampleDurationSeconds: Double {
        samples.reduce(0) { $0 + max(0, $1.durationSeconds) }
    }

    var isLocalOnly: Bool {
        samples.allSatisfy(\.localOnly)
    }

    var isReadyToPrepare: Bool {
        isLocalOnly && totalSampleDurationSeconds >= Self.requiredMinimumSampleDurationSeconds
    }

    var requiredRemainingDurationSeconds: Double {
        max(0, Self.requiredMinimumSampleDurationSeconds - totalSampleDurationSeconds)
    }

    var preparationStatusLabel: String {
        switch preparationStatus {
        case .prepared:
            return "Local voice pack prepared"
        case .preparing:
            return "Preparing local voice pack"
        case .collectingSamples:
            if isReadyToPrepare {
                return "Ready to prepare local voice pack"
            }
            return "Record \(Int(ceil(requiredRemainingDurationSeconds)))s more sample audio"
        }
    }

    var sampleProgress: Double {
        min(1, totalSampleDurationSeconds / Self.recommendedSampleDurationSeconds)
    }

    var sampleRequirementLabel: String {
        if totalSampleDurationSeconds >= Self.recommendedSampleDurationSeconds {
            return "Recommended amount of clean audio captured"
        }
        if isReadyToPrepare {
            return "Minimum captured. More clean audio improves the clone."
        }
        return "Record \(Int(ceil(requiredRemainingDurationSeconds)))s more of your voice."
    }

    var canPrepareNativeVoicePack: Bool {
        isReadyToPrepare
    }

    func preparing() -> RoachSpeechCustomVoiceProject {
        var copy = self
        copy.preparationStatus = .preparing
        return copy
    }

    func prepared(modelPackRootURL: URL) -> RoachSpeechCustomVoiceProject {
        var copy = self
        copy.preparationStatus = .prepared(modelPackRootPath: modelPackRootURL.path)
        return copy
    }

    private static func sample(
        source: RoachSpeechCustomVoiceSampleSource,
        sampleURL: URL,
        durationSeconds: Double
    ) -> RoachSpeechCustomVoiceSample {
        RoachSpeechCustomVoiceSample(
            id: "\(source.rawValue)-\(sampleURL.lastPathComponent)",
            source: source,
            urlPath: sampleURL.path,
            durationSeconds: max(0, durationSeconds),
            localOnly: sampleURL.isFileURL
        )
    }

    private static func stableProjectID(displayName: String) -> String {
        let slug =
            displayName
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return slug.isEmpty ? "custom-voice-project" : slug
    }
}

enum RoachSpeechVoiceProfileKind: String, Codable, Equatable {
    case systemVoice
    case customProject
}

struct RoachSpeechVoiceProfile: Codable, Equatable {
    var id: String
    var displayName: String
    var kind: RoachSpeechVoiceProfileKind
    var systemVoiceIdentifier: String?
    var customProject: RoachSpeechCustomVoiceProject?
    var modelPackRootPath: String?
    var modelPackVersion: String?
    var modelPackStatusLabel: String?

    static var systemDefault: RoachSpeechVoiceProfile {
        RoachSpeechVoiceProfile(
            id: "system-default",
            displayName: "System voice",
            kind: .systemVoice,
            systemVoiceIdentifier: nil,
            customProject: nil,
            modelPackRootPath: nil,
            modelPackVersion: nil,
            modelPackStatusLabel: nil
        )
    }

    static func custom(project: RoachSpeechCustomVoiceProject, modelPack: RoachSpeechModelPack?)
        -> RoachSpeechVoiceProfile
    {
        RoachSpeechVoiceProfile(
            id: project.id,
            displayName: project.displayName,
            kind: .customProject,
            systemVoiceIdentifier: nil,
            customProject: project,
            modelPackRootPath: modelPack?.rootURL.path,
            modelPackVersion: modelPack?.manifest.version,
            modelPackStatusLabel: modelPack?.voiceAssets.statusLabel
        )
    }

    func upgrading(to modelPack: RoachSpeechModelPack) -> RoachSpeechVoiceProfile {
        var copy = self
        copy.modelPackRootPath = modelPack.rootURL.path
        copy.modelPackVersion = modelPack.manifest.version
        copy.modelPackStatusLabel = modelPack.voiceAssets.statusLabel
        return copy
    }

    var canFallbackToSystemVoice: Bool {
        true
    }

    var requiresNativeVoicePack: Bool {
        kind == .customProject
    }

    var canUseCustomSynthesis: Bool {
        modelPackRootPath != nil && (modelPackStatusLabel == "Custom voice pack ready")
    }

    var statusLabel: String {
        switch kind {
        case .systemVoice:
            return "System voice ready"
        case .customProject:
            return modelPackStatusLabel ?? "Custom voice project needs a voice pack"
        }
    }
}

struct RoachSpeechPersonalVoiceSummary: Equatable {
    var authorizationLabel: String
    var availableVoiceIdentifiers: [String]
    var availableVoiceNames: [String]
    var isAuthorized: Bool
    var isSupported: Bool

    static var unavailable: RoachSpeechPersonalVoiceSummary {
        RoachSpeechPersonalVoiceSummary(
            authorizationLabel: "Unavailable",
            availableVoiceIdentifiers: [],
            availableVoiceNames: [],
            isAuthorized: false,
            isSupported: false
        )
    }
}

enum RoachSpeechVaultAction: String, Codable, CaseIterable, Equatable, Hashable {
    case readAloud
    case transcribeAudio
    case transcribeVideo
    case extractLyrics
    case generateTranscriptSidecar

    var displayName: String {
        switch self {
        case .readAloud:
            return "Read aloud"
        case .transcribeAudio:
            return "Transcribe audio"
        case .transcribeVideo:
            return "Transcribe video"
        case .extractLyrics:
            return "Extract lyrics"
        case .generateTranscriptSidecar:
            return "Save transcript beside the file"
        }
    }
}

struct RoachSpeechVaultActionPlan: Codable, Equatable {
    var action: RoachSpeechVaultAction
    var sourceURL: URL
    var outputURL: URL?

    static func plan(action: RoachSpeechVaultAction, sourceURL: URL) -> RoachSpeechVaultActionPlan {
        RoachSpeechVaultActionPlan(
            action: action,
            sourceURL: sourceURL,
            outputURL: outputURL(for: action, sourceURL: sourceURL)
        )
    }

    static func plans(for sourceURL: URL) -> [RoachSpeechVaultActionPlan] {
        plans(for: VaultPreviewKind.resolve(for: sourceURL), sourceURL: sourceURL)
    }

    static func plans(for kind: VaultPreviewKind, sourceURL: URL) -> [RoachSpeechVaultActionPlan] {
        actions(for: kind).map { plan(action: $0, sourceURL: sourceURL) }
    }

    static func actions(for kind: VaultPreviewKind) -> [RoachSpeechVaultAction] {
        switch kind {
        case .markdown, .text, .pdf, .book:
            return [.readAloud]
        case .audio:
            return [.transcribeAudio, .extractLyrics, .generateTranscriptSidecar]
        case .video:
            return [.transcribeVideo, .generateTranscriptSidecar]
        case .image, .archive, .folder, .generic:
            return []
        }
    }

    func isReady(runtime: RoachSpeechNativeRuntimeStatus, voiceProfile: RoachSpeechVoiceProfile) -> Bool {
        switch action {
        case .readAloud:
            return voiceProfile.canFallbackToSystemVoice
        case .transcribeAudio, .transcribeVideo, .extractLyrics, .generateTranscriptSidecar:
            return runtime.speechToTextReady
        }
    }

    func statusLabel(runtime: RoachSpeechNativeRuntimeStatus, voiceProfile: RoachSpeechVoiceProfile) -> String {
        if isReady(runtime: runtime, voiceProfile: voiceProfile) {
            return action == .readAloud ? "Ready with system voice" : "Ready with RoachWhisper"
        }
        switch action {
        case .readAloud:
            return "Needs a usable voice profile"
        case .transcribeAudio, .transcribeVideo, .extractLyrics, .generateTranscriptSidecar:
            return "Needs RoachWhisper, which isn't ready yet"
        }
    }

    private static func outputURL(for action: RoachSpeechVaultAction, sourceURL: URL) -> URL? {
        switch action {
        case .readAloud:
            return nil
        case .extractLyrics:
            return sidecarURL(for: sourceURL, suffix: "lyrics", extensionName: "txt")
        case .transcribeAudio, .transcribeVideo, .generateTranscriptSidecar:
            return sidecarURL(for: sourceURL, suffix: "transcript", extensionName: "json")
        }
    }

    private static func sidecarURL(for sourceURL: URL, suffix: String, extensionName: String) -> URL {
        let sourceWithoutExtension = sourceURL.deletingPathExtension()
        return
            sourceWithoutExtension
            .deletingLastPathComponent()
            .appendingPathComponent("\(sourceWithoutExtension.lastPathComponent).\(suffix).\(extensionName)")
    }
}

struct RoachSpeechNativeRuntimeStatus: Equatable {
    var encoderModelPath: String?
    var decoderModelPath: String?
    var tokenizerPath: String?
    var parityManifestPath: String?
    var coreMLSource: String
    var usesPackagedBinary: Bool
    var roachWhisperAssets: RoachWhisperAssets? = nil
    var roachVoiceAssets: RoachVoiceAssets? = nil
    var voicePackCount: Int = 0

    var roachWhisperAssetsReady: Bool {
        roachWhisperAssets?.isStaged
            ?? (encoderModelPath != nil && decoderModelPath != nil && tokenizerPath != nil && parityManifestPath != nil)
    }

    var whisperParityReady: Bool {
        roachWhisperAssets?.isReleaseReady ?? false
    }

    var speechToTextReady: Bool {
        whisperParityReady
    }

    var textToSpeechReady: Bool { true }

    var customVoiceSynthesisReady: Bool {
        roachVoiceAssets?.isSynthesisReady ?? false
    }

    var customVoiceCloningReady: Bool {
        roachVoiceAssets?.isVoiceCloningReady ?? false
    }

    var speechToTextLabel: String {
        whisperParityReady ? "RoachWhisper" : "Apple Speech"
    }

    var textToSpeechLabel: String {
        customVoiceSynthesisReady ? "RoachVoice" : "System voice"
    }

    var parityLabel: String {
        if let roachWhisperAssets {
            if roachWhisperAssets.manifest == nil && roachWhisperAssets.isStaged {
                return "RoachWhisper not ready"
            }
            return roachWhisperAssets.statusLabel
        }
        return whisperParityReady
            ? "RoachWhisper ready" : (roachWhisperAssetsReady ? "RoachWhisper not ready" : "Apple Speech fallback")
    }

    var voiceLabel: String {
        roachVoiceAssets?.statusLabel ?? "System voice fallback"
    }
}

enum RoachSpeechNativeRuntime {
    static func status() -> RoachSpeechNativeRuntimeStatus {
        status(
            environment: ProcessInfo.processInfo.environment,
            resourceRoots: defaultResourceRoots(),
            fileManager: .default
        )
    }

    static func status(
        environment: [String: String],
        resourceRoots: [URL],
        fileManager: FileManager
    ) -> RoachSpeechNativeRuntimeStatus {
        let encoderURL = firstExistingFile(
            explicitPath: environment["ROACHNET_ROACHWHISPER_ENCODER_MODEL"],
            named: [
                "RoachSpeech/RoachWhisperEncoder.mlmodelc",
                "EmbeddedRuntime/roachspeech/RoachWhisperEncoder.mlmodelc",
            ],
            resourceRoots: resourceRoots,
            fileManager: fileManager
        )
        let decoderURL = firstExistingFile(
            explicitPath: environment["ROACHNET_ROACHWHISPER_DECODER_MODEL"],
            named: [
                "RoachSpeech/RoachWhisperDecoder.mlmodelc",
                "EmbeddedRuntime/roachspeech/RoachWhisperDecoder.mlmodelc",
            ],
            resourceRoots: resourceRoots,
            fileManager: fileManager
        )
        let tokenizerURL = firstExistingFile(
            explicitPath: environment["ROACHNET_ROACHWHISPER_TOKENIZER"],
            named: [
                "RoachSpeech/RoachWhisperTokenizer.json",
                "EmbeddedRuntime/roachspeech/RoachWhisperTokenizer.json",
            ],
            resourceRoots: resourceRoots,
            fileManager: fileManager
        )
        let parityManifestURL = firstExistingFile(
            explicitPath: environment["ROACHNET_ROACHWHISPER_PARITY_MANIFEST"],
            named: [
                "RoachSpeech/RoachWhisperParity.json",
                "EmbeddedRuntime/roachspeech/RoachWhisperParity.json",
            ],
            resourceRoots: resourceRoots,
            fileManager: fileManager
        )
        let explicitPackRoots =
            environment["ROACHNET_ROACHSPEECH_MODEL_PACK"]
            .map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
            .map { [$0] }
            ?? []
        let discoveredPacks =
            explicitPackRoots.compactMap { try? RoachSpeechModelPack.load(rootURL: $0, fileManager: fileManager) }
            + RoachSpeechModelPack.discover(in: resourceRoots, fileManager: fileManager)
        let inventory = RoachSpeechRuntimeInventory(
            whisperPack: discoveredPacks.first { $0.manifest.kind == .roachWhisper },
            voicePacks: discoveredPacks.filter { $0.manifest.kind == .roachVoice }
        )
        let stagedWhisperAssets = RoachWhisperAssets(
            encoderModelURL: encoderURL,
            decoderModelURL: decoderURL,
            tokenizerURL: tokenizerURL,
            parityManifestURL: parityManifestURL,
            manifest: nil,
            encoderHasModelFiles: encoderURL.map {
                RoachSpeechModelPack.compiledModelBundleHasPayload($0, fileManager: fileManager)
            } ?? false,
            decoderHasModelFiles: decoderURL.map {
                RoachSpeechModelPack.compiledModelBundleHasPayload($0, fileManager: fileManager)
            } ?? false,
            tokenizerHasContent: tokenizerURL.map { RoachSpeechModelPack.fileHasContent($0, fileManager: fileManager) }
                ?? false,
            parityManifestHasContent: parityManifestURL.map {
                RoachSpeechModelPack.fileHasContent($0, fileManager: fileManager)
            } ?? false
        )
        let roachWhisperAssets = inventory.whisperAssets ?? (stagedWhisperAssets.isStaged ? stagedWhisperAssets : nil)

        return RoachSpeechNativeRuntimeStatus(
            encoderModelPath: encoderURL?.path,
            decoderModelPath: decoderURL?.path,
            tokenizerPath: tokenizerURL?.path,
            parityManifestPath: parityManifestURL?.path,
            coreMLSource: [encoderURL, decoderURL, tokenizerURL, parityManifestURL].allSatisfy { $0 != nil }
                ? "Bundled Core ML" : "Apple Speech fallback",
            usesPackagedBinary: false,
            roachWhisperAssets: roachWhisperAssets,
            roachVoiceAssets: inventory.primaryVoiceAssets,
            voicePackCount: inventory.voicePackCount
        )
    }

    private static func defaultResourceRoots() -> [URL] {
        var roots: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            roots.append(resourceURL)
        }
        let environment = ProcessInfo.processInfo.environment
        for key in ["ROACHNET_STORAGE_PATH", "ROACHNET_STORAGE_ROOT"] {
            if let rawPath = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                !rawPath.isEmpty
            {
                roots.append(URL(fileURLWithPath: NSString(string: rawPath).expandingTildeInPath))
            }
        }
        roots.append(
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("RoachNet/storage", isDirectory: true))
        roots.append(
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("RoachNet/runtime", isDirectory: true))
        roots.append(
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("RoachNet/app/runtime", isDirectory: true))
        return roots
    }

    private static func firstExistingFile(
        explicitPath: String?,
        named paths: [String],
        resourceRoots: [URL],
        fileManager: FileManager
    ) -> URL? {
        let explicit = explicitPath?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlankRoachSpeechPath
            .map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
        let candidates = resourceRoots.flatMap { root in
            paths.map { root.appendingPathComponent($0) }
        }
        let urls = [explicit].compactMap(\.self) + candidates
        return urls.first { url in
            fileManager.fileExists(atPath: url.path)
        }
    }
}

struct RoachSpeechCapabilitySnapshot: Equatable {
    var engineName: String
    var speechToTextBackend: String
    var textToSpeechBackend: String
    var localeIdentifier: String
    var recognizerAvailable: Bool
    var supportsOnDeviceRecognition: Bool
    var voiceName: String
    var nativeRuntime: RoachSpeechNativeRuntimeStatus

    var sttModeLabel: String {
        nativeRuntime.speechToTextReady
            ? "RoachWhisper STT" : (supportsOnDeviceRecognition ? "Apple on-device STT" : "STT unavailable")
    }

    var ttsModeLabel: String {
        "Native TTS"
    }

    var readinessLabel: String {
        if nativeRuntime.speechToTextReady || (recognizerAvailable && supportsOnDeviceRecognition) {
            return "Ready"
        }
        return "Needs model"
    }

    static var unavailable: RoachSpeechCapabilitySnapshot {
        RoachSpeechCapabilitySnapshot(
            engineName: "RoachSpeech",
            speechToTextBackend: RoachSpeechNativeRuntime.status().speechToTextLabel,
            textToSpeechBackend: RoachSpeechNativeRuntime.status().textToSpeechLabel,
            localeIdentifier: Locale.current.identifier,
            recognizerAvailable: false,
            supportsOnDeviceRecognition: false,
            voiceName: "System voice",
            nativeRuntime: RoachSpeechNativeRuntime.status()
        )
    }
}

@MainActor
final class RoachSpeechController: NSObject {
    enum SpeechError: LocalizedError {
        case unavailable
        case onDeviceSpeechUnavailable
        case speechPermissionDenied
        case microphonePermissionDenied
        case startupFailed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "RoachSpeech couldn't start speech recognition on this Mac. You can still type, or try again."
            case .onDeviceSpeechUnavailable:
                return
                    "RoachSpeech needs on-device speech recognition, which isn't available on this Mac. RoachNet won't send your dictation to a server instead. You can still type."
            case .speechPermissionDenied:
                return
                    "RoachNet needs Speech Recognition access to turn your voice prompts into text on this Mac. Allow it in System Settings › Privacy & Security › Speech Recognition. Without it, you can still type."
            case .microphonePermissionDenied:
                return
                    "RoachNet needs microphone access to hear your voice prompts. Allow it in System Settings › Privacy & Security › Microphone. Without it, you can still type."
            case .startupFailed(let detail):
                return "RoachNet couldn't start voice input. You can still type. \(detail)"
            }
        }
    }

    private let audioEngine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var transcriptionUpdate: ((String) -> Void)?
    private var transcriptionFinish: ((String) -> Void)?
    private var speechFinish: ((Bool) -> Void)?
    private var currentTranscript = ""
    private var didFinalizeTranscript = false
    var selectedVoiceProfile = RoachSpeechVoiceProfile.systemDefault
    private lazy var recognizer: SFSpeechRecognizer? = {
        SFSpeechRecognizer(locale: Locale(identifier: "en-US")) ?? SFSpeechRecognizer()
    }()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var capabilitySnapshot: RoachSpeechCapabilitySnapshot {
        guard let recognizer else {
            return .unavailable
        }

        return RoachSpeechCapabilitySnapshot(
            engineName: "RoachSpeech",
            speechToTextBackend: RoachSpeechNativeRuntime.status().speechToTextLabel,
            textToSpeechBackend: RoachSpeechNativeRuntime.status().textToSpeechLabel,
            localeIdentifier: recognizer.locale.identifier,
            recognizerAvailable: recognizer.isAvailable,
            supportsOnDeviceRecognition: recognizer.supportsOnDeviceRecognition,
            voiceName: AVSpeechSynthesisVoice(language: recognizer.locale.identifier)?.name
                ?? AVSpeechSynthesisVoice(language: "en-US")?.name
                ?? "System voice",
            nativeRuntime: RoachSpeechNativeRuntime.status()
        )
    }

    static func microphoneVoiceProject(
        displayName: String,
        recordingURL: URL,
        durationSeconds: Double
    ) -> RoachSpeechCustomVoiceProject {
        RoachSpeechCustomVoiceProject.microphoneProject(
            displayName: displayName,
            sampleURL: recordingURL,
            durationSeconds: durationSeconds
        )
    }

    static func importedVoiceProject(
        displayName: String,
        recordingURL: URL,
        durationSeconds: Double
    ) -> RoachSpeechCustomVoiceProject {
        RoachSpeechCustomVoiceProject.importedProject(
            displayName: displayName,
            sampleURL: recordingURL,
            durationSeconds: durationSeconds
        )
    }

    static func measuredDurationSeconds(for recordingURL: URL) async -> Double? {
        guard recordingURL.isFileURL else { return nil }
        let asset = AVURLAsset(url: recordingURL)
        do {
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            guard seconds.isFinite, seconds > 0 else { return nil }
            return seconds
        } catch {
            return nil
        }
    }

    static func vaultActionPlans(for sourceURL: URL) -> [RoachSpeechVaultActionPlan] {
        RoachSpeechVaultActionPlan.plans(for: sourceURL)
    }

    static func personalVoiceSummary() -> RoachSpeechPersonalVoiceSummary {
        guard #available(macOS 14.0, *) else {
            return .unavailable
        }

        let status = AVSpeechSynthesizer.personalVoiceAuthorizationStatus
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.voiceTraits.contains(.isPersonalVoice) }

        return RoachSpeechPersonalVoiceSummary(
            authorizationLabel: String(describing: status),
            availableVoiceIdentifiers: voices.map(\.identifier),
            availableVoiceNames: voices.map(\.name),
            isAuthorized: status == .authorized,
            isSupported: String(describing: status) != "unsupported"
        )
    }

    static func requestPersonalVoiceAccess() async -> RoachSpeechPersonalVoiceSummary {
        guard #available(macOS 14.0, *) else {
            return .unavailable
        }

        _ = await withCheckedContinuation { continuation in
            AVSpeechSynthesizer.requestPersonalVoiceAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        return personalVoiceSummary()
    }

    func startTranscription(
        onUpdate: @escaping (String) -> Void,
        onFinish: @escaping (String) -> Void
    ) async throws {
        stopTranscription(commitResult: false)

        currentTranscript = ""
        didFinalizeTranscript = false
        transcriptionUpdate = onUpdate
        transcriptionFinish = onFinish

        guard let recognizer, recognizer.isAvailable else {
            throw SpeechError.unavailable
        }

        try await requestPermissions()

        guard recognizer.supportsOnDeviceRecognition else {
            throw SpeechError.onDeviceSpeechUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true

        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            Task { @MainActor in
                if let result {
                    self.currentTranscript = result.bestTranscription.formattedString
                    self.transcriptionUpdate?(self.currentTranscript)

                    if result.isFinal {
                        self.didFinalizeTranscript = true
                        self.finishTranscription(notify: true)
                        return
                    }
                }

                if error != nil {
                    self.finishTranscription(notify: true)
                }
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            recognitionTask?.cancel()
            recognitionTask = nil
            recognitionRequest = nil
            throw SpeechError.startupFailed(error.localizedDescription)
        }
    }

    func stopTranscription(commitResult: Bool = true) {
        finishTranscription(notify: commitResult && !didFinalizeTranscript)
    }

    func speak(_ text: String, completion: @escaping (Bool) -> Void) {
        stopSpeaking()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(false)
            return
        }

        speakWithNativeSynthesizer(trimmed, completion: completion)
    }

    func stopSpeaking() {
        guard synthesizer.isSpeaking else {
            speechFinish?(false)
            speechFinish = nil
            return
        }

        synthesizer.stopSpeaking(at: .immediate)
    }

    private func speakWithNativeSynthesizer(_ text: String, completion: @escaping (Bool) -> Void) {
        let utterance = AVSpeechUtterance(string: text)
        if let identifier = selectedVoiceProfile.systemVoiceIdentifier,
            let voice = AVSpeechSynthesisVoice(identifier: identifier)
        {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        }
        utterance.rate = 0.48
        utterance.pitchMultiplier = 0.94
        utterance.volume = 0.92
        utterance.prefersAssistiveTechnologySettings = true

        speechFinish = completion
        synthesizer.speak(utterance)
    }

    private func requestPermissions() async throws {
        let speechAuth = await Self.requestSpeechAuthorization()
        guard speechAuth == .authorized else {
            throw SpeechError.speechPermissionDenied
        }

        try await requestMicrophonePermission()
    }

    private func requestMicrophonePermission() async throws {
        let microphoneAllowed = await Self.requestMicrophoneAuthorization()
        guard microphoneAllowed else {
            throw SpeechError.microphonePermissionDenied
        }
    }

    private func finishTranscription(notify: Bool) {
        if audioEngine.isRunning {
            audioEngine.stop()
        }

        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        recognitionRequest = nil
        recognitionTask = nil

        let finalTranscript = currentTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let finishHandler = transcriptionFinish

        currentTranscript = ""
        didFinalizeTranscript = false
        transcriptionUpdate = nil
        transcriptionFinish = nil

        if notify {
            finishHandler?(finalTranscript)
        }
    }

    private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private static func requestMicrophoneAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { allowed in
                continuation.resume(returning: allowed)
            }
        }
    }

    private func finishSpeechPlayback(_ finished: Bool) {
        let completion = speechFinish
        speechFinish = nil
        completion?(finished)
    }
}

extension RoachSpeechController: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.finishSpeechPlayback(true)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.finishSpeechPlayback(false)
        }
    }
}

extension String {
    fileprivate var nilIfBlankRoachSpeechPath: String? {
        isEmpty ? nil : self
    }
}
