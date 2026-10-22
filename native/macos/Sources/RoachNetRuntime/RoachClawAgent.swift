import Foundation

enum RoachClawAgent {
    static let runtime = "roachclaw-native-agent"
    static let reviewedHermesHead = "5fc308a70719a83cccdbba4c0e39c23f5a8239d5"

    static let skills: [JSON] = [
        [
            "id": "app-context-router", "title": "App context router",
            "description": "Builds a permissioned context packet from the current RoachNet surface.",
            "runtime": "roachclaw-native",
        ],
        [
            "id": "dev-agent", "title": "Dev agent",
            "description": "Uses visible editor, terminal, diagnostics, and release-gate context for coding work.",
            "runtime": "roachclaw-native",
        ],
        [
            "id": "vault-research", "title": "Vault research",
            "description": "Indexes local notes, books, media, and archive records without hidden cloud custody.",
            "runtime": "roachclaw-native",
        ],
        [
            "id": "arcade-copilot", "title": "Arcade copilot",
            "description":
                "Explains games, mods, controllers, emulators, save state, and cheat context inside RoachArcade.",
            "runtime": "roachclaw-native",
        ],
        [
            "id": "release-gate-operator", "title": "Release gate operator",
            "description":
                "Turns build, installer, update, and public-surface checks into explicit verification packets.",
            "runtime": "roachclaw-native",
        ],
        [
            "id": "memory-curator", "title": "Memory curator",
            "description": "Reads and writes RoachBrain records under the user-owned RoachNet storage root.",
            "runtime": "roachclaw-native",
        ],
    ]

    static let scopeLabels: [String: String] = [
        "roachnet": "RoachNet shell", "dev": "Dev workspace", "vault": "Vault", "archives": "Captured archives",
        "arcade": "RoachArcade", "maps": "Maps", "media": "Media", "settings": "Settings", "runtime": "Runtime",
    ]

    static func cleanString(_ value: JSON) -> String {
        (value.isNullish ? "" : value.jsString).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func cleanScope(_ value: JSON) -> String {
        JS.replace("[^a-z0-9_-]", in: cleanString(value).lowercased(), with: "")
    }

    static func uniqueScopes(_ values: [JSON]) -> [String] {
        var output: [String] = []
        for value in values {
            let normalized = cleanScope(value)
            if normalized.isEmpty || output.contains(normalized) { continue }
            output.append(normalized)
        }
        return output
    }

    static func clampInt(_ value: JSON, _ fallback: Int, _ minimum: Int, _ maximum: Int) -> Int {
        let text = (value.isNullish ? "" : value.jsString).trimmingCharacters(in: .whitespacesAndNewlines)
        var digits = ""
        for (index, character) in text.enumerated() {
            if character.isASCII && character.isNumber {
                digits.append(character)
                continue
            }
            if index == 0 && (character == "-" || character == "+") {
                digits.append(character)
                continue
            }
            break
        }
        guard let parsed = Int(digits) else { return fallback }
        return max(minimum, min(maximum, parsed))
    }

    static func safeContextValue(_ value: JSON, _ maxCharacters: Int) -> String {
        if value.isNullish { return "" }
        let raw = value.stringValue ?? value.prettySerialized()
        var normalized = JS.replace("\\s+\\n", in: raw, with: "\n")
        normalized = JS.replace("\\n{3,}", in: normalized, with: "\n\n")
        normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.utf16.count > maxCharacters {
            let head = JS.slice(normalized, max(0, maxCharacters - 32))
            let trimmed = head.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            return "\(trimmed)\n[truncated locally]"
        }
        return normalized
    }

    static func workspace(_ storageRoot: String) -> String { Path.join(storageRoot, "RoachClaw") }

    static func status(
        storageRoot: String, defaultModel: String, resolvedDefaultModel: String, installedModels: [String] = [],
        ollamaAvailable: Bool = false
    ) -> JSON {
        let modelReady = installedModels.contains(resolvedDefaultModel.isEmpty ? defaultModel : resolvedDefaultModel)
        return [
            "runtime": JSON(runtime),
            "mode": "native-rewrite",
            "upstreamRuntimeDependency": "none",
            "localOnly": true,
            "ready": JSON(ollamaAvailable && modelReady),
            "workspacePath": JSON(workspace(storageRoot)),
            "defaultModel": JSON(defaultModel),
            "resolvedDefaultModel": JSON(resolvedDefaultModel),
            "skills": .array(skills),
            "policy": [
                "defaultExecutionMode": "plan-only",
                "requiresApprovalFor": ["shell.write", "file.write", "network", "browser", "installer", "destructive"],
            ],
            "toolPolicy": [
                "defaultExecutionMode": "plan-only",
                "approvalRequiredFor": ["shell", "file-write", "network", "browser", "installer", "destructive"],
                "deniedByDefault": ["credential-exfiltration", "silent-network-sync", "unreviewed-destructive-action"],
            ],
            "budgets": [
                "contextCharacters": 12000,
                "planMaxTokens": 4096,
                "evaluatorMaxTokens": 4096,
                "maxToolLoopAttempts": 3,
            ],
            "memory": [
                "provider": "roachbrain",
                "storagePath": JSON(Path.join(storageRoot, "roachbrain")),
                "profileIsolation": "per-storage-root",
            ],
            "references": [
                "hermesAgent": [
                    "role": "design-reference-only",
                    "reviewedHead": JSON(reviewedHermesHead),
                    "upstreamRuntimeDependency": false,
                    "vendoredCode": false,
                ],
                "openClaw": [
                    "role": "migration-reference-only",
                    "bundledRuntime": false,
                ],
            ],
        ]
    }

    static func buildPrompt(_ body: JSON, status: JSON) throws -> JSON {
        let prompt = cleanString(body["prompt"] || body["userPrompt"])
        if prompt.isEmpty { throw RuntimeError("RoachClaw agent prompt is required.") }
        let budgetFallback = Int((status["budgets"]["contextCharacters"] || 12000).jsNumber)
        let contextBudget = clampInt(body["contextBudget"] || body["budgetCharacters"], budgetFallback, 1_000, 64_000)
        let enabledScopes = uniqueScopes(body["enabledScopes"].arrayValue ?? ["roachnet"])
        let context = body["context"].isObject ? body["context"] : .object(JSONObject())
        let activeSurface =
            cleanString(body["activeSurface"]).isEmpty
            ? (cleanString(body["surface"]).isEmpty ? "RoachNet" : cleanString(body["surface"]))
            : cleanString(body["activeSurface"])
        let perScopeBudget = max(600, contextBudget / max(1, enabledScopes.count))

        var contextLines: [String] = []
        for scope in enabledScopes {
            let excerpt = safeContextValue(context[scope], perScopeBudget)
            if excerpt.isEmpty { continue }
            contextLines.append("## \(scopeLabels[scope] ?? scope)\n\(excerpt)")
        }
        let contextBlock =
            contextLines.isEmpty
            ? "No permissioned context supplied. Ask for access before relying on hidden app state."
            : contextLines.joined(separator: "\n\n")
        let model =
            cleanString(body["model"]).isEmpty
            ? (status["resolvedDefaultModel"] || status["defaultModel"])
            : JSON(cleanString(body["model"]))
        let system = [
            "RoachClaw is RoachNet's native local agent spine.",
            "Use only the permissioned context in this packet.",
            "Name the smallest useful next action.",
            "Never claim a command ran, a file changed, or a release shipped unless a RoachNet tool lane performed it.",
            "Request approval before shell, file-write, network, browser, installer, or destructive actions.",
        ].joined(separator: "\n")
        let user = [
            "Task: \(prompt)",
            "Active surface: \(activeSurface)",
            "Enabled scopes: \(enabledScopes.isEmpty ? "none" : enabledScopes.joined(separator: ", "))",
            "",
            "Permissioned context:",
            contextBlock,
        ].joined(separator: "\n")
        return [
            "model": model,
            "messages": [
                ["role": "system", "content": JSON(system)],
                ["role": "user", "content": JSON(user)],
            ],
            "enabledScopes": jsonStrings(enabledScopes),
            "includedScopes": jsonStrings(
                enabledScopes.filter { !safeContextValue(context[$0], perScopeBudget).isEmpty }),
            "activeSurface": JSON(activeSurface),
            "contextCharacters": JSON(contextBlock.utf16.count),
        ]
    }

    static func createRun(_ body: JSON, status: JSON) throws -> JSON {
        let prompt = try buildPrompt(body, status: status)
        let requestedExecution = body["execute"] == .bool(true)
        return [
            "runtime": JSON(runtime),
            "upstreamRuntimeDependency": "none",
            "executed": false,
            "executionMode": JSON(requestedExecution ? "approval-required" : "plan-only"),
            "prompt": prompt,
            "plan": [
                "summary": JSON(
                    requestedExecution
                        ? "Prepared a native RoachClaw agent packet. Execution is blocked until explicit tool approval is wired for this action."
                        : "Prepared a native RoachClaw agent packet without executing tools."),
                "steps": [
                    "Read only the permissioned RoachNet context.",
                    "Draft the smallest useful response or tool plan.",
                    "Ask for approval before any shell, file-write, network, browser, installer, or destructive action.",
                    "Record useful outcomes back into local RoachBrain memory after verification.",
                ],
            ],
            "toolPolicy": status["toolPolicy"],
            "budgets": status["budgets"],
        ]
    }
}
