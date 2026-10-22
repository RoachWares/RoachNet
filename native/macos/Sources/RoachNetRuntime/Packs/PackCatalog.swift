import Foundation

public enum PackCatalog {
    public static let appVersion = "1.1.0"

    public static let bundledCapabilityPacks: [PackManifest] = [
        PackManifest(
            id: "roachclaw", version: appVersion, kind: .capability, name: "RoachClaw",
            summary: "Local AI chat, voice, context and the native RoachInference engine.",
            capabilities: [.inference, .microphone, .speaker, .filesystemStorage],
            dataRoots: [
                PackDataRoot(path: "RoachClaw", description: "Conversations, memories, playbooks and provider settings")
            ]
        ),
        PackManifest(
            id: "org", version: appVersion, kind: .capability, name: "RoachClaw Org",
            summary: "A company of local agents with approvals, budgets and routines.",
            dependencies: [PackDependency(id: "roachclaw", minimumVersion: "1.1.0")],
            capabilities: [.inference, .networkLocal, .companionBridge],
            dataRoots: [
                PackDataRoot(path: "RoachClaw/org", description: "Companies, agents, issues, approvals and run logs")
            ]
        ),
        PackManifest(
            id: "dev", version: appVersion, kind: .capability, name: "RoachNet Dev",
            summary: "Editor, terminal and inline RoachClaw assist for local projects.",
            dependencies: [PackDependency(id: "roachclaw")],
            capabilities: [.processSpawn, .filesystemUser, .inference],
            dataRoots: [PackDataRoot(path: "dev", description: "Workspace state and terminal history")]
        ),
        PackManifest(
            id: "vault", version: appVersion, kind: .capability, name: "RoachNet Vault",
            summary: "Notes, books, captures and media on a local shelf with built-in readers.",
            capabilities: [.filesystemStorage, .filesystemUser],
            dataRoots: [PackDataRoot(path: "Vault", description: "Everything on the Vault shelf")]
        ),
        PackManifest(
            id: "arcade", version: appVersion, kind: .capability, name: "RoachArcade",
            summary: "ROM library, runners, mods and cheats.",
            capabilities: [.processSpawn, .filesystemUser],
            dataRoots: [
                PackDataRoot(path: "RoachArcade", description: "Library metadata, save states and runner settings")
            ]
        ),
        PackManifest(
            id: "maps", version: appVersion, kind: .capability, name: "RoachNet Maps",
            summary: "Offline atlas, map packs and the phone GPS bridge.",
            capabilities: [.networkPublic, .bluetooth, .location],
            dataRoots: [PackDataRoot(path: "maps", description: "Downloaded map collections and saved places")]
        ),
        PackManifest(
            id: "education", version: appVersion, kind: .capability, name: "Knowledge shelf",
            summary: "Offline reference bundles (Wikipedia and other ZIM archives).",
            capabilities: [.networkPublic, .filesystemStorage],
            dataRoots: [PackDataRoot(path: "zim", description: "Downloaded knowledge bundles")]
        ),
        PackManifest(
            id: "speech", version: appVersion, kind: .capability, name: "RoachSpeech",
            summary: "On-device speech to text and text to speech. Voice packs install separately.",
            dependencies: [PackDependency(id: "roachclaw")],
            capabilities: [.microphone, .speaker],
            dataRoots: [PackDataRoot(path: "RoachSpeech", description: "Installed voice and transcription packs")]
        ),
        PackManifest(
            id: "companion", version: appVersion, kind: .capability, name: "RoachTail companion bridge",
            summary: "Pair iPhones and iPads over RoachTail.",
            capabilities: [.networkLocal, .companionBridge],
            dataRoots: [
                PackDataRoot(path: "state/runtime-state/roachtail", description: "Paired devices and join codes")
            ]
        ),
    ]
}
