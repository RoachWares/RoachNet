import AppKit
import Foundation
import RoachNetCore
import RoachNetDesign
import SwiftUI

struct DeveloperFileNode: Identifiable, Hashable {
    let id: String
    let url: URL
    let relativePath: String
    let isDirectory: Bool
    let children: [DeveloperFileNode]?

    var name: String {
        url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
    }
}

struct DeveloperDocument: Identifiable, Hashable {
    let id: String
    let url: URL
    let relativePath: String
    var text: String
    var isDirty: Bool
}

struct SecretScopeSummary: Identifiable, Hashable {
    let id: String
    let title: String
    let count: Int
}

struct DeveloperInlineSuggestion: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let snippet: String
}

struct DeveloperAssistTurn: Identifiable, Hashable {
    let id: String
    let prompt: String
    let mode: DeveloperAssistMode
    let responsePreview: String
    let createdAt: Date
}

struct DeveloperWorkspaceShortcut: Identifiable {
    let id: String
    let title: String
    let displayName: String
    let path: String
    let accent: Color
}

struct DeveloperGuidebookResource: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let url: String
    let tags: [String]
}

enum DeveloperTerminalTheme: String, CaseIterable, Identifiable {
    case roach = "Roach"
    case phosphor = "Phosphor"
    case ember = "Ember"
    case midnight = "Midnight"

    var id: String { rawValue }

    var detail: String {
        switch self {
        case .roach:
            return "Green signal, black glass."
        case .phosphor:
            return "Soft CRT glow."
        case .ember:
            return "Warm workshop light."
        case .midnight:
            return "Quiet blue console."
        }
    }

    var accent: Color {
        switch self {
        case .roach:
            return RoachPalette.green
        case .phosphor:
            return RoachPalette.cyan
        case .ember:
            return RoachPalette.warning
        case .midnight:
            return RoachPalette.magenta
        }
    }

    var outputForeground: Color {
        switch self {
        case .roach:
            return RoachPalette.text
        case .phosphor:
            return RoachPalette.cyan.opacity(0.94)
        case .ember:
            return Color(red: 1.0, green: 0.78, blue: 0.48)
        case .midnight:
            return Color(red: 0.80, green: 0.88, blue: 1.0)
        }
    }

    var mutedForeground: Color {
        switch self {
        case .roach:
            return RoachPalette.muted
        case .phosphor:
            return RoachPalette.cyan.opacity(0.58)
        case .ember:
            return Color(red: 1.0, green: 0.70, blue: 0.42).opacity(0.64)
        case .midnight:
            return Color(red: 0.62, green: 0.70, blue: 0.86)
        }
    }

    var backgroundColors: [Color] {
        switch self {
        case .roach:
            return [Color.black.opacity(0.50), Color.black.opacity(0.34), RoachPalette.green.opacity(0.08)]
        case .phosphor:
            return [
                Color.black.opacity(0.54), Color(red: 0.01, green: 0.12, blue: 0.11).opacity(0.74),
                RoachPalette.cyan.opacity(0.10),
            ]
        case .ember:
            return [
                Color.black.opacity(0.52), Color(red: 0.18, green: 0.07, blue: 0.02).opacity(0.78),
                RoachPalette.warning.opacity(0.11),
            ]
        case .midnight:
            return [
                Color.black.opacity(0.54), Color(red: 0.02, green: 0.05, blue: 0.14).opacity(0.86),
                RoachPalette.magenta.opacity(0.10),
            ]
        }
    }
}

enum DeveloperAssistMode: String, CaseIterable, Identifiable {
    case agent = "Agent"
    case plan = "Plan"
    case implement = "Implement"
    case debug = "Debug"
    case review = "Review"

    var id: String { rawValue }

    var detail: String {
        switch self {
        case .agent:
            return "Run the task loop: inspect, act, verify, record."
        case .plan:
            return "Lay out the next steps in order."
        case .implement:
            return "Write the change and prove it."
        case .debug:
            return "Find the likely cause, the quickest fix and a way to prove it."
        case .review:
            return "Call out risk, regressions, and missing tests."
        }
    }

    var systemName: String {
        switch self {
        case .agent:
            return "terminal.fill"
        case .plan:
            return "point.topleft.down.curvedto.point.bottomright.up"
        case .implement:
            return "hammer.fill"
        case .debug:
            return "stethoscope"
        case .review:
            return "checklist.checked"
        }
    }

    var accent: Color {
        switch self {
        case .agent:
            return RoachPalette.green
        case .plan:
            return RoachPalette.cyan
        case .implement:
            return RoachPalette.green
        case .debug:
            return RoachPalette.warning
        case .review:
            return RoachPalette.magenta
        }
    }

    var instruction: String {
        switch self {
        case .agent:
            return
                "Operate like a task runner inside the RoachNet Dev Studio. Use the open file, local memory, compiled wiki, terminal context, and explicit app context. Give the smallest concrete action, include patch-ready code when a file should change, and name the verification command or signal. Never claim a command ran or a file changed unless RoachNet actually performed it."
        case .plan:
            return
                "Break the request into the next concrete implementation steps. Keep it short, ordered, and biased toward what should happen first."
        case .implement:
            return
                "Prefer direct code changes, exact commands, and the smallest safe implementation path. Include verification commands when they matter."
        case .debug:
            return
                "Diagnose the most likely root cause, explain the signal that supports it, and propose the fastest fix plus the fastest proof."
        case .review:
            return
                "Use a code-review mindset. Prioritize bugs, regressions, weak assumptions, and missing tests before summarizing anything else."
        }
    }
}

@MainActor
final class DevWorkspaceModel: ObservableObject {
    @Published var storagePath = ""
    @Published var workspaceRootPath = ""
    @Published var projectsRootPath = ""
    @Published var installPath = ""
    @Published var importStatus = "Dev is ready."
    @Published var lastError: String?
    @Published var fileSearchQuery = ""
    @Published var fileTree: [DeveloperFileNode] = []
    @Published var openDocuments: [DeveloperDocument] = []
    @Published var activeDocumentID: String? {
        didSet {
            prepareInlineCompletion()
            syncLiveTerminalWorkingDirectory()
        }
    }
    @Published var terminalCommand = ""
    @Published var terminalOutput = ""
    @Published var terminalIsRunning = false
    @Published var terminalAwaitingPrompt = false
    @Published var terminalStatus = "Opening the shell."
    @Published var terminalRecentCommands: [String] = []
    @Published var terminalWorkingDirectoryOverride = ""
    @Published var terminalReportedWorkingDirectory = ""
    @Published var lastTerminalExitCode: Int32?
    @Published var terminalTheme: DeveloperTerminalTheme = .roach
    @Published var terminalFontSize: CGFloat = 12
    @Published var terminalSoftWrap = true
    @Published var inlineCompletion = ""
    @Published var inlineCompletionIsLoading = false
    @Published var inlineCompletionStatus = "Open a file. RoachClaw reads the end of it and suggests the next lines."
    @Published var aiPrompt = "Read this file and suggest the next clean edit."
    @Published var assistantMode: DeveloperAssistMode = .implement
    @Published var aiResponse = ""
    @Published var aiIsRunning = false
    @Published var assistantTurns: [DeveloperAssistTurn] = []
    @Published var secretRecords: [RoachNetSecretRecord] = []
    @Published var selectedSecretID: String?
    @Published var secretLabelDraft = ""
    @Published var secretKeyDraft = ""
    @Published var secretScopeDraft = ""
    @Published var secretNotesDraft = ""
    @Published var secretValueDraft = ""
    @Published var revealedSecretValue = ""
    @Published var roachBrainQuery = ""
    @Published var roachBrainMemories: [RoachBrainMemory] = []
    @Published var roachBrainStatus = "Local memory is ready."

    private var terminalSession: DeveloperTerminalSession?
    private var queuedTerminalCommand: String?
    private var terminalDidReachPrompt = false
    private let dateFormatter = ISO8601DateFormatter()
    private let assistantFileContextLimit = 8_000
    private let inlineTailContextLimit = 2_200
    private let inlineOpeningContextLimit = 600
    private let automaticInlineMaxDocumentCharacters = 180_000

    var activeDocument: DeveloperDocument? {
        guard let activeDocumentID else { return nil }
        return openDocuments.first(where: { $0.id == activeDocumentID })
    }

    var selectedSecret: RoachNetSecretRecord? {
        guard let selectedSecretID else { return nil }
        return secretRecords.first(where: { $0.id == selectedSecretID })
    }

    var suggestedTemplates: [RoachNetSecretTemplate] {
        RoachNetSecretsCatalogStore.suggestedTemplates
    }

    var secretScopeSummary: [SecretScopeSummary] {
        Dictionary(grouping: suggestedTemplates, by: \.scope)
            .map { scope, templates in
                SecretScopeSummary(id: scope, title: scope, count: templates.count)
            }
            .sorted { lhs, rhs in
                if lhs.count == rhs.count {
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                return lhs.count > rhs.count
            }
    }

    var currentProjectName: String {
        if let firstSegment = activeDocument?.relativePath.split(separator: "/").first {
            return String(firstSegment)
        }
        return fileTree.first?.name ?? "Workspace"
    }

    var activeDocumentLabel: String {
        activeDocument?.relativePath ?? "No file open"
    }

    var inlinePromptDirective: DeveloperInlinePromptDirective? {
        guard let activeDocument else { return nil }
        return DeveloperInlineAssistSupport.promptDirective(
            in: activeDocument.text,
            fileExtension: activeDocument.url.pathExtension
        )
    }

    var activeDocumentLineCount: Int {
        guard let activeDocument else { return 0 }
        return max(activeDocument.text.components(separatedBy: .newlines).count, 1)
    }

    var activeDocumentCharacterCount: Int {
        activeDocument?.text.count ?? 0
    }

    var isTerminalFollowingActiveContext: Bool {
        terminalWorkingDirectoryOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var terminalHistoryCount: Int {
        terminalRecentCommands.count
    }

    private var activeProjectRootPath: String? {
        guard
            let firstSegment = activeDocument?.relativePath.split(separator: "/").first,
            !projectsRootPath.isEmpty
        else {
            return nil
        }

        return URL(fileURLWithPath: projectsRootPath)
            .appendingPathComponent(String(firstSegment), isDirectory: true)
            .path
    }

    var terminalDirectoryShortcuts: [DeveloperWorkspaceShortcut] {
        var shortcuts: [DeveloperWorkspaceShortcut] = []
        var seenPaths = Set<String>()

        func appendShortcut(title: String, path: String?, accent: Color) {
            guard let path else { return }
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seenPaths.insert(trimmed).inserted else { return }
            shortcuts.append(
                DeveloperWorkspaceShortcut(
                    id: title + "::" + trimmed,
                    title: title,
                    displayName: DeveloperWorkspacePathLabel.displayName(title: title, path: trimmed),
                    path: trimmed,
                    accent: accent
                )
            )
        }

        appendShortcut(title: "Workspace", path: projectsRootPath, accent: RoachPalette.green)
        appendShortcut(title: "Project root", path: activeProjectRootPath, accent: RoachPalette.bronze)
        appendShortcut(
            title: "Active file", path: activeDocument?.url.deletingLastPathComponent().path, accent: RoachPalette.cyan)
        appendShortcut(title: "Install", path: installPath, accent: RoachPalette.magenta)
        return shortcuts
    }

    var activeDocumentPathComponents: [String] {
        guard let activeDocument else { return [] }
        return activeDocument.relativePath.split(separator: "/").map(String.init)
    }

    var terminalOutputLineCount: Int {
        max(terminalOutput.components(separatedBy: .newlines).count, terminalOutput.isEmpty ? 0 : 1)
    }

    var terminalViewportHeight: CGFloat {
        terminalSoftWrap ? 170 : 220
    }

    var activeDocumentLanguage: String {
        guard let pathExtension = activeDocument?.url.pathExtension.lowercased(), !pathExtension.isEmpty else {
            return "Plain Text"
        }

        switch pathExtension {
        case "swift": return "Swift"
        case "ts": return "TypeScript"
        case "tsx": return "TSX"
        case "js": return "JavaScript"
        case "jsx": return "JSX"
        case "json": return "JSON"
        case "md": return "Markdown"
        case "yml", "yaml": return "YAML"
        case "sh", "zsh": return "Shell"
        default: return pathExtension.uppercased()
        }
    }

    var roachBrainSuggestedMatches: [RoachBrainMatch] {
        let query = [aiPrompt, activeDocumentLabel, currentProjectName]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " ")
        return RoachBrainStore.search(roachBrainMemories, query: query, tags: roachBrainContextTags, limit: 4)
    }

    var roachBrainVisibleMatches: [RoachBrainMatch] {
        let trimmedQuery = roachBrainQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuery.isEmpty {
            return Array(
                roachBrainMemories
                    .sorted { lhs, rhs in
                        if lhs.pinned != rhs.pinned {
                            return lhs.pinned && !rhs.pinned
                        }
                        return lhs.lastAccessedAt > rhs.lastAccessedAt
                    }
                    .prefix(5)
                    .map { RoachBrainMatch(memory: $0, score: $0.pinned ? 100 : 10, matchedTags: []) }
            )
        }

        return RoachBrainStore.search(roachBrainMemories, query: trimmedQuery, tags: roachBrainContextTags, limit: 6)
    }

    var roachBrainPinnedCount: Int {
        roachBrainMemories.filter(\.pinned).count
    }

    var inlineSuggestions: [DeveloperInlineSuggestion] {
        guard let activeDocument else { return [] }

        let pathExtension = activeDocument.url.pathExtension.lowercased()
        let fileName = activeDocument.url.deletingPathExtension().lastPathComponent
        let identifier = swiftIdentifier(from: fileName)

        switch pathExtension {
        case "swift":
            return [
                DeveloperInlineSuggestion(
                    id: "swift-task",
                    title: "Insert async task",
                    detail: "Drop in an async entry point you can wire immediately.",
                    snippet: """

                        Task {
                            do {
                                try await Task.sleep(for: .milliseconds(250))
                            } catch {
                                print(error.localizedDescription)
                            }
                        }
                        """
                ),
                DeveloperInlineSuggestion(
                    id: "swift-struct",
                    title: "Insert typed scaffold",
                    detail: "A small typed unit for the active file.",
                    snippet: """

                        struct \(identifier)State {
                            var title = "\(fileName)"
                            var updatedAt = Date()
                        }
                        """
                ),
            ]
        case "ts", "tsx":
            return [
                DeveloperInlineSuggestion(
                    id: "ts-async",
                    title: "Insert async function",
                    detail: "Drop in an async implementation stub.",
                    snippet: """

                        export async function \(identifier.prefix(1).lowercased() + identifier.dropFirst())Action(): Promise<void> {
                          console.log('\(fileName) action ready')
                        }
                        """
                ),
                DeveloperInlineSuggestion(
                    id: "ts-test",
                    title: "Insert test outline",
                    detail: "A focused test block for the current module.",
                    snippet: """

                        describe('\(fileName)', () => {
                          it('stays ready for the next implementation pass', () => {
                            expect(true).toBe(true)
                          })
                        })
                        """
                ),
            ]
        case "js", "jsx":
            return [
                DeveloperInlineSuggestion(
                    id: "js-async",
                    title: "Insert async function",
                    detail: "A clean async helper for the current file.",
                    snippet: """

                        export async function ${fileName}Action() {
                          console.log('\(fileName) action ready')
                        }
                        """.replacingOccurrences(
                            of: "${fileName}", with: fileName.replacingOccurrences(of: "-", with: "_"))
                ),
                DeveloperInlineSuggestion(
                    id: "js-cli",
                    title: "Insert CLI guard",
                    detail: "Useful for scripts that should run directly.",
                    snippet: """

                        if (import.meta.url === `file://${process.argv[1]}`) {
                          console.log('\(fileName) is running directly')
                        }
                        """
                ),
            ]
        case "py":
            return [
                DeveloperInlineSuggestion(
                    id: "py-main",
                    title: "Insert main guard",
                    detail: "A direct-run entry point for the active Python file.",
                    snippet: """

                        def main() -> None:
                            print("\(fileName) is ready.")


                        if __name__ == "__main__":
                            main()
                        """
                ),
                DeveloperInlineSuggestion(
                    id: "py-test",
                    title: "Insert pytest check",
                    detail: "A tiny first test you can build from.",
                    snippet: """

                        def test_\(fileName.replacingOccurrences(of: "-", with: "_"))_stays_ready() -> None:
                            assert True
                        """
                ),
            ]
        case "go":
            return [
                DeveloperInlineSuggestion(
                    id: "go-func",
                    title: "Insert helper function",
                    detail: "A small helper you can wire into main immediately.",
                    snippet: """

                        func \(identifier.prefix(1).lowercased() + identifier.dropFirst())Status() string {
                            return "\(fileName) is ready."
                        }
                        """
                ),
                DeveloperInlineSuggestion(
                    id: "go-test",
                    title: "Insert test outline",
                    detail: "A starter test block for the active package.",
                    snippet: """

                        func Test\(identifier)(t *testing.T) {
                            if got := \(identifier.prefix(1).lowercased() + identifier.dropFirst())Status(); got == "" {
                                t.Fatal("expected a non-empty status")
                            }
                        }
                        """
                ),
            ]
        case "rs":
            return [
                DeveloperInlineSuggestion(
                    id: "rs-func",
                    title: "Insert helper function",
                    detail: "A small Rust helper for the active file.",
                    snippet: """

                        fn \(fileName.replacingOccurrences(of: "-", with: "_"))_status() -> &'static str {
                            "\(fileName) is ready."
                        }
                        """
                ),
                DeveloperInlineSuggestion(
                    id: "rs-test",
                    title: "Insert test module",
                    detail: "A starter unit test for the current file.",
                    snippet: """

                        #[cfg(test)]
                        mod tests {
                            use super::*;

                            #[test]
                            fn status_is_not_empty() {
                                assert!(!\(fileName.replacingOccurrences(of: "-", with: "_"))_status().is_empty());
                            }
                        }
                        """
                ),
            ]
        case "cs":
            return [
                DeveloperInlineSuggestion(
                    id: "cs-method",
                    title: "Insert method stub",
                    detail: "A simple C# method for the active program.",
                    snippet: """

                        static string \(identifier)Status()
                        {
                            return "\(fileName) is ready.";
                        }
                        """
                )
            ]
        case "sh", "zsh":
            return [
                DeveloperInlineSuggestion(
                    id: "sh-safety",
                    title: "Insert safety header",
                    detail: "Keep shell scripts predictable from the start.",
                    snippet: """

                        set -euo pipefail
                        IFS=$'\\n\\t'
                        """
                ),
                DeveloperInlineSuggestion(
                    id: "sh-usage",
                    title: "Insert usage block",
                    detail: "A short usage message for the script.",
                    snippet: """

                        usage() {
                          echo "usage: $0 [args]"
                        }
                        """
                ),
            ]
        case "md":
            return [
                DeveloperInlineSuggestion(
                    id: "md-checklist",
                    title: "Insert next-step checklist",
                    detail: "Keep the active note actionable.",
                    snippet: """

                        ## Next Steps

                        - Confirm the implementation path
                        - Record the runtime assumptions
                        - Add the verification command before release
                        """
                )
            ]
        default:
            return [
                DeveloperInlineSuggestion(
                    id: "plain-next-step",
                    title: "Insert next-step block",
                    detail: "A compact planning block for the current file.",
                    snippet: """

                        // Next step:
                        // - Define the next concrete change
                        // - Record the verification command
                        """
                )
            ]
        }
    }

    var filteredFileTree: [DeveloperFileNode] {
        let query = fileSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return fileTree }
        return filterNodes(fileTree, query: query.lowercased())
    }

    let starterProjectLanguages: [String] = [
        "Swift",
        "TypeScript",
        "JavaScript",
        "Python",
        "Go",
        "Rust",
        "C#",
        "Shell",
    ]

    func configure(storagePath: String, installPath: String) {
        let workspaceRootPath = RoachNetDeveloperPaths.workspaceRoot(storagePath: storagePath)
        let projectsRootPath = RoachNetDeveloperPaths.projectsRoot(storagePath: storagePath)

        self.storagePath = storagePath

        if self.workspaceRootPath == workspaceRootPath,
            self.projectsRootPath == projectsRootPath,
            self.installPath == installPath,
            !fileTree.isEmpty || !secretRecords.isEmpty || !roachBrainMemories.isEmpty
        {
            ensureTerminalSessionIfNeeded()
            return
        }

        self.workspaceRootPath = workspaceRootPath
        self.projectsRootPath = projectsRootPath
        self.installPath = installPath

        if !terminalWorkingDirectoryOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !FileManager.default.fileExists(atPath: terminalWorkingDirectoryOverride)
        {
            terminalWorkingDirectoryOverride = ""
        }

        do {
            try RoachNetDeveloperPaths.ensureWorkspaceDirectories(storagePath: storagePath)
            try seedWorkspaceIfNeeded()
            reloadWorkspace()
            loadSecrets(storagePath: storagePath)
            loadRoachBrain(storagePath: storagePath)
            ensureTerminalSessionIfNeeded()
            importStatus = "Dev is ready."
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            importStatus = "Couldn't load the workspace."
        }
    }

    func reloadWorkspace() {
        guard !projectsRootPath.isEmpty else { return }

        do {
            fileTree = try buildFileNodes(
                at: URL(fileURLWithPath: projectsRootPath), root: URL(fileURLWithPath: projectsRootPath))
            if activeDocument == nil, let firstFile = firstFileNode(in: fileTree) {
                try open(node: firstFile)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func importProject() {
        guard !projectsRootPath.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = "Import a project into RoachNet"
        panel.message = "Choose a folder to copy into the RoachNet developer workspace."
        panel.prompt = "Import"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }

        do {
            let destinationRoot = URL(fileURLWithPath: projectsRootPath)
            let destinationURL = destinationRoot.appendingPathComponent(sourceURL.lastPathComponent, isDirectory: true)
            let fileManager = FileManager.default

            if fileManager.fileExists(atPath: destinationURL.path) {
                throw NSError(
                    domain: "RoachNetDevWorkspace",
                    code: 4,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "A project named \(sourceURL.lastPathComponent) is already in the RoachNet workspace. Rename one of them, then import again."
                    ]
                )
            }

            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            importStatus = "Imported \(sourceURL.lastPathComponent)."
            reloadWorkspace()
        } catch {
            lastError = error.localizedDescription
            importStatus = "Couldn't import the project."
        }
    }

    func createProject() {
        guard !projectsRootPath.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "New project"
        alert.informativeText =
            "The project gets its own folder in the RoachNet workspace, with starter files in the language you pick."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        input.placeholderString = "project-name"

        let languagePicker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 28), pullsDown: false)
        starterProjectLanguages.forEach(languagePicker.addItem(withTitle:))
        languagePicker.selectItem(withTitle: "Swift")

        let accessoryStack = NSStackView(views: [input, languagePicker])
        accessoryStack.orientation = .vertical
        accessoryStack.alignment = .leading
        accessoryStack.spacing = 10
        alert.accessoryView = accessoryStack

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let projectName = normalizedProjectName(input.stringValue)
        let selectedLanguage = languagePicker.titleOfSelectedItem ?? "Swift"
        guard !projectName.isEmpty else {
            lastError = "Enter a project name first."
            importStatus = "Couldn't create the project."
            return
        }

        do {
            let projectURL = URL(fileURLWithPath: projectsRootPath).appendingPathComponent(
                projectName, isDirectory: true)
            let sourceURL = projectURL.appendingPathComponent("src", isDirectory: true)
            let notesURL = projectURL.appendingPathComponent("notes", isDirectory: true)
            let fileManager = FileManager.default

            guard !fileManager.fileExists(atPath: projectURL.path) else {
                throw NSError(
                    domain: "RoachNetDevWorkspace",
                    code: 12,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "A project named \(projectName) is already in the RoachNet workspace. Pick another name."
                    ]
                )
            }

            try fileManager.createDirectory(at: sourceURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: notesURL, withIntermediateDirectories: true)

            let starter = projectStarter(projectName: projectName, language: selectedLanguage)

            try """
            # \(projectName)

            Created inside RoachNet Dev Studio.

            Starter lane:
            - \(selectedLanguage)

            - Keep source in `src/`
            - Keep specs, notes, and prompts in `notes/`
            - Use the built-in shell and RoachClaw assist without leaving the vault
            """.write(
                to: projectURL.appendingPathComponent("README.md"),
                atomically: true,
                encoding: .utf8
            )

            try starter.contents.write(
                to: sourceURL.appendingPathComponent(starter.fileName),
                atomically: true,
                encoding: .utf8
            )

            try """
            Goal:
            - Define the first feature, command flow, and tests here.
            - Record the runtime, secrets, and release assumptions before the first deploy.
            """.write(
                to: notesURL.appendingPathComponent("plan.md"),
                atomically: true,
                encoding: .utf8
            )

            reloadWorkspace()
            try open(url: projectURL.appendingPathComponent("README.md"))
            importStatus = "Created \(projectName) in the RoachNet workspace."
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            importStatus = "Couldn't create the project."
        }
    }

    func createScratchFile() {
        guard !projectsRootPath.isEmpty else { return }

        do {
            let workspaceURL = URL(fileURLWithPath: projectsRootPath)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let scratchDirectory = workspaceURL.appendingPathComponent("scratch", isDirectory: true)
            try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)

            let fileURL = scratchDirectory.appendingPathComponent("scratch-\(formatter.string(from: Date())).md")
            let template = """
                # RoachNet Scratchpad

                Start a command, keep notes, or draft code here.
                """
            try template.write(to: fileURL, atomically: true, encoding: .utf8)
            reloadWorkspace()
            try open(url: fileURL)
            importStatus = "Created a new scratch file."
        } catch {
            lastError = error.localizedDescription
            importStatus = "Couldn't create a scratch file."
        }
    }

    func createFile() {
        guard !projectsRootPath.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "New file"
        alert.informativeText = "Create a file inside the current RoachNet project."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        input.placeholderString = preferredNewFileRelativePath()
        alert.accessoryView = input

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let requestedPath = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let relativePath = requestedPath.isEmpty ? preferredNewFileRelativePath() : requestedPath
        let normalizedRelativePath = sanitizeRelativePath(relativePath)

        guard !normalizedRelativePath.isEmpty else {
            lastError = "Enter a file path before creating the file."
            importStatus = "Couldn't create the file."
            return
        }

        do {
            let projectsRootURL = URL(fileURLWithPath: projectsRootPath)
            let fileURL = projectsRootURL.appendingPathComponent(normalizedRelativePath)
            let parentURL = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)

            guard !FileManager.default.fileExists(atPath: fileURL.path) else {
                throw NSError(
                    domain: "RoachNetDevWorkspace",
                    code: 21,
                    userInfo: [
                        NSLocalizedDescriptionKey: "\(normalizedRelativePath) already exists. Pick another name."
                    ]
                )
            }

            try starterTemplate(for: fileURL, relativePath: normalizedRelativePath)
                .write(to: fileURL, atomically: true, encoding: .utf8)

            reloadWorkspace()
            try open(url: fileURL)
            importStatus = "Created \(normalizedRelativePath)."
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            importStatus = "Couldn't create the file."
        }
    }

    func createFolder() {
        guard !projectsRootPath.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "New folder"
        alert.informativeText = "Create a folder inside the current RoachNet project."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        input.placeholderString = preferredNewFolderRelativePath()
        alert.accessoryView = input

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let requestedPath = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let relativePath = requestedPath.isEmpty ? preferredNewFolderRelativePath() : requestedPath
        let normalizedRelativePath = sanitizeRelativePath(relativePath)

        guard !normalizedRelativePath.isEmpty else {
            lastError = "Enter a folder path before creating the folder."
            importStatus = "Couldn't create the folder."
            return
        }

        do {
            let folderURL = URL(fileURLWithPath: projectsRootPath).appendingPathComponent(
                normalizedRelativePath, isDirectory: true)
            guard !FileManager.default.fileExists(atPath: folderURL.path) else {
                throw NSError(
                    domain: "RoachNetDevWorkspace",
                    code: 22,
                    userInfo: [
                        NSLocalizedDescriptionKey: "\(normalizedRelativePath) already exists. Pick another name."
                    ]
                )
            }

            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            reloadWorkspace()
            importStatus = "Created \(normalizedRelativePath)."
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            importStatus = "Couldn't create the folder."
        }
    }

    func open(node: DeveloperFileNode) throws {
        guard !node.isDirectory else { return }
        try open(url: node.url)
    }

    func open(url: URL) throws {
        let relativePath = relativePath(for: url)
        let fileContents = try String(contentsOf: url, encoding: .utf8)
        let documentID = url.path

        if let index = openDocuments.firstIndex(where: { $0.id == documentID }) {
            openDocuments[index].text = fileContents
            activeDocumentID = documentID
            return
        }

        openDocuments.append(
            DeveloperDocument(
                id: documentID,
                url: url,
                relativePath: relativePath,
                text: fileContents,
                isDirty: false
            )
        )
        activeDocumentID = documentID
    }

    func saveActiveDocument() {
        guard let activeDocumentID, let index = openDocuments.firstIndex(where: { $0.id == activeDocumentID }) else {
            return
        }

        do {
            try openDocuments[index].text.write(to: openDocuments[index].url, atomically: true, encoding: .utf8)
            openDocuments[index].isDirty = false
            importStatus = "Saved \(openDocuments[index].relativePath)."
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            importStatus = "Couldn't save the file. Your changes are still in the editor."
        }
    }

    func updateActiveDocumentText(_ value: String) {
        guard let activeDocumentID, let index = openDocuments.firstIndex(where: { $0.id == activeDocumentID }) else {
            return
        }

        openDocuments[index].text = value
        openDocuments[index].isDirty = true
        inlineCompletion = ""
        inlineCompletionStatus =
            inlinePromptDirective == nil
            ? "Buffer changed. Refresh inline assist when you want the next lines."
            : "Inline prompt ready at the end of the file. Refresh when you want RoachClaw to answer it."
    }

    func closeDocument(id: String) {
        openDocuments.removeAll { $0.id == id }
        if activeDocumentID == id {
            activeDocumentID = openDocuments.first?.id
        }
    }

    func runTerminalCommand() {
        let command = terminalCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }

        do {
            try ensureTerminalSession(forceRestart: false)
            recordTerminalCommand(command)
            lastTerminalExitCode = nil
            lastError = nil

            if terminalDidReachPrompt {
                terminalAwaitingPrompt = true
                terminalStatus = "Running in \(displayWorkingDirectory())."
                try terminalSession?.send(command + "\n")
            } else {
                queuedTerminalCommand = command
                terminalAwaitingPrompt = true
                terminalStatus = "Waiting for the first prompt in \(displayWorkingDirectory())."
            }

            terminalCommand = ""
        } catch {
            terminalStatus = "Couldn't start the shell."
            lastTerminalExitCode = -1
            lastError = error.localizedDescription
        }
    }

    func stopTerminalCommand() {
        if queuedTerminalCommand != nil, !terminalDidReachPrompt {
            queuedTerminalCommand = nil
            terminalAwaitingPrompt = false
            terminalStatus = "Queued command cleared."
            return
        }

        guard terminalSession != nil else { return }
        terminalSession?.interrupt()
        terminalAwaitingPrompt = true
        terminalStatus = "Interrupt sent."
    }

    func relaunchTerminalSession() {
        do {
            try ensureTerminalSession(forceRestart: true)
            importStatus = "Started a new terminal session."
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            importStatus = "Couldn't start a new terminal session."
        }
    }

    func shutdownTerminalSession() {
        terminalSession?.terminate()
        terminalSession = nil
        terminalIsRunning = false
        terminalAwaitingPrompt = false
        terminalReportedWorkingDirectory = ""
        terminalDidReachPrompt = false
        queuedTerminalCommand = nil
    }

    func clearTerminalOutput() {
        terminalOutput = ""
        if !terminalIsRunning {
            terminalStatus = "Terminal output cleared."
        }
    }

    func copyTerminalOutput() {
        copyToPasteboard(terminalOutput)
        importStatus = "Copied terminal output."
    }

    func cycleTerminalTheme() {
        let themes = DeveloperTerminalTheme.allCases
        guard let index = themes.firstIndex(of: terminalTheme) else {
            terminalTheme = .roach
            return
        }
        terminalTheme = themes[(index + 1) % themes.count]
        terminalStatus = "Terminal theme: \(terminalTheme.rawValue)."
    }

    func increaseTerminalFontSize() {
        terminalFontSize = min(terminalFontSize + 1, 18)
    }

    func decreaseTerminalFontSize() {
        terminalFontSize = max(terminalFontSize - 1, 10)
    }

    private func recordTerminalCommand(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        terminalRecentCommands.removeAll { $0 == trimmed }
        terminalRecentCommands.insert(trimmed, at: 0)
        terminalRecentCommands = Array(terminalRecentCommands.prefix(8))
    }

    func loadSecrets(storagePath: String) {
        secretRecords = RoachNetSecretsCatalogStore.load(storagePath: storagePath)
        if selectedSecret == nil {
            selectedSecretID = secretRecords.first?.id
        }
        if let selectedSecret {
            loadSecretDraft(from: selectedSecret)
        }
    }

    func loadRoachBrain(storagePath: String) {
        roachBrainMemories = RoachBrainStore.load(storagePath: storagePath)
        if !roachBrainMemories.isEmpty, RoachBrainWikiStore.status(storagePath: storagePath).pageCount == 0 {
            _ = try? RoachBrainWikiStore.rebuildFromMemories(storagePath: storagePath, memories: roachBrainMemories)
        }
        let wikiPages = RoachBrainWikiStore.status(storagePath: storagePath).pageCount
        roachBrainStatus =
            roachBrainMemories.isEmpty
            ? "No memory stored yet."
            : "\(RoachCopy.count(roachBrainMemories.count, "memory", "memories")), \(RoachCopy.count(wikiPages, "wiki page"))."
    }

    func selectSecret(_ record: RoachNetSecretRecord?) {
        selectedSecretID = record?.id
        if let record {
            loadSecretDraft(from: record)
        } else {
            clearSecretDrafts()
        }
    }

    func stageTemplate(_ template: RoachNetSecretTemplate) {
        selectedSecretID = nil
        secretLabelDraft = template.label
        secretKeyDraft = template.key
        secretScopeDraft = template.scope
        secretNotesDraft = template.notes
        secretValueDraft = ""
        revealedSecretValue = ""
    }

    func revealSelectedSecret() {
        guard let selectedSecret else { return }

        do {
            revealedSecretValue =
                try RoachNetKeychainSecretStore.secretValue(id: selectedSecret.id, installPath: installPath) ?? ""
            secretValueDraft = revealedSecretValue
            importStatus = "Loaded \(selectedSecret.label) from Keychain."
        } catch {
            lastError = error.localizedDescription
            importStatus = "Couldn't load that secret from Keychain."
        }
    }

    func saveSecret(storagePath: String) {
        let label = secretLabelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = secretKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let scope = secretScopeDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = secretNotesDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = secretValueDraft

        guard !label.isEmpty, !key.isEmpty else {
            lastError = "Secrets need both a label and an environment key."
            importStatus = "Couldn't save the secret."
            return
        }

        let timestamp = dateFormatter.string(from: Date())
        let identifier = selectedSecretID ?? slug(for: key)

        var records = RoachNetSecretsCatalogStore.load(storagePath: storagePath)
        if let index = records.firstIndex(where: { $0.id == identifier }) {
            let createdAt = records[index].createdAt
            records[index] = RoachNetSecretRecord(
                id: identifier,
                label: label,
                key: key,
                scope: scope.isEmpty ? "Workspace" : scope,
                notes: notes,
                createdAt: createdAt,
                updatedAt: timestamp
            )
        } else {
            records.append(
                RoachNetSecretRecord(
                    id: identifier,
                    label: label,
                    key: key,
                    scope: scope.isEmpty ? "Workspace" : scope,
                    notes: notes,
                    createdAt: timestamp,
                    updatedAt: timestamp
                )
            )
        }

        do {
            try RoachNetKeychainSecretStore.setSecretValue(value, id: identifier, installPath: installPath)
            try RoachNetSecretsCatalogStore.save(records, storagePath: storagePath)
            secretRecords = RoachNetSecretsCatalogStore.load(storagePath: storagePath)
            selectedSecretID = identifier
            revealedSecretValue = value
            importStatus = "Saved \(label) to Keychain."
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            importStatus = "Couldn't save the secret."
        }
    }

    func deleteSelectedSecret(storagePath: String) {
        guard let selectedSecret else { return }
        do {
            try RoachNetKeychainSecretStore.deleteSecret(id: selectedSecret.id, installPath: installPath)
            let filtered = RoachNetSecretsCatalogStore.load(storagePath: storagePath).filter {
                $0.id != selectedSecret.id
            }
            try RoachNetSecretsCatalogStore.save(filtered, storagePath: storagePath)
            secretRecords = filtered
            selectedSecretID = filtered.first?.id
            if let replacement = filtered.first {
                loadSecretDraft(from: replacement)
            } else {
                clearSecretDrafts()
            }
            importStatus = "Deleted \(selectedSecret.label)."
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            importStatus = "Couldn't delete the secret."
        }
    }

    func requestAssistant(using workspaceModel: WorkspaceModel) async {
        guard !aiIsRunning else { return }
        let prompt = aiPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        let activeMode = assistantMode

        let memoryMatches = roachBrainSuggestedMatches
        let memoryContextBlock = RoachBrainStore.contextBlock(for: memoryMatches)
        let wikiContextBlock = RoachBrainWikiStore.contextBlock(
            storagePath: storagePath, query: prompt, matches: memoryMatches)
        let operatorProtocolBlock = RoachBrainWikiStore.operatorProtocolBlock()
        let researchProtocolBlock = RoachBrainWikiStore.researchProtocolBlock()
        let appContextBlock = workspaceModel.permissionedRoachClawContextBlock()

        let fileContext =
            activeDocument.map { document in
                """
                Current file: \(document.relativePath)

                ```text
                \(document.text.prefix(assistantFileContextLimit))
                ```
                """
            } ?? "No file is open right now."

        let composedPrompt = """
            You are assisting inside RoachNet Dev Studio.

            Current assist mode: \(assistantMode.rawValue)
            Mode contract:
            \(assistantMode.instruction)

            \(memoryContextBlock.isEmpty ? "" : """
            \(memoryContextBlock)

            Use the RoachBrain notes only if they help this request stay concrete.
            """)

            \(wikiContextBlock.isEmpty ? "" : """
            \(wikiContextBlock)

            Read the compiled wiki as durable local context, not as unquestioned truth.
            """)

            \(operatorProtocolBlock)

            \(researchProtocolBlock)

            \(appContextBlock.isEmpty ? "" : """
            \(appContextBlock)

            Use the explicit RoachNet context only when it materially improves the answer.
            """)

            \(fileContext)

            Request:
            \(prompt)

            Keep the answer concrete, implementation-ready, and shaped to the current assist mode.
            """

        aiIsRunning = true
        aiResponse = ""
        importStatus = "Asking RoachClaw."
        lastError = nil

        do {
            aiResponse = try await workspaceModel.requestDeveloperAssist(prompt: composedPrompt)
            try? RoachBrainStore.markAccessed(memoryIDs: memoryMatches.map(\.id), storagePath: storagePath)
            rememberAssistantExchange(prompt: prompt, response: aiResponse)
            recordAssistantTurn(prompt: prompt, response: aiResponse, mode: activeMode)
            importStatus =
                memoryMatches.isEmpty
                ? "RoachClaw replied."
                : "RoachClaw replied, using RoachBrain memories as context."
        } catch {
            let presentation = developerAssistFailurePresentation(
                for: error, automatic: false, workspaceModel: workspaceModel)
            aiResponse = presentation.surfacedError == nil ? presentation.status : ""
            lastError = presentation.surfacedError
            importStatus = presentation.status
            recordAssistantTurn(prompt: prompt, response: presentation.status, mode: activeMode)
        }

        aiIsRunning = false
    }

    func copyAssistantResponse() {
        copyToPasteboard(aiResponse)
        importStatus = "Copied RoachClaw response."
    }

    func saveAssistantResponseToRoachBrain() {
        let response = aiResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !response.isEmpty, !storagePath.isEmpty else { return }

        do {
            _ = try RoachBrainStore.capture(
                storagePath: storagePath,
                title: roachBrainMemoryTitle(from: aiPrompt),
                body: """
                    Request:
                    \(aiPrompt.trimmingCharacters(in: .whitespacesAndNewlines))

                    Response:
                    \(response)
                    """,
                source: "Dev Studio Assist",
                tags: roachBrainContextTags + ["saved", "dev-assist"],
                pinned: true
            )
            loadRoachBrain(storagePath: storagePath)
            importStatus = "Saved this reply to RoachBrain."
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            importStatus = "Couldn't save to RoachBrain."
        }
    }

    func requestInlineCompletion(using workspaceModel: WorkspaceModel, automatic: Bool = false) async {
        guard !inlineCompletionIsLoading else { return }
        guard let activeDocument else {
            inlineCompletion = ""
            inlineCompletionStatus = "Open a file. RoachClaw reads the end of it and suggests the next lines."
            return
        }
        if automatic && activeDocument.text.count > automaticInlineMaxDocumentCharacters {
            inlineCompletion = ""
            inlineCompletionStatus = "This file is large, so inline assist waits until you press Refresh."
            return
        }

        let tailWindow = String(activeDocument.text.suffix(inlineTailContextLimit))
        let openingWindow = String(activeDocument.text.prefix(inlineOpeningContextLimit))
        let memoryMatches = roachBrainSuggestedMatches.prefix(2).map { $0 }
        let memoryContextBlock = RoachBrainStore.contextBlock(for: memoryMatches)
        let wikiContextBlock = RoachBrainWikiStore.contextBlock(
            storagePath: storagePath, query: tailWindow, matches: memoryMatches)
        let inlinePromptDirective = self.inlinePromptDirective

        let prompt = """
            You are generating an inline completion inside RoachNet Dev Studio.

            Return only the code or text that should be inserted directly into the open editor.
            Do not explain anything.
            Do not use markdown fences.
            Keep the completion compact and faithful to the file's existing style.
            \(inlinePromptDirective == nil
            ? "If the file looks complete, return one short next-step comment using the file's own comment style."
            : "An explicit inline prompt directive was written at the end of the file. Answer that directive and assume the directive line itself will be replaced by your returned code or text.")

            File: \(activeDocument.relativePath)
            Language: \(activeDocumentLanguage)
            Project: \(currentProjectName)

            \(inlinePromptDirective.map { """
            Inline prompt directive:
            \($0.instruction)
            """ } ?? "")

            \(memoryContextBlock.isEmpty ? "" : """
            Local memory:
            \(memoryContextBlock)
            """)

            \(wikiContextBlock.isEmpty ? "" : """
            Compiled RoachBrain wiki:
            \(wikiContextBlock)
            """)

            Buffer opening:
            ```text
            \(openingWindow)
            ```

            Buffer tail:
            ```text
            \(tailWindow)
            ```
            """

        inlineCompletionIsLoading = true
        inlineCompletionStatus =
            automatic
            ? (inlinePromptDirective == nil
                ? "RoachClaw is reading the end of the file."
                : "RoachClaw is reading the inline prompt at the end of the file.")
            : (inlinePromptDirective == nil
                ? "Refreshing the inline completion."
                : "Refreshing the inline prompt answer.")
        lastError = nil

        do {
            let response = try await workspaceModel.requestDeveloperAssist(prompt: prompt)
            let cleaned = DeveloperInlineAssistSupport.cleanedCompletion(from: response)
            inlineCompletion = cleaned
            inlineCompletionStatus =
                cleaned.isEmpty
                ? "RoachClaw had no suggestion this time."
                : (inlinePromptDirective == nil
                    ? "RoachClaw's next lines are ready at the end of the file."
                    : "RoachClaw's answer to the inline prompt is ready in the editor.")
        } catch {
            let presentation = developerAssistFailurePresentation(
                for: error, automatic: automatic, workspaceModel: workspaceModel)
            inlineCompletion = ""
            inlineCompletionStatus = presentation.status
            lastError = presentation.surfacedError
        }

        inlineCompletionIsLoading = false
    }

    func acceptInlineCompletion() {
        let completion = inlineCompletion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !completion.isEmpty else { return }
        guard let activeDocumentID, let index = openDocuments.firstIndex(where: { $0.id == activeDocumentID }) else {
            lastError = "Open a file before accepting the inline completion."
            importStatus = "Nothing inserted."
            return
        }

        let existing = openDocuments[index].text
        let updated = DeveloperInlineAssistSupport.integratingAcceptedCompletion(
            completion,
            into: existing,
            fileExtension: openDocuments[index].url.pathExtension
        )
        openDocuments[index].text = updated.hasSuffix("\n") ? updated : updated + "\n"
        openDocuments[index].isDirty = true
        inlineCompletion = ""
        inlineCompletionStatus =
            inlinePromptDirective == nil
            ? "Completion accepted. Ask RoachClaw for the next lines when you need them."
            : "Replaced the inline prompt with RoachClaw's answer."
        importStatus = "Accepted the inline completion in \(openDocuments[index].relativePath)."
        lastError = nil
    }

    func insertAssistantResponseIntoActiveDocument() {
        guard !aiResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let activeDocumentID, let index = openDocuments.firstIndex(where: { $0.id == activeDocumentID }) else {
            lastError = "Open a file before inserting the RoachClaw response."
            importStatus = "Nothing inserted."
            return
        }

        let extensionName = openDocuments[index].url.pathExtension.lowercased()
        let responseBlock = formattedAssistantInsertion(aiResponse, fileExtension: extensionName)
        let existing = openDocuments[index].text
        let separator = existing.hasSuffix("\n") ? "\n" : "\n\n"
        openDocuments[index].text += separator + responseBlock + "\n"
        openDocuments[index].isDirty = true
        importStatus = "Inserted the RoachClaw response into \(openDocuments[index].relativePath)."
        lastError = nil
    }

    private func loadSecretDraft(from record: RoachNetSecretRecord) {
        secretLabelDraft = record.label
        secretKeyDraft = record.key
        secretScopeDraft = record.scope
        secretNotesDraft = record.notes
        secretValueDraft = ""
        revealedSecretValue = ""
    }

    private func clearSecretDrafts() {
        secretLabelDraft = ""
        secretKeyDraft = ""
        secretScopeDraft = ""
        secretNotesDraft = ""
        secretValueDraft = ""
        revealedSecretValue = ""
    }

    func currentWorkingDirectory() -> String {
        let override = terminalWorkingDirectoryOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty {
            return override
        }
        return activeDocument?.url.deletingLastPathComponent().path
            ?? (projectsRootPath.isEmpty ? NSHomeDirectory() : projectsRootPath)
    }

    func displayWorkingDirectory() -> String {
        let resolvedPath =
            terminalReportedWorkingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? currentWorkingDirectory()
            : terminalReportedWorkingDirectory
        let directoryURL = URL(fileURLWithPath: resolvedPath)
        let projectsRootURL = URL(fileURLWithPath: projectsRootPath)

        if directoryURL.path == projectsRootURL.path {
            return currentProjectName == "Workspace" ? "workspace" : currentProjectName
        }

        if directoryURL.path.hasPrefix(projectsRootURL.path) {
            let relative = directoryURL.path.replacingOccurrences(of: projectsRootURL.path, with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !relative.isEmpty {
                return relative
            }
        }

        let fallback = directoryURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? "workspace" : fallback
    }

    func setTerminalWorkingDirectory(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        terminalWorkingDirectoryOverride = trimmed
        jumpTerminalSessionIfNeeded(to: trimmed)
        if !terminalIsRunning {
            terminalStatus = "Shell pinned to \(displayWorkingDirectory())."
        }
    }

    func followTerminalActiveContext() {
        terminalWorkingDirectoryOverride = ""
        syncLiveTerminalWorkingDirectory(force: true)
        if !terminalIsRunning {
            terminalStatus = "Shell follows the open file when you relaunch it."
        }
    }

    private func filterNodes(_ nodes: [DeveloperFileNode], query: String) -> [DeveloperFileNode] {
        nodes.compactMap { node in
            let matchesNode = node.name.lowercased().contains(query) || node.relativePath.lowercased().contains(query)
            if node.isDirectory {
                let filteredChildren = filterNodes(node.children ?? [], query: query)
                guard matchesNode || !filteredChildren.isEmpty else { return nil }
                return DeveloperFileNode(
                    id: node.id,
                    url: node.url,
                    relativePath: node.relativePath,
                    isDirectory: true,
                    children: filteredChildren
                )
            }

            return matchesNode ? node : nil
        }
    }

    private func ensureTerminalSessionIfNeeded() {
        do {
            try ensureTerminalSession(forceRestart: false)
        } catch {
            lastError = error.localizedDescription
            terminalStatus = "Couldn't start the shell."
        }
    }

    private func ensureTerminalSession(forceRestart: Bool) throws {
        if forceRestart {
            terminalSession?.terminate()
            terminalSession = nil
            terminalOutput = ""
            terminalReportedWorkingDirectory = ""
            terminalDidReachPrompt = false
            queuedTerminalCommand = nil
        }

        guard terminalSession == nil else { return }

        let session = DeveloperTerminalSession(
            launchDirectory: currentWorkingDirectory(),
            environment: [
                "PATH": RoachNetRepositoryLocator.preferredBinarySearchPath(),
                "HOME": NSHomeDirectory(),
                "TERM": "xterm-256color",
                "COLORTERM": "truecolor",
            ]
        )

        session.onOutput = { [weak self] chunk in
            Task { @MainActor in
                self?.consumeTerminalChunk(chunk)
            }
        }
        session.onExit = { [weak self] exitCode in
            Task { @MainActor in
                self?.terminalSession = nil
                self?.terminalIsRunning = false
                self?.terminalAwaitingPrompt = false
                self?.lastTerminalExitCode = exitCode
                self?.queuedTerminalCommand = nil
                self?.terminalStatus = "Shell ended with code \(exitCode)."
            }
        }

        try session.start()
        terminalSession = session
        terminalIsRunning = true
        terminalAwaitingPrompt = true
        terminalStatus = "Opening shell in \(displayWorkingDirectory())."
        lastTerminalExitCode = nil
    }

    private func consumeTerminalChunk(_ chunk: String) {
        let parsed = DeveloperTerminalTranscript.consume(chunk)

        if let prompt = parsed.prompt {
            terminalReportedWorkingDirectory = prompt.workingDirectory
            terminalAwaitingPrompt = false
            lastTerminalExitCode = prompt.exitCode
            terminalStatus =
                prompt.exitCode == 0
                ? "Shell ready in \(displayWorkingDirectory())."
                : "Last command exited with \(prompt.exitCode)."

            let sanitizedVisibleText = DeveloperTerminalTranscript.stripBootstrapNoise(from: parsed.visibleText)

            if terminalDidReachPrompt {
                if !sanitizedVisibleText.isEmpty {
                    appendTerminalOutput(sanitizedVisibleText)
                }
            } else {
                terminalDidReachPrompt = true
                terminalOutput = terminalRecentCommands.isEmpty ? "" : sanitizedVisibleText
            }

            if let queuedCommand = queuedTerminalCommand {
                queuedTerminalCommand = nil
                do {
                    terminalAwaitingPrompt = true
                    terminalStatus = "Running in \(displayWorkingDirectory())."
                    try terminalSession?.send(queuedCommand + "\n")
                } catch {
                    lastError = error.localizedDescription
                    terminalAwaitingPrompt = false
                    terminalStatus = "Couldn't start the shell."
                }
            }
            return
        }

        if !parsed.visibleText.isEmpty {
            guard !(terminalRecentCommands.isEmpty && !terminalDidReachPrompt) else {
                return
            }
            let visibleText = DeveloperTerminalTranscript.stripBootstrapNoise(from: parsed.visibleText)
            if !visibleText.isEmpty {
                appendTerminalOutput(visibleText)
            }
        }
    }

    private func prepareInlineCompletion() {
        inlineCompletion = ""
        inlineCompletionStatus =
            if activeDocument == nil {
                "Open a file. RoachClaw reads the end of it and suggests the next lines."
            } else if inlinePromptDirective == nil {
                "RoachClaw is watching the end of the file."
            } else {
                "Inline prompt ready at the end of the file."
            }
    }

    private func syncLiveTerminalWorkingDirectory(force: Bool = false) {
        guard terminalSession != nil else { return }
        guard !terminalAwaitingPrompt || force else { return }
        let resolvedDirectory = currentWorkingDirectory()
        guard force || resolvedDirectory != terminalReportedWorkingDirectory else { return }
        jumpTerminalSessionIfNeeded(to: resolvedDirectory)
    }

    private func jumpTerminalSessionIfNeeded(to path: String) {
        guard terminalSession != nil else { return }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let move = DeveloperShell.changeDirectory(to: trimmed) else {
            terminalStatus =
                "This folder's name has a character the shell would take as a key, so the shell stays where it is."
            return
        }
        do {
            try terminalSession?.send(move)
            terminalAwaitingPrompt = true
            terminalStatus = "Moving shell to \(displayWorkingDirectory())."
        } catch {
            lastError = error.localizedDescription
            terminalStatus = "Couldn't move the shell to that folder."
        }
    }

    private func appendTerminalOutput(_ chunk: String) {
        let combined = terminalOutput + chunk
        terminalOutput = String(combined.suffix(40_000))
    }

    private func developerAssistFailurePresentation(
        for error: Error,
        automatic: Bool,
        workspaceModel: WorkspaceModel
    ) -> DeveloperAssistFailurePresentation {
        let hasCloudFallback =
            workspaceModel.snapshot?.internetConnected == true
            && workspaceModel.chatModelOptions.contains(where: OllamaCloudModel.matches)

        return DeveloperInlineAssistSupport.failurePresentation(
            description: error.localizedDescription,
            roachClawReady: workspaceModel.snapshot?.roachClaw.ready == true,
            hasCloudFallback: hasCloudFallback,
            automatic: automatic,
            modelDownloading: workspaceModel.selectedModelState == .downloading
        )
    }

    private var roachBrainContextTags: [String] {
        [
            "dev",
            "assist",
            activeDocumentLanguage.lowercased(),
            currentProjectName.lowercased(),
        ]
    }

    private func rememberAssistantExchange(prompt: String, response: String) {
        guard !storagePath.isEmpty else { return }

        do {
            _ = try RoachBrainStore.capture(
                storagePath: storagePath,
                title: roachBrainMemoryTitle(from: prompt),
                body: """
                    Request:
                    \(prompt)

                    Response:
                    \(response)
                    """,
                source: "Dev Studio Assist",
                tags: roachBrainContextTags + ["dev-assist"]
            )
            loadRoachBrain(storagePath: storagePath)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func recordAssistantTurn(prompt: String, response: String, mode: DeveloperAssistMode) {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }

        let collapsedResponse =
            response
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let preview = collapsedResponse.isEmpty ? "No reply captured yet." : String(collapsedResponse.prefix(180))

        assistantTurns.removeAll { $0.prompt == trimmedPrompt && $0.mode == mode }
        assistantTurns.insert(
            DeveloperAssistTurn(
                id: UUID().uuidString,
                prompt: trimmedPrompt,
                mode: mode,
                responsePreview: preview,
                createdAt: Date()
            ),
            at: 0
        )
        assistantTurns = Array(assistantTurns.prefix(8))
    }

    private func roachBrainMemoryTitle(from prompt: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Dev Studio exchange" }
        let compact = trimmed.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return compact.count > 56 ? String(compact.prefix(53)) + "..." : compact
    }

    private func formattedAssistantInsertion(_ response: String, fileExtension: String) -> String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.components(separatedBy: .newlines)

        let prefix: String
        switch fileExtension {
        case "swift", "ts", "tsx", "js", "jsx", "go", "rs", "cs":
            prefix = "// "
        case "py", "sh", "zsh", "rb":
            prefix = "# "
        case "html":
            return """
                <!-- RoachClaw assist
                \(trimmed)
                -->
                """
        case "css":
            return """
                /* RoachClaw assist
                \(trimmed)
                */
                """
        default:
            prefix = ""
        }

        if prefix.isEmpty {
            return trimmed
        }

        return ([prefix + "RoachClaw assist"] + lines.map { prefix + $0 }).joined(separator: "\n")
    }

    private func seedWorkspaceIfNeeded() throws {
        let workspaceURL = URL(fileURLWithPath: projectsRootPath)
        let fileManager = FileManager.default
        let existing = (try? fileManager.contentsOfDirectory(atPath: workspaceURL.path)) ?? []
        guard existing.isEmpty else { return }

        let sampleProject = workspaceURL.appendingPathComponent("welcome", isDirectory: true)
        try fileManager.createDirectory(at: sampleProject, withIntermediateDirectories: true)

        let readme = sampleProject.appendingPathComponent("README.md")
        let swiftFile = sampleProject.appendingPathComponent("hello.swift")

        try """
        # RoachNet Dev Studio

        Projects copied into this folder stay inside the RoachNet workspace.

        - Import a project to keep it portable with the app storage root.
        - Use the shell lane to run commands in the selected file's directory.
        - Store API keys in the Secrets lane so values stay in macOS Keychain.
        """.write(to: readme, atomically: true, encoding: .utf8)

        try """
        import Foundation

        struct HelloRoachNet {
            static func main() {
                print("RoachNet Dev is awake.")
            }
        }
        """.write(to: swiftFile, atomically: true, encoding: .utf8)
    }

    private func buildFileNodes(at directoryURL: URL, root: URL) throws -> [DeveloperFileNode] {
        let fileManager = FileManager.default
        let items = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .sorted {
            let lhsDirectory = (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let rhsDirectory = (try? $1.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if lhsDirectory != rhsDirectory {
                return lhsDirectory && !rhsDirectory
            }
            return $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
        }

        return try items.map { url in
            let isDirectory = (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory ?? false
            let children = isDirectory ? try buildFileNodes(at: url, root: root) : nil
            let relativePath = url.path.replacingOccurrences(of: root.path + "/", with: "")
            return DeveloperFileNode(
                id: url.path,
                url: url,
                relativePath: relativePath,
                isDirectory: isDirectory,
                children: children
            )
        }
    }

    private func firstFileNode(in nodes: [DeveloperFileNode]) -> DeveloperFileNode? {
        for node in nodes {
            if node.isDirectory {
                if let child = firstFileNode(in: node.children ?? []) {
                    return child
                }
            } else {
                return node
            }
        }
        return nil
    }

    private func relativePath(for url: URL) -> String {
        let root = URL(fileURLWithPath: projectsRootPath)
        return url.path.replacingOccurrences(of: root.path + "/", with: "")
    }

    private func preferredNewFileRelativePath() -> String {
        let currentDirectory = currentRelativeDirectory()
        if !currentDirectory.isEmpty {
            return "\(currentDirectory)/notes.md"
        }

        if currentProjectName != "Workspace" {
            return "\(currentProjectName)/notes/next-step.md"
        }

        return "welcome/notes.md"
    }

    private func preferredNewFolderRelativePath() -> String {
        let currentDirectory = currentRelativeDirectory()
        if !currentDirectory.isEmpty {
            return "\(currentDirectory)/new-folder"
        }

        if currentProjectName != "Workspace" {
            return "\(currentProjectName)/notes"
        }

        return "welcome/notes"
    }

    private func currentRelativeDirectory() -> String {
        guard let activeDocument else { return "" }
        let directory = activeDocument.url.deletingLastPathComponent()
        let root = URL(fileURLWithPath: projectsRootPath)
        let relativePath = directory.path.replacingOccurrences(of: root.path + "/", with: "")
        return relativePath == directory.path ? "" : relativePath
    }

    private func sanitizeRelativePath(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\\\", with: "/")
            .replacingOccurrences(of: "^/+|/+$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\.\\.+", with: ".", options: .regularExpression)
    }

    private func starterTemplate(for url: URL, relativePath: String) -> String {
        switch url.pathExtension.lowercased() {
        case "swift":
            return """
                import Foundation

                struct \(swiftIdentifier(from: url.deletingPathExtension().lastPathComponent)) {
                    func run() {
                        print("\(relativePath) is ready.")
                    }
                }
                """
        case "js":
            return """
                export function main() {
                  console.log('\(relativePath) is ready.')
                }
                """
        case "ts":
            return """
                export function main(): void {
                  console.log('\(relativePath) is ready.');
                }
                """
        case "tsx":
            return """
                import React from 'react'

                export function \(swiftIdentifier(from: url.deletingPathExtension().lastPathComponent))(): JSX.Element {
                  return <div>\(relativePath) is ready.</div>
                }
                """
        case "py":
            return """
                def main() -> None:
                    print("\(relativePath) is ready.")


                if __name__ == "__main__":
                    main()
                """
        case "go":
            return """
                package main

                import "fmt"

                func main() {
                    fmt.Println("\(relativePath) is ready.")
                }
                """
        case "rs":
            return """
                fn main() {
                    println!(\"\(relativePath) is ready.\");
                }
                """
        case "cs":
            return """
                using System;

                Console.WriteLine("\(relativePath) is ready.");
                """
        case "sh", "zsh":
            return """
                #!/usr/bin/env bash
                set -euo pipefail

                echo "\(relativePath) is ready."
                """
        case "html":
            return """
                <!doctype html>
                <html lang="en">
                  <head>
                    <meta charset="UTF-8" />
                    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
                    <title>\(url.deletingPathExtension().lastPathComponent)</title>
                  </head>
                  <body>
                    <main>\(relativePath) is ready.</main>
                  </body>
                </html>
                """
        case "css":
            return """
                :root {
                  color-scheme: dark;
                }

                body {
                  margin: 0;
                  font-family: system-ui, sans-serif;
                }
                """
        case "md":
            return """
                # \(url.deletingPathExtension().lastPathComponent)

                Notes for \(relativePath).
                """
        case "json":
            return """
                {
                  "name": "\(url.deletingPathExtension().lastPathComponent)",
                  "createdBy": "RoachNet Dev Studio"
                }
                """
        default:
            return ""
        }
    }

    private func projectStarter(projectName: String, language: String) -> (fileName: String, contents: String) {
        switch language {
        case "TypeScript":
            return (
                "main.ts",
                """
                export function main(): void {
                  console.log('RoachNet project \(projectName) is ready.');
                }
                """
            )
        case "JavaScript":
            return (
                "main.js",
                """
                export function main() {
                  console.log('RoachNet project \(projectName) is ready.')
                }
                """
            )
        case "Python":
            return (
                "main.py",
                """
                def main() -> None:
                    print("RoachNet project \(projectName) is ready.")


                if __name__ == "__main__":
                    main()
                """
            )
        case "Go":
            return (
                "main.go",
                """
                package main

                import "fmt"

                func main() {
                    fmt.Println("RoachNet project \(projectName) is ready.")
                }
                """
            )
        case "Rust":
            return (
                "main.rs",
                """
                fn main() {
                    println!("RoachNet project \(projectName) is ready.");
                }
                """
            )
        case "C#":
            return (
                "Program.cs",
                """
                using System;

                Console.WriteLine("RoachNet project \(projectName) is ready.");
                """
            )
        case "Shell":
            return (
                "main.sh",
                """
                #!/usr/bin/env bash
                set -euo pipefail

                echo "RoachNet project \(projectName) is ready."
                """
            )
        default:
            return (
                "main.swift",
                """
                import Foundation

                @main
                enum \(swiftIdentifier(from: projectName)) {
                    static func main() {
                        print("RoachNet project \(projectName) is ready.")
                    }
                }
                """
            )
        }
    }

    private func copyToPasteboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    private func slug(for value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private func normalizedProjectName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[^A-Za-z0-9._ -]+", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func swiftIdentifier(from value: String) -> String {
        let collapsed =
            value
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined()
        return collapsed.isEmpty ? "RoachNetProject" : collapsed
    }
}

struct DevWorkspaceView: View {
    @ObservedObject var model: WorkspaceModel
    @StateObject private var devModel = DevWorkspaceModel()
    @State private var selectedRailSection: DeveloperRailSection = .assist
    private let workbenchSpring = Animation.spring(response: 0.34, dampingFraction: 0.84)

    private var summaryColumns: [GridItem] {
        [
            GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 12, alignment: .top)
        ]
    }

    private var roachClawStatusText: String {
        guard model.snapshot?.roachClaw != nil else { return "Checking model" }
        return model.selectedModelState.devStatus
    }

    private var cloudLaneText: String {
        let providers = model.snapshot?.providers.providers ?? [:]
        let availableProviders =
            providers
            .filter { $0.value.available }
            .map(\.key)
            .sorted()

        guard !availableProviders.isEmpty else { return "No remote model" }
        return availableProviders.joined(separator: ", ")
    }

    private var inlineAssistStatusLine: String {
        if let directive = devModel.inlinePromptDirective {
            return devModel.inlineCompletion.isEmpty
                ? "Inline prompt ready: \(directive.instruction)"
                : "The answer to the inline prompt is ready in the editor."
        }
        return devModel.inlineCompletion.isEmpty
            ? devModel.inlineCompletionStatus : "The next lines are ready at the end of the file."
    }

    private var guidebookResources: [DeveloperGuidebookResource] {
        [
            DeveloperGuidebookResource(
                id: "raycast-developers",
                title: "Raycast Developers",
                detail: "React, TypeScript, command UX, publishing.",
                url: "https://developers.raycast.com/",
                tags: ["React", "TypeScript", "Command UX"]
            )
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            devWorkspaceHeader

            if let lastError = devModel.lastError {
                RoachNotice(title: "Last error", detail: lastError)
            }

            devWorkbenchBody
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: model.storagePath) {
            devModel.configure(storagePath: model.storagePath, installPath: model.installPath)
        }
        .task(id: devModel.activeDocumentID) {
            await devModel.requestInlineCompletion(using: model, automatic: true)
        }
        .animation(workbenchSpring, value: selectedRailSection)
        .animation(workbenchSpring, value: devModel.activeDocumentID)
        .onDisappear {
            devModel.shutdownTerminalSession()
        }
    }

    private var devWorkspaceHeader: some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 6) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 12) {
                        HStack(spacing: 10) {
                            Image(systemName: "terminal.fill")
                                .font(.roach(size: 14, weight: .bold))
                                .foregroundStyle(RoachPalette.cyan)
                                .frame(width: 28, height: 28)
                                .background(
                                    RoundedRectangle(cornerRadius: RoachMetrics.radius(10), style: .continuous)
                                        .fill(RoachPalette.cyan.opacity(0.12))
                                )

                            VStack(alignment: .leading, spacing: 3) {
                                Text("Dev")
                                    .font(.roach(size: 15, weight: .semibold))
                                    .foregroundStyle(RoachPalette.text)
                                    .lineLimit(1)
                                Text(devModel.displayWorkingDirectory())
                                    .font(.roach(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(RoachPalette.muted)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }

                        Spacer(minLength: 12)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                RoachTag(devModel.currentProjectName, accent: RoachPalette.cyan)
                                RoachTag(
                                    "\(RoachCopy.count(devModel.openDocuments.count, "tab"))",
                                    accent: RoachPalette.green)
                                RoachTag(
                                    "\(RoachCopy.count(devModel.terminalOutputLineCount, "terminal line"))",
                                    accent: RoachPalette.magenta)
                                RoachTag(
                                    "\(RoachCopy.count(devModel.secretRecords.count, "secret"))",
                                    accent: RoachPalette.bronze)
                            }
                        }
                        .frame(maxWidth: 420)

                        HStack(spacing: 6) {
                            Button {
                                devModel.createProject()
                            } label: {
                                Label("New", systemImage: "plus.rectangle.on.folder")
                                    .labelStyle(.titleAndIcon)
                            }
                            .buttonStyle(RoachPrimaryButtonStyle())

                            Button {
                                devModel.importProject()
                            } label: {
                                Label("Import…", systemImage: "square.and.arrow.down")
                                    .labelStyle(.titleAndIcon)
                            }
                            .buttonStyle(RoachSecondaryButtonStyle())

                            Button {
                                devModel.reloadWorkspace()
                                devModel.loadSecrets(storagePath: model.storagePath)
                                devModel.loadRoachBrain(storagePath: model.storagePath)
                            } label: {
                                Label("Reload", systemImage: "arrow.clockwise")
                                    .labelStyle(.titleAndIcon)
                            }
                            .buttonStyle(RoachSecondaryButtonStyle())
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Dev workspace")
                                .font(.roach(size: 16, weight: .semibold))
                                .foregroundStyle(RoachPalette.text)
                            Text(devModel.displayWorkingDirectory())
                                .font(.roach(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(RoachPalette.muted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                RoachTag(devModel.currentProjectName, accent: RoachPalette.cyan)
                                RoachTag(
                                    "\(RoachCopy.count(devModel.openDocuments.count, "tab"))",
                                    accent: RoachPalette.green)
                                RoachTag(
                                    "\(RoachCopy.count(devModel.terminalOutputLineCount, "terminal line"))",
                                    accent: RoachPalette.magenta)
                                RoachTag(
                                    "\(RoachCopy.count(devModel.secretRecords.count, "secret"))",
                                    accent: RoachPalette.bronze)
                            }
                        }

                        HStack(spacing: 6) {
                            Button("New") {
                                devModel.createProject()
                            }
                            .buttonStyle(RoachPrimaryButtonStyle())

                            Button("Import…") {
                                devModel.importProject()
                            }
                            .buttonStyle(RoachSecondaryButtonStyle())

                            Button("Reload") {
                                devModel.reloadWorkspace()
                                devModel.loadSecrets(storagePath: model.storagePath)
                                devModel.loadRoachBrain(storagePath: model.storagePath)
                            }
                            .buttonStyle(RoachSecondaryButtonStyle())
                        }
                    }
                }

                if devModel.importStatus != "Dev desk ready." {
                    Text(devModel.importStatus)
                        .font(.roach(size: 11, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private var devWorkbenchBody: some View {
        GeometryReader { geometry in
            let useStackedLayout = geometry.size.width < 760
            let useCompactLayout = geometry.size.width < 1_260

            Group {
                if useStackedLayout {
                    stackedWorkbenchLayout
                } else if useCompactLayout {
                    compactWorkbenchLayout
                } else {
                    expandedWorkbenchLayout
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minHeight: 420, maxHeight: .infinity, alignment: .topLeading)
    }

    private var expandedWorkbenchLayout: some View {
        HStack(alignment: .top, spacing: 14) {
            devWorkbenchShell {
                HStack(spacing: 0) {
                    fileExplorerColumn
                        .frame(width: 236)
                        .frame(maxHeight: .infinity, alignment: .topLeading)

                    verticalWorkbenchDivider

                    VStack(spacing: 0) {
                        editorColumn
                            .frame(minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                            .layoutPriority(1)

                        horizontalWorkbenchDivider

                        terminalColumn
                            .frame(minHeight: 220, idealHeight: 250, maxHeight: 320, alignment: .topLeading)
                            .layoutPriority(0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            sideRail
                .frame(minWidth: 274, idealWidth: 302, maxWidth: 320)
                .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var stackedWorkbenchLayout: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                devWorkbenchShell {
                    VStack(spacing: 12) {
                        fileExplorerColumn
                            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 260, alignment: .topLeading)

                        horizontalWorkbenchDivider

                        editorColumn
                            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 540, alignment: .topLeading)

                        horizontalWorkbenchDivider

                        terminalColumn
                            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 320, alignment: .topLeading)
                    }
                }

                sideRail
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var compactWorkbenchLayout: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                devWorkbenchShell {
                    VStack(spacing: 12) {
                        HStack(alignment: .top, spacing: 10) {
                            fileExplorerColumn
                                .frame(
                                    minWidth: 190, idealWidth: 220, maxWidth: 250, maxHeight: .infinity,
                                    alignment: .topLeading)

                            editorColumn(textEditorMinHeight: 280, documentDeckMinHeight: 380)
                                .frame(minWidth: 360, maxWidth: .infinity, minHeight: 420, alignment: .topLeading)
                        }

                        horizontalWorkbenchDivider

                        terminalColumn
                            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 330, alignment: .topLeading)
                    }
                }

                sideRail
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func devWorkbenchShell<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                RoachPalette.panelRaised.opacity(0.92),
                                RoachPalette.panel.opacity(0.82),
                                RoachPalette.shade.opacity(0.16),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous)
                    .stroke(RoachPalette.borderStrong, lineWidth: RoachMetrics.line(1))
            )
            .clipShape(RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous))
    }

    private var verticalWorkbenchDivider: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        Color.clear,
                        RoachPalette.borderStrong.opacity(0.92),
                        Color.clear,
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 1)
            .padding(.vertical, 10)
    }

    private var horizontalWorkbenchDivider: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        Color.clear,
                        RoachPalette.borderStrong.opacity(0.92),
                        Color.clear,
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 1)
            .padding(.horizontal, 10)
    }

    private var fileExplorerColumn: some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Explorer")
                            .font(.roach(size: 15, weight: .semibold))
                            .foregroundStyle(RoachPalette.text)
                        Text(devModel.displayWorkingDirectory())
                            .font(.roach(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(RoachPalette.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Text("\(devModel.filteredFileTree.count)")
                        .font(.roach(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(RoachPalette.muted)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        Button("New file…") {
                            devModel.createFile()
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())

                        Button("New folder…") {
                            devModel.createFolder()
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Button("New file…") {
                            devModel.createFile()
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())

                        Button("New folder…") {
                            devModel.createFolder()
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())
                    }
                }

                TextField("Filter files or folders", text: $devModel.fileSearchQuery)
                    .textFieldStyle(.plain)
                    .font(.roach(size: 12, weight: .medium))
                    .foregroundStyle(RoachPalette.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: RoachMetrics.radius(16), style: .continuous)
                            .fill(RoachPalette.panelRaised.opacity(0.64))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: RoachMetrics.radius(16), style: .continuous)
                            .stroke(RoachPalette.border, lineWidth: RoachMetrics.line(1))
                    )

                List {
                    OutlineGroup(devModel.filteredFileTree, children: \.children) { node in
                        Button {
                            if !node.isDirectory {
                                try? devModel.open(node: node)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: node.isDirectory ? "folder.fill" : "doc.plaintext")
                                    .foregroundStyle(node.isDirectory ? RoachPalette.bronze : RoachPalette.green)
                                Text(node.name)
                                    .font(.roach(size: 13, weight: .medium))
                                    .foregroundStyle(
                                        node.id == devModel.activeDocumentID ? RoachPalette.green : RoachPalette.text)
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .frame(minHeight: 160, maxHeight: .infinity)
            }
        }
    }

    private func heroSignalTile(
        kicker: String,
        title: String,
        detail: String,
        systemName: String,
        accent: Color
    ) -> some View {
        RoachFeatureTile(
            kicker,
            title: title,
            detail: detail,
            systemName: systemName,
            accent: accent
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var editorColumn: some View {
        editorColumn(textEditorMinHeight: 260, documentDeckMinHeight: 330)
    }

    private func editorColumn(
        textEditorMinHeight: CGFloat,
        documentDeckMinHeight: CGFloat
    ) -> some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Editor")
                            .font(.roach(size: 16, weight: .semibold))
                            .foregroundStyle(RoachPalette.text)
                        Text(devModel.activeDocumentLabel)
                            .font(.roach(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(RoachPalette.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    if let active = devModel.activeDocument {
                        RoachTag(
                            active.isDirty ? "Unsaved" : "Saved",
                            accent: active.isDirty ? RoachPalette.warning : RoachPalette.green)
                    }

                    RoachTag(devModel.activeDocumentLanguage, accent: RoachPalette.cyan)

                    Button("Save") {
                        devModel.saveActiveDocument()
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())
                }

                if devModel.openDocuments.isEmpty {
                    Text("Open a file from Explorer, or start a scratch file.")
                        .font(.roach(size: 14, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                        .frame(maxWidth: .infinity, minHeight: max(textEditorMinHeight, 220), alignment: .topLeading)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(devModel.openDocuments) { document in
                                documentTabChip(for: document)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) {
                                if !devModel.activeDocumentPathComponents.isEmpty {
                                    ForEach(Array(devModel.activeDocumentPathComponents.enumerated()), id: \.offset) {
                                        index, component in
                                        HStack(spacing: 6) {
                                            Text(component)
                                                .font(.roach(size: 11, weight: .medium, design: .monospaced))
                                                .foregroundStyle(
                                                    index == devModel.activeDocumentPathComponents.count - 1
                                                        ? RoachPalette.text : RoachPalette.muted
                                                )
                                                .lineLimit(1)
                                            if index < devModel.activeDocumentPathComponents.count - 1 {
                                                Image(systemName: "chevron.right")
                                                    .font(.roach(size: 8, weight: .bold))
                                                    .foregroundStyle(RoachPalette.muted)
                                            }
                                        }
                                    }
                                }

                                Spacer()

                                HStack(spacing: 8) {
                                    RoachTag(
                                        "\(RoachCopy.count(devModel.activeDocumentLineCount, "line"))",
                                        accent: RoachPalette.cyan)
                                    RoachTag(
                                        "\(RoachCopy.count(devModel.activeDocumentCharacterCount, "char"))",
                                        accent: RoachPalette.magenta)
                                }
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Editing in \(devModel.displayWorkingDirectory())")
                                    .font(.roach(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(RoachPalette.muted)
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                HStack(spacing: 8) {
                                    RoachTag(
                                        "\(RoachCopy.count(devModel.activeDocumentLineCount, "line"))",
                                        accent: RoachPalette.cyan)
                                    RoachTag(
                                        "\(RoachCopy.count(devModel.activeDocumentCharacterCount, "char"))",
                                        accent: RoachPalette.magenta)
                                }
                            }
                        }

                        editorAssistantToolbar

                        editorInlineAssistDock

                        VStack(alignment: .leading, spacing: 10) {
                            TextEditor(
                                text: Binding(
                                    get: { devModel.activeDocument?.text ?? "" },
                                    set: { devModel.updateActiveDocumentText($0) }
                                )
                            )
                            .font(.roach(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(RoachPalette.text)
                            .scrollContentBackground(.hidden)
                            .padding(14)
                            .frame(minHeight: textEditorMinHeight)
                            .background(
                                RoundedRectangle(cornerRadius: RoachMetrics.radius(20), style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: [
                                                RoachPalette.shade.opacity(0.28),
                                                RoachPalette.shade.opacity(0.22),
                                            ],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: RoachMetrics.radius(20), style: .continuous)
                                    .stroke(RoachPalette.borderStrong, lineWidth: RoachMetrics.line(1))
                            )
                        }
                        .frame(minHeight: documentDeckMinHeight)

                        HStack(spacing: 10) {
                            RoachTag(devModel.currentProjectName, accent: RoachPalette.bronze)
                            RoachTag(devModel.activeDocumentLanguage, accent: RoachPalette.cyan)
                            if let active = devModel.activeDocument {
                                RoachTag(
                                    active.isDirty ? "Unsaved buffer" : "Buffer clean",
                                    accent: active.isDirty ? RoachPalette.warning : RoachPalette.green)
                            }
                            Spacer()
                            Text(
                                "\(RoachCopy.count(devModel.activeDocumentLineCount, "line"))  ·  \(RoachCopy.count(devModel.activeDocumentCharacterCount, "char"))"
                            )
                            .font(.roach(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(RoachPalette.muted)
                        }
                    }
                }
            }
        }
    }

    private var editorAssistantToolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 10) {
                compactAssistModeButtons
                editorAssistantPromptField
                Button(devModel.aiIsRunning ? "Thinking…" : "Ask") {
                    selectedRailSection = .assist
                    Task {
                        await devModel.requestAssistant(using: model)
                    }
                }
                .buttonStyle(RoachPrimaryButtonStyle())
                .disabled(devModel.aiIsRunning)

                Button("Inspector") {
                    selectedRailSection = .assist
                }
                .buttonStyle(RoachSecondaryButtonStyle())
            }

            VStack(alignment: .leading, spacing: 10) {
                compactAssistModeButtons
                HStack(spacing: 10) {
                    editorAssistantPromptField
                    Button(devModel.aiIsRunning ? "Thinking…" : "Ask") {
                        selectedRailSection = .assist
                        Task {
                            await devModel.requestAssistant(using: model)
                        }
                    }
                    .buttonStyle(RoachPrimaryButtonStyle())
                    .disabled(devModel.aiIsRunning)
                }
            }
        }
    }

    private var compactAssistModeButtons: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(DeveloperAssistMode.allCases) { mode in
                    Button {
                        selectAssistMode(mode)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: mode.systemName)
                                .font(.roach(size: 10, weight: .bold))
                            Text(mode.rawValue)
                                .font(.roach(size: 11, weight: .semibold, design: .monospaced))
                                .lineLimit(1)
                                .minimumScaleFactor(0.82)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .foregroundStyle(devModel.assistantMode == mode ? RoachPalette.text : RoachPalette.muted)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .fixedSize(horizontal: true, vertical: false)
                        .background(
                            Capsule(style: .continuous)
                                .fill(
                                    devModel.assistantMode == mode
                                        ? mode.accent.opacity(0.22)
                                        : RoachPalette.panelRaised.opacity(0.72)
                                )
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(
                                    devModel.assistantMode == mode ? mode.accent.opacity(0.44) : RoachPalette.border,
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(mode.rawValue) assist mode")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var editorAssistantPromptField: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(RoachPalette.magenta)
                .font(.roach(size: 12, weight: .semibold))

            TextField("Ask about this file", text: $devModel.aiPrompt)
                .textFieldStyle(.plain)
                .font(.roach(size: 12, weight: .medium))
                .foregroundStyle(RoachPalette.text)
                .onSubmit {
                    selectedRailSection = .assist
                    Task {
                        await devModel.requestAssistant(using: model)
                    }
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minWidth: 220, maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: RoachMetrics.radius(16), style: .continuous)
                .fill(RoachPalette.panelRaised.opacity(0.74))
        )
        .overlay(
            RoundedRectangle(cornerRadius: RoachMetrics.radius(16), style: .continuous)
                .stroke(RoachPalette.border, lineWidth: RoachMetrics.line(1))
        )
    }

    private var editorInlineAssistDock: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 10) {
                    inlineAssistSummary
                    Spacer(minLength: 10)
                    inlineAssistActions
                }

                VStack(alignment: .leading, spacing: 10) {
                    inlineAssistSummary
                    inlineAssistActions
                }
            }

            Text(devModel.inlineCompletion.isEmpty ? inlineAssistPlaceholder : devModel.inlineCompletion)
                .font(.roach(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(
                    devModel.inlineCompletion.isEmpty ? RoachPalette.muted : RoachPalette.text.opacity(0.86)
                )
                .lineLimit(3)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            RoachPalette.panelRaised.opacity(0.88),
                            RoachPalette.shade.opacity(0.18),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous)
                .stroke(RoachPalette.borderStrong, lineWidth: RoachMetrics.line(1))
        )
    }

    private var inlineAssistSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(devModel.inlinePromptDirective == nil ? "Inline" : "Inline prompt")
                .font(.roach(size: 11, weight: .semibold, design: .monospaced))
                .tracking(1.1)
                .foregroundStyle(RoachPalette.muted)
            Text(devModel.inlineCompletionStatus)
                .font(.roach(size: 12, weight: .medium))
                .foregroundStyle(RoachPalette.muted)
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inlineAssistActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                inlineAssistStateTag
                inlineRetryButton
                inlineInsertButton
            }

            Menu {
                Button("Retry inline answer") {
                    Task {
                        await devModel.requestInlineCompletion(using: model, automatic: false)
                    }
                }
                Button("Insert completion") {
                    devModel.acceptInlineCompletion()
                }
                .disabled(devModel.inlineCompletion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } label: {
                Label("Inline", systemImage: "wand.and.stars")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(RoachSecondaryButtonStyle())
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var inlineAssistStateTag: some View {
        if devModel.inlineCompletionIsLoading {
            RoachTag("Watching", accent: RoachPalette.magenta)
                .fixedSize(horizontal: true, vertical: false)
        } else if !devModel.inlineCompletion.isEmpty {
            RoachTag("Ready", accent: RoachPalette.green)
                .fixedSize(horizontal: true, vertical: false)
        } else if devModel.inlinePromptDirective != nil {
            RoachTag("Prompt found", accent: RoachPalette.cyan)
                .fixedSize(horizontal: true, vertical: false)
        } else {
            RoachTag("Idle", accent: RoachPalette.cyan)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var inlineRetryButton: some View {
        Button("Retry") {
            Task {
                await devModel.requestInlineCompletion(using: model, automatic: false)
            }
        }
        .buttonStyle(RoachSecondaryButtonStyle())
        .fixedSize(horizontal: true, vertical: false)
    }

    private var inlineInsertButton: some View {
        Button("Insert") {
            devModel.acceptInlineCompletion()
        }
        .buttonStyle(RoachPrimaryButtonStyle())
        .fixedSize(horizontal: true, vertical: false)
        .disabled(devModel.inlineCompletion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var workspaceAssistRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                assistantWorkbenchPanel
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)

                inlineAssistPanel
                    .frame(minWidth: 320, idealWidth: 340, maxWidth: 380)
            }

            VStack(alignment: .leading, spacing: 12) {
                assistantWorkbenchPanel
                inlineAssistPanel
            }
        }
    }

    private var assistantWorkbenchPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("RoachClaw")
                            .font(.roach(size: 11, weight: .semibold, design: .monospaced))
                            .tracking(1.1)
                            .foregroundStyle(RoachPalette.muted)
                        Text("Code with RoachClaw on this Mac.")
                            .font(.roach(size: 17, weight: .semibold))
                            .foregroundStyle(RoachPalette.text)
                    }

                    Spacer(minLength: 12)

                    HStack(spacing: 8) {
                        RoachTag(model.selectedChatModelLabel, accent: RoachPalette.green)
                        RoachTag(devModel.assistantMode.rawValue, accent: devModel.assistantMode.accent)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("RoachClaw")
                        .font(.roach(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(1.1)
                        .foregroundStyle(RoachPalette.muted)
                    Text("Code with RoachClaw on this Mac.")
                        .font(.roach(size: 17, weight: .semibold))
                        .foregroundStyle(RoachPalette.text)

                    HStack(spacing: 8) {
                        RoachTag(model.selectedChatModelLabel, accent: RoachPalette.green)
                        RoachTag(devModel.assistantMode.rawValue, accent: devModel.assistantMode.accent)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(
                    "\(roachClawStatusText)  ·  \(devModel.assistantMode.rawValue)  ·  \(model.selectedChatModelLabel)"
                )
                .font(.roach(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(RoachPalette.text.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)
                if let activeDocument = devModel.activeDocument {
                    Text(activeDocument.relativePath)
                        .font(.roach(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(RoachPalette.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if cloudLaneText != "No cloud lane" {
                    Text(cloudLaneText)
                        .font(.roach(size: 11, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    assistantPromptPanel
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)

                    assistantResponsePanel
                        .frame(minWidth: 300, idealWidth: 330, maxWidth: 360, alignment: .topLeading)
                }

                VStack(alignment: .leading, spacing: 12) {
                    assistantPromptPanel
                    assistantResponsePanel
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: RoachMetrics.radius(20), style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            RoachPalette.panelRaised.opacity(0.82),
                            RoachPalette.shade.opacity(0.16),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: RoachMetrics.radius(20), style: .continuous)
                .stroke(RoachPalette.borderStrong, lineWidth: RoachMetrics.line(1))
        )
    }

    private var assistantPromptPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            assistModeButtons

            VStack(alignment: .leading, spacing: 8) {
                Text("Prompt")
                    .font(.roach(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(RoachPalette.muted)

                TextEditor(text: $devModel.aiPrompt)
                    .font(.roach(size: 13, weight: .medium))
                    .foregroundStyle(RoachPalette.text)
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .frame(minHeight: 118)
                    .background(
                        RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [RoachPalette.shade.opacity(0.28), RoachPalette.shade.opacity(0.18)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous)
                            .stroke(RoachPalette.borderStrong, lineWidth: RoachMetrics.line(1))
                    )
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    RoachTag(devModel.assistantMode.rawValue, accent: devModel.assistantMode.accent)
                    RoachTag(
                        devModel.activeDocument == nil ? "No file" : "File context",
                        accent: devModel.activeDocument == nil ? RoachPalette.warning : RoachPalette.green)
                    RoachTag(model.selectedChatModelLabel, accent: RoachPalette.cyan)
                }
            }

            HStack(spacing: 10) {
                Button(devModel.aiIsRunning ? "Thinking…" : "Ask RoachClaw") {
                    Task {
                        await devModel.requestAssistant(using: model)
                    }
                }
                .buttonStyle(RoachPrimaryButtonStyle())
                .disabled(devModel.aiIsRunning)

                if !devModel.aiResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("Insert in file") {
                        devModel.insertAssistantResponseIntoActiveDocument()
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())
                    .disabled(devModel.activeDocument == nil)
                }
            }
        }
    }

    private var assistantResponsePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Reply")
                        .font(.roach(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(1.1)
                        .foregroundStyle(RoachPalette.muted)
                    Text(devModel.aiResponse.isEmpty ? "Waiting" : "Live response")
                        .font(.roach(size: 15, weight: .semibold))
                        .foregroundStyle(RoachPalette.text)
                }

                Spacer()
                RoachTag(devModel.assistantMode.rawValue, accent: devModel.assistantMode.accent)
            }

            ScrollView(showsIndicators: false) {
                Text(
                    devModel.aiResponse.isEmpty
                        ? "Ask from the editor bar."
                        : devModel.aiResponse
                )
                .font(.roach(size: 13, weight: .medium))
                .foregroundStyle(devModel.aiResponse.isEmpty ? RoachPalette.muted : RoachPalette.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .frame(minHeight: 238)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                RoachPalette.shade.opacity(0.22),
                                RoachPalette.panelRaised.opacity(0.64),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous)
                    .stroke(RoachPalette.border, lineWidth: RoachMetrics.line(1))
            )

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    Button("Copy") {
                        devModel.copyAssistantResponse()
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())
                    .disabled(devModel.aiResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Save to RoachBrain") {
                        devModel.saveAssistantResponseToRoachBrain()
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())
                    .disabled(devModel.aiResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Button("Copy") {
                        devModel.copyAssistantResponse()
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())
                    .disabled(devModel.aiResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Save to RoachBrain") {
                        devModel.saveAssistantResponseToRoachBrain()
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())
                    .disabled(devModel.aiResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var inlineAssistPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Inline assist")
                            .font(.roach(size: 11, weight: .semibold, design: .monospaced))
                            .tracking(1.1)
                            .foregroundStyle(RoachPalette.muted)
                        Text(devModel.inlineCompletionStatus)
                            .font(.roach(size: 12, weight: .medium))
                            .foregroundStyle(RoachPalette.muted)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 10)

                    HStack(spacing: 8) {
                        if devModel.inlineCompletionIsLoading {
                            RoachTag("Watching file", accent: RoachPalette.magenta)
                        } else if !devModel.inlineCompletion.isEmpty {
                            RoachTag("Ready", accent: RoachPalette.green)
                        } else {
                            RoachTag("Idle", accent: RoachPalette.cyan)
                        }

                        Button("Refresh") {
                            Task {
                                await devModel.requestInlineCompletion(using: model, automatic: false)
                            }
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())

                        Button("Accept") {
                            devModel.acceptInlineCompletion()
                        }
                        .buttonStyle(RoachPrimaryButtonStyle())
                        .disabled(devModel.inlineCompletion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Inline assist")
                            .font(.roach(size: 11, weight: .semibold, design: .monospaced))
                            .tracking(1.1)
                            .foregroundStyle(RoachPalette.muted)
                        Text(devModel.inlineCompletionStatus)
                            .font(.roach(size: 12, weight: .medium))
                            .foregroundStyle(RoachPalette.muted)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 8) {
                        if devModel.inlineCompletionIsLoading {
                            RoachTag("Watching file", accent: RoachPalette.magenta)
                        } else if !devModel.inlineCompletion.isEmpty {
                            RoachTag("Ready", accent: RoachPalette.green)
                        } else {
                            RoachTag("Idle", accent: RoachPalette.cyan)
                        }

                        Button("Refresh") {
                            Task {
                                await devModel.requestInlineCompletion(using: model, automatic: false)
                            }
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())

                        Button("Accept") {
                            devModel.acceptInlineCompletion()
                        }
                        .buttonStyle(RoachPrimaryButtonStyle())
                        .disabled(devModel.inlineCompletion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }

            Text(devModel.inlineCompletion.isEmpty ? inlineAssistPlaceholder : devModel.inlineCompletion)
                .font(.roach(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(
                    devModel.inlineCompletion.isEmpty ? RoachPalette.muted : RoachPalette.text.opacity(0.84)
                )
                .lineLimit(5)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    RoachPalette.panelRaised.opacity(0.74),
                                    RoachPalette.shade.opacity(0.18),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous)
                        .stroke(
                            RoachPalette.border,
                            style: StrokeStyle(lineWidth: 1, dash: devModel.inlineCompletion.isEmpty ? [5, 5] : []))
                )
        }
    }

    private var inlineAssistPlaceholder: String {
        guard let document = devModel.activeDocument else {
            return "Open a file and leave // roachclaw: near the code you want to change."
        }

        if let directive = devModel.inlinePromptDirective {
            return "Inline prompt: " + directive.instruction
        }

        let prefix = DeveloperInlineAssistSupport.lineCommentPrefix(for: document.url.pathExtension)
        if prefix == "<!-- " {
            return "<!-- roachclaw: describe the next change here -->"
        }
        if prefix == "/* " {
            return "/* roachclaw: describe the next change here */"
        }
        if prefix.isEmpty {
            return "roachclaw: describe the next change here"
        }
        return prefix + "roachclaw: describe the next change here"
    }

    private var sideRail: some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Assist panel")
                            .font(.roach(size: 16, weight: .semibold))
                            .foregroundStyle(RoachPalette.text)
                        Text(devModel.assistantMode.rawValue)
                            .font(.roach(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(devModel.assistantMode.accent)
                    }
                    Spacer()
                    Text(devModel.terminalAwaitingPrompt ? "Live" : "Idle")
                        .font(.roach(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(devModel.terminalAwaitingPrompt ? RoachPalette.green : RoachPalette.muted)
                }

                railSectionPicker

                ScrollView(showsIndicators: false) {
                    Group {
                        switch selectedRailSection {
                        case .assist:
                            assistRailContent
                        case .memory:
                            memoryRailContent
                        case .secrets:
                            secretsRailContent
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private var railSectionPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(DeveloperRailSection.allCases) { section in
                    Button {
                        selectedRailSection = section
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(section.rawValue)
                                .font(.roach(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(selectedRailSection == section ? RoachPalette.text : RoachPalette.muted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: RoachMetrics.radius(14), style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            section.accent.opacity(selectedRailSection == section ? 0.18 : 0.08),
                                            RoachPalette.panelRaised.opacity(0.74),
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: RoachMetrics.radius(14), style: .continuous)
                                .stroke(
                                    selectedRailSection == section ? section.accent.opacity(0.35) : RoachPalette.border,
                                    lineWidth: RoachMetrics.line(1))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var assistRailContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("AI reply")
                        .font(.roach(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(1.1)
                        .foregroundStyle(RoachPalette.muted)
                    Text(devModel.aiResponse.isEmpty ? "Waiting" : "Ready")
                        .font(.roach(size: 16, weight: .semibold))
                        .foregroundStyle(RoachPalette.text)
                }

                Spacer()
                RoachTag(model.selectedChatModelLabel, accent: devModel.assistantMode.accent)
            }

            compactAssistModeButtons

            if devModel.assistantTurns.isEmpty {
                Text("No prompts yet.")
                    .font(.roach(size: 12, weight: .medium))
                    .foregroundStyle(RoachPalette.muted)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recent prompts")
                        .font(.roach(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(1.1)
                        .foregroundStyle(RoachPalette.muted)

                    ForEach(devModel.assistantTurns.prefix(4)) { turn in
                        Button {
                            selectAssistMode(turn.mode)
                            devModel.aiPrompt = turn.prompt
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Circle()
                                    .fill(turn.mode.accent)
                                    .frame(width: 8, height: 8)
                                    .padding(.top, 4)
                                Text(turn.prompt)
                                    .font(.roach(size: 12, weight: .semibold))
                                    .foregroundStyle(RoachPalette.text)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .lineLimit(2)
                            }
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: RoachMetrics.radius(14), style: .continuous)
                                    .fill(RoachPalette.panelRaised.opacity(0.58))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: RoachMetrics.radius(14), style: .continuous)
                                    .stroke(RoachPalette.border, lineWidth: RoachMetrics.line(1))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                ScrollView(showsIndicators: false) {
                    Text(
                        devModel.aiResponse.isEmpty
                            ? "Ask from the editor bar."
                            : devModel.aiResponse
                    )
                    .font(.roach(size: 13, weight: .medium))
                    .foregroundStyle(devModel.aiResponse.isEmpty ? RoachPalette.muted : RoachPalette.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                .frame(minHeight: 160)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    RoachPalette.shade.opacity(0.22),
                                    RoachPalette.panelRaised.opacity(0.64),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous)
                        .stroke(RoachPalette.border, lineWidth: RoachMetrics.line(1))
                )

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        Button("Copy") {
                            devModel.copyAssistantResponse()
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())
                        .disabled(devModel.aiResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button("Insert in file") {
                            devModel.insertAssistantResponseIntoActiveDocument()
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())
                        .disabled(
                            devModel.activeDocument == nil
                                || devModel.aiResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button("Save") {
                            devModel.saveAssistantResponseToRoachBrain()
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())
                        .disabled(devModel.aiResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Button("Copy") {
                            devModel.copyAssistantResponse()
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())
                        .disabled(devModel.aiResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        HStack(spacing: 10) {
                            Button("Insert in file") {
                                devModel.insertAssistantResponseIntoActiveDocument()
                            }
                            .buttonStyle(RoachSecondaryButtonStyle())
                            .disabled(
                                devModel.activeDocument == nil
                                    || devModel.aiResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                            Button("Save") {
                                devModel.saveAssistantResponseToRoachBrain()
                            }
                            .buttonStyle(RoachSecondaryButtonStyle())
                            .disabled(devModel.aiResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
            }
        }
    }

    private var guidebookPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Guidebook")
                        .font(.roach(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(1.1)
                        .foregroundStyle(RoachPalette.muted)
                    Text("Reference links.")
                        .font(.roach(size: 14, weight: .semibold))
                        .foregroundStyle(RoachPalette.text)
                }
                Spacer()
                RoachTag("Docs", accent: RoachPalette.cyan)
            }

            ForEach(guidebookResources) { resource in
                Button {
                    model.openPublicURL(resource.url, title: resource.title)
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(resource.title)
                            .font(.roach(size: 13, weight: .semibold))
                            .foregroundStyle(RoachPalette.text)
                        Text(resource.detail)
                            .font(.roach(size: 11, weight: .medium))
                            .foregroundStyle(RoachPalette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(resource.tags, id: \.self) { tag in
                                    RoachTag(tag, accent: RoachPalette.green)
                                }
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: RoachMetrics.radius(16), style: .continuous)
                            .fill(RoachPalette.panelRaised.opacity(0.62))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: RoachMetrics.radius(16), style: .continuous)
                            .stroke(RoachPalette.border, lineWidth: RoachMetrics.line(1))
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var memoryRailContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("RoachBrain")
                        .font(.roach(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(1.1)
                        .foregroundStyle(RoachPalette.muted)
                    Text(devModel.roachBrainStatus)
                        .font(.roach(size: 15, weight: .semibold))
                        .foregroundStyle(RoachPalette.text)
                }
                Spacer()
                RoachTag("\(devModel.roachBrainPinnedCount) pinned", accent: RoachPalette.magenta)
            }

            TextField("Search local memory", text: $devModel.roachBrainQuery)
                .textFieldStyle(.plain)
                .font(.roach(size: 12, weight: .medium))
                .foregroundStyle(RoachPalette.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: RoachMetrics.radius(16), style: .continuous)
                        .fill(RoachPalette.panelRaised.opacity(0.64))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: RoachMetrics.radius(16), style: .continuous)
                        .stroke(RoachPalette.border, lineWidth: RoachMetrics.line(1))
                )

            if devModel.roachBrainVisibleMatches.isEmpty {
                Text("Memories appear here after your first RoachClaw request, or when you save a reply.")
                    .font(.roach(size: 12, weight: .medium))
                    .foregroundStyle(RoachPalette.muted)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(devModel.roachBrainVisibleMatches.prefix(4)) { match in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(match.memory.title)
                                    .font(.roach(size: 12, weight: .semibold))
                                    .foregroundStyle(RoachPalette.text)
                                    .lineLimit(1)
                                Spacer()
                                if match.memory.pinned {
                                    RoachTag("Pinned", accent: RoachPalette.magenta)
                                }
                            }

                            Text(match.memory.summary)
                                .font(.roach(size: 11, weight: .medium))
                                .foregroundStyle(RoachPalette.muted)
                                .fixedSize(horizontal: false, vertical: true)

                            if !match.memory.tags.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 6) {
                                        ForEach(match.memory.tags.prefix(4), id: \.self) { tag in
                                            RoachTag(tag, accent: RoachPalette.cyan)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: RoachMetrics.radius(16), style: .continuous)
                                .fill(RoachPalette.shade.opacity(0.18))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: RoachMetrics.radius(16), style: .continuous)
                                .stroke(RoachPalette.border, lineWidth: RoachMetrics.line(1))
                        )
                    }
                }
            }
        }
    }

    private var secretsRailContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Secrets")
                        .font(.roach(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(1.1)
                        .foregroundStyle(RoachPalette.muted)
                    Text("Keychain-backed workspace values.")
                        .font(.roach(size: 15, weight: .semibold))
                        .foregroundStyle(RoachPalette.text)
                }
                Spacer()
                Text("\(devModel.secretRecords.count)")
                    .font(.roach(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(RoachPalette.muted)
            }

            if !devModel.secretScopeSummary.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(devModel.secretScopeSummary) { summary in
                            HStack(spacing: 6) {
                                Text(summary.title)
                                    .lineLimit(1)
                                Text("\(summary.count)")
                                    .foregroundStyle(RoachPalette.green)
                            }
                            .font(.roach(size: 10, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(RoachPalette.panel.opacity(0.9))
                            )
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(RoachPalette.border, lineWidth: RoachMetrics.line(1))
                            )
                        }
                    }
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(devModel.suggestedTemplates) { template in
                        Button(template.key) {
                            devModel.stageTemplate(template)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            Capsule(style: .continuous)
                                .fill(RoachPalette.panelRaised.opacity(0.52))
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(RoachPalette.border, lineWidth: RoachMetrics.line(1))
                        )
                        .foregroundStyle(RoachPalette.text)
                        .font(.roach(size: 11, weight: .semibold, design: .monospaced))
                    }
                }
            }

            Text(
                "Templates fill in the label and scope. Values are stored in Keychain and stay hidden until you press Reveal."
            )
            .font(.roach(size: 11, weight: .medium))
            .foregroundStyle(RoachPalette.muted)

            if !devModel.secretRecords.isEmpty {
                Picker(
                    "Secret",
                    selection: Binding(
                        get: { devModel.selectedSecretID ?? "" },
                        set: { newValue in
                            devModel.selectSecret(devModel.secretRecords.first(where: { $0.id == newValue }))
                        }
                    )
                ) {
                    Text("New secret").tag("")
                    ForEach(devModel.secretRecords) { record in
                        Text(record.label).tag(record.id)
                    }
                }
                .pickerStyle(.menu)
            }

            RoachInlineField(title: "Label", value: $devModel.secretLabelDraft, placeholder: "GitHub Token")
            RoachInlineField(title: "Key", value: $devModel.secretKeyDraft, placeholder: "GITHUB_TOKEN")
            RoachInlineField(title: "Scope", value: $devModel.secretScopeDraft, placeholder: "Release builds")
            RoachInlineField(
                title: "Notes", value: $devModel.secretNotesDraft,
                placeholder: "Used by release builds; rotates every 90 days")

            VStack(alignment: .leading, spacing: 8) {
                Text("Value")
                    .font(.roach(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(RoachPalette.muted)

                SecureField("Secret value", text: $devModel.secretValueDraft)
                    .textFieldStyle(.plain)
                    .font(.roach(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(RoachPalette.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [RoachPalette.panelRaised.opacity(0.72), RoachPalette.panel.opacity(0.62)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous)
                            .stroke(RoachPalette.borderStrong, lineWidth: RoachMetrics.line(1))
                    )
            }

            if !devModel.revealedSecretValue.isEmpty {
                Text("Revealed value: \(devModel.revealedSecretValue)")
                    .font(.roach(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(RoachPalette.green)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    Button("Reveal") {
                        devModel.revealSelectedSecret()
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())
                    .disabled(devModel.selectedSecret == nil)

                    Button("Save") {
                        devModel.saveSecret(storagePath: model.storagePath)
                    }
                    .buttonStyle(RoachPrimaryButtonStyle())

                    Button("Delete") {
                        devModel.deleteSelectedSecret(storagePath: model.storagePath)
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())
                    .disabled(devModel.selectedSecret == nil)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Button("Reveal") {
                        devModel.revealSelectedSecret()
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())
                    .disabled(devModel.selectedSecret == nil)

                    HStack(spacing: 10) {
                        Button("Save") {
                            devModel.saveSecret(storagePath: model.storagePath)
                        }
                        .buttonStyle(RoachPrimaryButtonStyle())

                        Button("Delete") {
                            devModel.deleteSelectedSecret(storagePath: model.storagePath)
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())
                        .disabled(devModel.selectedSecret == nil)
                    }
                }
            }
        }
    }

    private func documentTabChip(for document: DeveloperDocument) -> some View {
        let isActive = devModel.activeDocumentID == document.id

        return ZStack(alignment: .topTrailing) {
            Button {
                devModel.activeDocumentID = document.id
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: document.isDirty ? "circle.fill" : "circle")
                        .font(.roach(size: 7, weight: .bold))
                    Text(document.relativePath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.roach(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(isActive ? RoachPalette.text : RoachPalette.muted)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .padding(.trailing, 20)
                .background(
                    Capsule(style: .continuous)
                        .fill(isActive ? RoachPalette.panelSoft.opacity(0.86) : RoachPalette.panelRaised.opacity(0.50))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(
                            isActive ? RoachPalette.green.opacity(0.26) : RoachPalette.border,
                            lineWidth: RoachMetrics.line(1))
                )
            }
            .buttonStyle(.plain)

            Button {
                devModel.closeDocument(id: document.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.roach(size: 8, weight: .semibold))
                    .foregroundStyle(RoachPalette.muted)
                    .frame(width: 18, height: 18)
                    .background(
                        Circle()
                            .fill(RoachPalette.shade.opacity(0.22))
                    )
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
            .padding(.trailing, 5)
        }
    }

    private var terminalControlStrip: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 10) {
                terminalThemeRail

                Spacer(minLength: 8)

                terminalUtilityControls
                    .fixedSize(horizontal: true, vertical: false)
            }

            VStack(alignment: .leading, spacing: 10) {
                terminalThemeRail
                terminalUtilityControls
            }
        }
    }

    private var terminalUtilityControls: some View {
        HStack(spacing: 6) {
            terminalIconButton(
                title: "Decrease terminal font size",
                systemName: "textformat.size.smaller",
                tint: RoachPalette.cyan
            ) {
                devModel.decreaseTerminalFontSize()
            }

            terminalIconButton(
                title: "Increase terminal font size",
                systemName: "textformat.size.larger",
                tint: RoachPalette.cyan
            ) {
                devModel.increaseTerminalFontSize()
            }

            terminalIconButton(
                title: devModel.terminalSoftWrap ? "Turn terminal wrap off" : "Turn terminal wrap on",
                systemName: devModel.terminalSoftWrap ? "arrow.left.and.right.text.vertical" : "arrow.left.and.right",
                tint: devModel.terminalSoftWrap ? RoachPalette.green : RoachPalette.muted
            ) {
                devModel.terminalSoftWrap.toggle()
            }

            terminalIconButton(
                title: "Cycle terminal theme",
                systemName: "paintpalette.fill",
                tint: RoachPalette.magenta
            ) {
                devModel.cycleTerminalTheme()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func terminalIconButton(
        title: String,
        systemName: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.roach(size: 13, weight: .semibold))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(RoachUtilityButtonStyle(tint: tint))
        .help(title)
        .accessibilityLabel(title)
    }

    private var terminalThemeRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(DeveloperTerminalTheme.allCases) { theme in
                    Button {
                        devModel.terminalTheme = theme
                    } label: {
                        HStack(spacing: 7) {
                            Circle()
                                .fill(theme.accent)
                                .frame(width: 8, height: 8)
                                .shadow(color: theme.accent.opacity(RoachMetrics.glow(0.45)), radius: 8, x: 0, y: 0)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(theme.rawValue)
                                    .font(.roach(size: 11, weight: .semibold, design: .monospaced))
                            }
                        }
                        .foregroundStyle(devModel.terminalTheme == theme ? RoachPalette.text : RoachPalette.muted)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            Capsule(style: .continuous)
                                .fill(
                                    devModel.terminalTheme == theme
                                        ? theme.accent.opacity(0.18) : RoachPalette.panelRaised.opacity(0.58))
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(
                                    devModel.terminalTheme == theme ? theme.accent.opacity(0.44) : RoachPalette.border,
                                    lineWidth: RoachMetrics.line(1))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var terminalPromptField: some View {
        HStack(spacing: 10) {
            Text("$")
                .font(.roach(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(RoachPalette.green)
                .padding(.leading, 14)

            TextField("Shell command", text: $devModel.terminalCommand)
                .textFieldStyle(.plain)
                .font(.roach(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(RoachPalette.text)
                .onSubmit {
                    devModel.runTerminalCommand()
                }
                .padding(.vertical, 12)
                .padding(.trailing, 14)
        }
        .background(
            RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous)
                .fill(RoachPalette.shade.opacity(0.22))
        )
        .overlay(
            RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous)
                .stroke(RoachPalette.border, lineWidth: RoachMetrics.line(1))
        )
    }

    private var terminalCommandActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                terminalRunButton(iconOnly: false)
                terminalInterruptButton(iconOnly: false)
                terminalNewSessionButton(iconOnly: false)
                terminalClearButton(iconOnly: false)
                terminalCopyButton(iconOnly: false)
            }
            .fixedSize(horizontal: true, vertical: false)

            HStack(spacing: 6) {
                terminalRunButton(iconOnly: true)
                terminalInterruptButton(iconOnly: true)
                terminalNewSessionButton(iconOnly: true)
                terminalClearButton(iconOnly: true)
                terminalCopyButton(iconOnly: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func terminalRunButton(iconOnly: Bool) -> some View {
        if iconOnly {
            Button {
                devModel.runTerminalCommand()
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.roach(size: 13, weight: .semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(RoachUtilityButtonStyle(tint: RoachPalette.green))
            .disabled(devModel.terminalCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Run command")
            .accessibilityLabel("Run command")
        } else {
            Button {
                devModel.runTerminalCommand()
            } label: {
                Label("Run", systemImage: "paperplane.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(RoachPrimaryButtonStyle())
            .disabled(devModel.terminalCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Run command")
            .accessibilityLabel("Run command")
        }
    }

    @ViewBuilder
    private func terminalInterruptButton(iconOnly: Bool) -> some View {
        if iconOnly {
            Button {
                devModel.stopTerminalCommand()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.roach(size: 13, weight: .semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(RoachUtilityButtonStyle(tint: RoachPalette.warning))
            .disabled(!devModel.terminalIsRunning)
            .help("Interrupt command")
            .accessibilityLabel("Interrupt command")
        } else {
            Button {
                devModel.stopTerminalCommand()
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(RoachSecondaryButtonStyle())
            .disabled(!devModel.terminalIsRunning)
            .help("Interrupt command")
            .accessibilityLabel("Interrupt command")
        }
    }

    @ViewBuilder
    private func terminalNewSessionButton(iconOnly: Bool) -> some View {
        if iconOnly {
            Button {
                devModel.relaunchTerminalSession()
            } label: {
                Image(systemName: "plus.rectangle.on.rectangle")
                    .font(.roach(size: 13, weight: .semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(RoachUtilityButtonStyle(tint: RoachPalette.cyan))
            .help("Start new terminal session")
            .accessibilityLabel("Start new terminal session")
        } else {
            Button {
                devModel.relaunchTerminalSession()
            } label: {
                Label("New", systemImage: "plus.rectangle.on.rectangle")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(RoachSecondaryButtonStyle())
            .help("Start new terminal session")
            .accessibilityLabel("Start new terminal session")
        }
    }

    @ViewBuilder
    private func terminalClearButton(iconOnly: Bool) -> some View {
        if iconOnly {
            Button {
                devModel.clearTerminalOutput()
            } label: {
                Image(systemName: "eraser.fill")
                    .font(.roach(size: 13, weight: .semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(RoachUtilityButtonStyle(tint: RoachPalette.bronze))
            .help("Clear terminal output")
            .accessibilityLabel("Clear terminal output")
        } else {
            Button {
                devModel.clearTerminalOutput()
            } label: {
                Label("Clear", systemImage: "eraser.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(RoachSecondaryButtonStyle())
            .help("Clear terminal output")
            .accessibilityLabel("Clear terminal output")
        }
    }

    @ViewBuilder
    private func terminalCopyButton(iconOnly: Bool) -> some View {
        if iconOnly {
            Button {
                devModel.copyTerminalOutput()
            } label: {
                Image(systemName: "doc.on.doc.fill")
                    .font(.roach(size: 13, weight: .semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(RoachUtilityButtonStyle(tint: RoachPalette.magenta))
            .disabled(devModel.terminalOutput.isEmpty)
            .help("Copy terminal output")
            .accessibilityLabel("Copy terminal output")
        } else {
            Button {
                devModel.copyTerminalOutput()
            } label: {
                Label("Copy", systemImage: "doc.on.doc.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(RoachSecondaryButtonStyle())
            .disabled(devModel.terminalOutput.isEmpty)
            .help("Copy terminal output")
            .accessibilityLabel("Copy terminal output")
        }
    }

    private var terminalColumn: some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        RoachSectionHeader(
                            "Terminal",
                            title: devModel.terminalStatus,
                            detail: devModel.displayWorkingDirectory()
                        )

                        Spacer(minLength: 12)

                        VStack(alignment: .trailing, spacing: 6) {
                            Text(devModel.terminalStatus)
                                .font(.roach(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(
                                    devModel.terminalAwaitingPrompt ? RoachPalette.green : RoachPalette.muted)
                            Text(devModel.displayWorkingDirectory())
                                .font(.roach(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(RoachPalette.muted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        RoachSectionHeader(
                            "Terminal",
                            title: devModel.terminalStatus,
                            detail: devModel.displayWorkingDirectory()
                        )

                        VStack(alignment: .leading, spacing: 4) {
                            Text(devModel.terminalStatus)
                                .font(.roach(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(
                                    devModel.terminalAwaitingPrompt ? RoachPalette.green : RoachPalette.muted)
                            Text(devModel.displayWorkingDirectory())
                                .font(.roach(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(RoachPalette.muted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }

                terminalControlStrip

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 12) {
                        Menu {
                            ForEach(devModel.terminalDirectoryShortcuts) { shortcut in
                                Button("\(shortcut.title)  \(shortcut.displayName)") {
                                    devModel.setTerminalWorkingDirectory(shortcut.path)
                                }
                            }
                        } label: {
                            Label("Working folder", systemImage: "folder")
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())

                        if !devModel.isTerminalFollowingActiveContext {
                            Button("Follow file") {
                                devModel.followTerminalActiveContext()
                            }
                            .buttonStyle(RoachSecondaryButtonStyle())
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Menu {
                                ForEach(devModel.terminalDirectoryShortcuts) { shortcut in
                                    Button("\(shortcut.title)  \(shortcut.displayName)") {
                                        devModel.setTerminalWorkingDirectory(shortcut.path)
                                    }
                                }
                            } label: {
                                Label("Working folder", systemImage: "folder")
                                    .labelStyle(.titleAndIcon)
                            }
                            .buttonStyle(RoachSecondaryButtonStyle())

                            if !devModel.isTerminalFollowingActiveContext {
                                Button("Follow file") {
                                    devModel.followTerminalActiveContext()
                                }
                                .buttonStyle(RoachSecondaryButtonStyle())
                            }
                        }
                    }
                }

                if !devModel.terminalRecentCommands.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recent commands")
                            .font(.roach(size: 11, weight: .semibold, design: .monospaced))
                            .tracking(1.1)
                            .foregroundStyle(RoachPalette.muted)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(devModel.terminalRecentCommands, id: \.self) { command in
                                    Button(command) {
                                        devModel.terminalCommand = command
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(RoachPalette.shade.opacity(0.24))
                                    )
                                    .overlay(
                                        Capsule(style: .continuous)
                                            .stroke(RoachPalette.border, lineWidth: RoachMetrics.line(1))
                                    )
                                    .foregroundStyle(RoachPalette.text)
                                    .font(.roach(size: 11, weight: .semibold, design: .monospaced))
                                }
                            }
                        }
                    }
                }

                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(RoachPalette.warning)
                            .frame(width: 10, height: 10)
                        Circle()
                            .fill(RoachPalette.bronze)
                            .frame(width: 10, height: 10)
                        Circle()
                            .fill(RoachPalette.green)
                            .frame(width: 10, height: 10)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Terminal")
                                .font(.roach(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(RoachPalette.text)
                            Text(devModel.displayWorkingDirectory())
                                .font(.roach(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(RoachPalette.muted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Spacer()

                        Text(devModel.terminalAwaitingPrompt ? "Command running" : "Prompt ready")
                            .font(.roach(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(
                                devModel.terminalAwaitingPrompt ? RoachPalette.green : RoachPalette.magenta)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(RoachPalette.panelRaised.opacity(0.78))

                    Rectangle()
                        .fill(RoachPalette.borderStrong.opacity(0.9))
                        .frame(height: 1)

                    ScrollView(
                        devModel.terminalSoftWrap ? .vertical : [.vertical, .horizontal], showsIndicators: false
                    ) {
                        VStack(alignment: .leading, spacing: 8) {
                            if devModel.terminalOutput.isEmpty {
                                Text("Opening the shell.")
                                    .font(.roach(size: devModel.terminalFontSize, weight: .medium, design: .monospaced))
                                    .foregroundStyle(devModel.terminalTheme.mutedForeground)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Text("user@roachnet " + devModel.displayWorkingDirectory() + " %")
                                    .font(
                                        .roach(size: devModel.terminalFontSize, weight: .semibold, design: .monospaced)
                                    )
                                    .foregroundStyle(devModel.terminalTheme.accent)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                Text(devModel.terminalOutput)
                                    .font(.roach(size: devModel.terminalFontSize, weight: .medium, design: .monospaced))
                                    .foregroundStyle(devModel.terminalTheme.outputForeground)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: !devModel.terminalSoftWrap, vertical: true)
                            }
                        }
                        .padding(14)
                        .textSelection(.enabled)
                    }
                    .frame(minHeight: devModel.terminalViewportHeight)
                    .background(
                        LinearGradient(
                            colors: devModel.terminalTheme.backgroundColors,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                    Rectangle()
                        .fill(RoachPalette.borderStrong.opacity(0.9))
                        .frame(height: 1)

                    VStack(alignment: .leading, spacing: 12) {
                        terminalPromptField
                        terminalCommandActions
                    }
                    .padding(12)
                    .background(
                        LinearGradient(
                            colors: [RoachPalette.panelRaised.opacity(0.86), RoachPalette.panel.opacity(0.72)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            Text(
                                "zsh  ·  \(devModel.terminalTheme.rawValue)  ·  \(RoachCopy.count(devModel.terminalOutputLineCount, "line"))  ·  \(devModel.terminalHistoryCount) recent"
                            )
                            .font(.roach(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(RoachPalette.text.opacity(0.92))
                            .lineLimit(1)
                            Spacer()
                            Text(devModel.terminalIsRunning ? "session live" : "offline")
                                .font(.roach(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(RoachPalette.muted)
                                .lineLimit(1)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(
                                "zsh  ·  \(devModel.terminalTheme.rawValue)  ·  \(RoachCopy.count(devModel.terminalOutputLineCount, "line"))"
                            )
                            .font(.roach(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(RoachPalette.text.opacity(0.92))
                            Text(devModel.terminalIsRunning ? "session live" : "offline")
                                .font(.roach(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(RoachPalette.muted)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(RoachPalette.shade.opacity(0.22))
                }
                .clipShape(RoundedRectangle(cornerRadius: RoachMetrics.radius(20), style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: RoachMetrics.radius(20), style: .continuous)
                        .stroke(RoachPalette.borderStrong, lineWidth: RoachMetrics.line(1))
                )
            }
        }
    }

    @ViewBuilder
    private var assistModeButtons: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 172, maximum: 260), spacing: 8)],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(DeveloperAssistMode.allCases) { mode in
                Button {
                    selectAssistMode(mode)
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 10) {
                            ZStack {
                                Circle()
                                    .fill(mode.accent.opacity(mode == devModel.assistantMode ? 0.22 : 0.12))
                                    .frame(width: 32, height: 32)

                                Image(systemName: mode.systemName)
                                    .font(.roach(size: 13, weight: .bold))
                                    .foregroundStyle(mode.accent)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text(mode.rawValue)
                                    .font(.roach(size: 12, weight: .semibold))
                                    .foregroundStyle(RoachPalette.text)
                                    .lineLimit(1)
                                Text(mode.detail)
                                    .font(.roach(size: 11, weight: .medium))
                                    .foregroundStyle(RoachPalette.muted)
                                    .multilineTextAlignment(.leading)
                                    .lineLimit(2)
                            }

                            Spacer(minLength: 6)

                            Image(systemName: mode == devModel.assistantMode ? "checkmark.circle.fill" : "circle")
                                .font(.roach(size: 14, weight: .bold))
                                .foregroundStyle(mode == devModel.assistantMode ? mode.accent : RoachPalette.muted)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
                    .background(
                        RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        mode.accent.opacity(mode == devModel.assistantMode ? 0.16 : 0.08),
                                        RoachPalette.panelRaised.opacity(0.78),
                                        RoachPalette.shade.opacity(0.12),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous)
                            .stroke(
                                mode == devModel.assistantMode ? mode.accent.opacity(0.52) : RoachPalette.border,
                                lineWidth: 1
                            )
                    )
                }
                .buttonStyle(RoachCardButtonStyle())
            }
        }
    }

    private func selectAssistMode(_ mode: DeveloperAssistMode) {
        devModel.assistantMode = mode
    }
}
