import AppKit
import Foundation
import SwiftUI
import RoachNetCore
import RoachNetDesign

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

@MainActor
final class DevWorkspaceModel: ObservableObject {
    @Published var storagePath = ""
    @Published var workspaceRootPath = ""
    @Published var projectsRootPath = ""
    @Published var installPath = ""
    @Published var importStatus = "Developer workspace ready."
    @Published var lastError: String?
    @Published var fileSearchQuery = ""
    @Published var fileTree: [DeveloperFileNode] = []
    @Published var openDocuments: [DeveloperDocument] = []
    @Published var activeDocumentID: String?
    @Published var terminalCommand = "pwd"
    @Published var terminalOutput = ""
    @Published var terminalIsRunning = false
    @Published var terminalStatus = "Shell idle."
    @Published var aiPrompt = "Review the open file and suggest the next code change."
    @Published var aiResponse = ""
    @Published var aiIsRunning = false
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
    @Published var roachBrainStatus = "RoachBrain is ready."

    private var commandProcess: Process?
    private let dateFormatter = ISO8601DateFormatter()

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

    var activeDocumentLineCount: Int {
        guard let activeDocument else { return 0 }
        return max(activeDocument.text.components(separatedBy: .newlines).count, 1)
    }

    var activeDocumentCharacterCount: Int {
        activeDocument?.text.count ?? 0
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
                    """.replacingOccurrences(of: "${fileName}", with: fileName.replacingOccurrences(of: "-", with: "_"))
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
                ),
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
                    detail: "Add a compact CLI usage path.",
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
                ),
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
                ),
            ]
        }
    }

    var contextualTerminalCommands: [String] {
        guard let activeDocument else {
            return terminalPresets
        }

        let pathExtension = activeDocument.url.pathExtension.lowercased()
        let fileName = activeDocument.url.lastPathComponent

        switch pathExtension {
        case "swift":
            return ["swift build", "swift test", "swift run"]
        case "ts", "tsx", "js", "jsx":
            return ["npm install", "npm test", "npm run dev"]
        case "py":
            return ["python \(fileName)", "python -m pytest", "ruff check ."]
        case "go":
            return ["go run .", "go test ./...", "go fmt ./..."]
        case "rs":
            return ["cargo run", "cargo test", "cargo fmt"]
        case "cs":
            return ["dotnet build", "dotnet run", "dotnet test"]
        case "sh", "zsh":
            return ["bash \(fileName)", "shellcheck \(fileName)", "chmod +x \(fileName)"]
        default:
            return ["git status --short", "ls -la", "pwd"]
        }
    }

    var filteredFileTree: [DeveloperFileNode] {
        let query = fileSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return fileTree }
        return filterNodes(fileTree, query: query.lowercased())
    }

    let assistantPromptPresets: [String] = [
        "Review the open file and suggest the safest next change.",
        "Explain this code path in plain English and call out risk.",
        "Write a focused test plan for the open file.",
        "Propose a refactor that improves readability without changing behavior.",
        "Suggest the next implementation step and include the shell commands to verify it.",
        "Draft a clean commit message and release note summary from the current file changes.",
        "Point out the missing secrets, env values, or deploy assumptions for this project.",
    ]

    let terminalPresets: [String] = [
        "pwd",
        "git status --short",
        "ls -la",
        "swift test",
        "npm test",
        "pnpm test",
        "python -m pytest",
        "cargo test",
    ]

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
           (!fileTree.isEmpty || !secretRecords.isEmpty || !roachBrainMemories.isEmpty)
        {
            return
        }

        self.workspaceRootPath = workspaceRootPath
        self.projectsRootPath = projectsRootPath
        self.installPath = installPath

        do {
            try RoachNetDeveloperPaths.ensureWorkspaceDirectories(storagePath: storagePath)
            try seedWorkspaceIfNeeded()
            reloadWorkspace()
            loadSecrets(storagePath: storagePath)
            loadRoachBrain(storagePath: storagePath)
            importStatus = "Developer workspace ready."
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            importStatus = "Developer workspace unavailable."
        }
    }

    func reloadWorkspace() {
        guard !projectsRootPath.isEmpty else { return }

        do {
            fileTree = try buildFileNodes(at: URL(fileURLWithPath: projectsRootPath), root: URL(fileURLWithPath: projectsRootPath))
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
        panel.title = "Import Project into RoachNet"
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
                    userInfo: [NSLocalizedDescriptionKey: "A project named \(sourceURL.lastPathComponent) already exists in the RoachNet workspace."]
                )
            }

            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            importStatus = "Imported \(sourceURL.lastPathComponent)."
            reloadWorkspace()
        } catch {
            lastError = error.localizedDescription
            importStatus = "Project import failed."
        }
    }

    func createProject() {
        guard !projectsRootPath.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "New RoachNet Project"
        alert.informativeText = "Create a project folder inside the RoachNet vault and seed it with a starter language."
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
            lastError = "Enter a project name before creating the workspace."
            importStatus = "Project creation failed."
            return
        }

        do {
            let projectURL = URL(fileURLWithPath: projectsRootPath).appendingPathComponent(projectName, isDirectory: true)
            let sourceURL = projectURL.appendingPathComponent("src", isDirectory: true)
            let notesURL = projectURL.appendingPathComponent("notes", isDirectory: true)
            let fileManager = FileManager.default

            guard !fileManager.fileExists(atPath: projectURL.path) else {
                throw NSError(
                    domain: "RoachNetDevWorkspace",
                    code: 12,
                    userInfo: [NSLocalizedDescriptionKey: "A project named \(projectName) already exists in the RoachNet workspace."]
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
            importStatus = "Created \(projectName) in the RoachNet vault."
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            importStatus = "Project creation failed."
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
            importStatus = "Could not create a scratch file."
        }
    }

    func createFile() {
        guard !projectsRootPath.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "New File"
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
            importStatus = "File creation failed."
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
                    userInfo: [NSLocalizedDescriptionKey: "\(normalizedRelativePath) already exists."]
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
            importStatus = "File creation failed."
        }
    }

    func createFolder() {
        guard !projectsRootPath.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "New Folder"
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
            importStatus = "Folder creation failed."
            return
        }

        do {
            let folderURL = URL(fileURLWithPath: projectsRootPath).appendingPathComponent(normalizedRelativePath, isDirectory: true)
            guard !FileManager.default.fileExists(atPath: folderURL.path) else {
                throw NSError(
                    domain: "RoachNetDevWorkspace",
                    code: 22,
                    userInfo: [NSLocalizedDescriptionKey: "\(normalizedRelativePath) already exists."]
                )
            }

            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            reloadWorkspace()
            importStatus = "Created \(normalizedRelativePath)."
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            importStatus = "Folder creation failed."
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
            importStatus = "File save failed."
        }
    }

    func updateActiveDocumentText(_ value: String) {
        guard let activeDocumentID, let index = openDocuments.firstIndex(where: { $0.id == activeDocumentID }) else {
            return
        }

        openDocuments[index].text = value
        openDocuments[index].isDirty = true
    }

    func closeDocument(id: String) {
        openDocuments.removeAll { $0.id == id }
        if activeDocumentID == id {
            activeDocumentID = openDocuments.first?.id
        }
    }

    func runTerminalCommand() {
        guard !terminalIsRunning else { return }
        let command = terminalCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }

        stopTerminalCommand()

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = URL(fileURLWithPath: currentWorkingDirectory())
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = [
            "PATH": RoachNetRepositoryLocator.preferredBinarySearchPath(),
            "HOME": NSHomeDirectory(),
            "TERM": "xterm-256color",
        ]

        let startLine = "\n$ \(command)\n"
        appendTerminalOutput(startLine)
        terminalIsRunning = true
        terminalStatus = "Running in \(currentWorkingDirectory())."
        lastError = nil

        let handleOutput: (FileHandle) -> Void = { [weak self] handle in
            handle.readabilityHandler = { pipeHandle in
                let data = pipeHandle.availableData
                guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                Task { @MainActor in
                    self?.appendTerminalOutput(chunk)
                }
            }
        }

        handleOutput(stdoutPipe.fileHandleForReading)
        handleOutput(stderrPipe.fileHandleForReading)

        process.terminationHandler = { [weak self] finishedProcess in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                self?.terminalIsRunning = false
                self?.terminalStatus = "Exited with code \(finishedProcess.terminationStatus)."
                self?.appendTerminalOutput("\n[process exited with code \(finishedProcess.terminationStatus)]\n")
                self?.commandProcess = nil
            }
        }

        do {
            try process.run()
            commandProcess = process
        } catch {
            terminalIsRunning = false
            terminalStatus = "Launch failed."
            lastError = error.localizedDescription
        }
    }

    func stopTerminalCommand() {
        guard let commandProcess else { return }
        if commandProcess.isRunning {
            commandProcess.terminate()
        }
        self.commandProcess = nil
    }

    func clearTerminalOutput() {
        terminalOutput = ""
        terminalStatus = terminalIsRunning ? terminalStatus : "Shell cleared."
    }

    func copyTerminalOutput() {
        copyToPasteboard(terminalOutput)
        importStatus = "Copied terminal output."
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
        roachBrainStatus = roachBrainMemories.isEmpty
            ? "No memory stored yet."
            : "\(roachBrainMemories.count) local memories ready."
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
            revealedSecretValue = try RoachNetKeychainSecretStore.secretValue(id: selectedSecret.id, installPath: installPath) ?? ""
            secretValueDraft = revealedSecretValue
            importStatus = "Loaded \(selectedSecret.label) from Keychain."
        } catch {
            lastError = error.localizedDescription
            importStatus = "Secret lookup failed."
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
            importStatus = "Secret save failed."
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
            importStatus = "Secret save failed."
        }
    }

    func deleteSelectedSecret(storagePath: String) {
        guard let selectedSecret else { return }
        do {
            try RoachNetKeychainSecretStore.deleteSecret(id: selectedSecret.id, installPath: installPath)
            let filtered = RoachNetSecretsCatalogStore.load(storagePath: storagePath).filter { $0.id != selectedSecret.id }
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
            importStatus = "Secret delete failed."
        }
    }

    func requestAssistant(using workspaceModel: WorkspaceModel) async {
        guard !aiIsRunning else { return }
        let prompt = aiPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }

        let memoryMatches = roachBrainSuggestedMatches
        let memoryContextBlock = RoachBrainStore.contextBlock(for: memoryMatches)

        let fileContext = activeDocument.map { document in
            """
            Current file: \(document.relativePath)

            ```text
            \(document.text.prefix(12000))
            ```
            """
        } ?? "No file is open right now."

        let composedPrompt = """
        You are assisting inside RoachNet Dev Studio.

        \(memoryContextBlock.isEmpty ? "" : """
        \(memoryContextBlock)

        Use the RoachBrain notes only if they help this request stay concrete.
        """)

        \(fileContext)

        Request:
        \(prompt)

        Keep the answer concrete and implementation-ready.
        """

        aiIsRunning = true
        aiResponse = ""
        importStatus = "Requesting RoachClaw coding assist."
        lastError = nil

        do {
            aiResponse = try await workspaceModel.requestDeveloperAssist(prompt: composedPrompt)
            try? RoachBrainStore.markAccessed(memoryIDs: memoryMatches.map(\.id), storagePath: storagePath)
            rememberAssistantExchange(prompt: prompt, response: aiResponse)
            importStatus = memoryMatches.isEmpty
                ? "RoachClaw returned a coding response."
                : "RoachClaw returned a coding response with RoachBrain context."
        } catch {
            aiResponse = ""
            lastError = error.localizedDescription
            importStatus = "RoachClaw coding assist failed."
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
            importStatus = "Saved this assist pass into RoachBrain."
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            importStatus = "RoachBrain save failed."
        }
    }

    func insertInlineSuggestion(_ suggestion: DeveloperInlineSuggestion) {
        guard let activeDocumentID, let index = openDocuments.firstIndex(where: { $0.id == activeDocumentID }) else {
            lastError = "Open a file before inserting an inline suggestion."
            importStatus = "Inline suggestion skipped."
            return
        }

        let existing = openDocuments[index].text
        let separator = existing.hasSuffix("\n") ? "\n" : "\n\n"
        openDocuments[index].text += separator + suggestion.snippet.trimmingCharacters(in: .newlines) + "\n"
        openDocuments[index].isDirty = true
        importStatus = "Inserted \(suggestion.title.lowercased()) into \(openDocuments[index].relativePath)."
        lastError = nil
    }

    func insertAssistantResponseIntoActiveDocument() {
        guard !aiResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let activeDocumentID, let index = openDocuments.firstIndex(where: { $0.id == activeDocumentID }) else {
            lastError = "Open a file before inserting the RoachClaw response."
            importStatus = "Assistant insert skipped."
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
        activeDocument?.url.deletingLastPathComponent().path ?? projectsRootPath
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

    private func appendTerminalOutput(_ chunk: String) {
        let combined = terminalOutput + chunk
        terminalOutput = String(combined.suffix(40_000))
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
                print("RoachNet Dev Studio is live.")
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
        let collapsed = value
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

    private var summaryColumns: [GridItem] {
        [
            GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 12, alignment: .top),
        ]
    }

    private var roachClawStatusText: String {
        guard let roachClaw = model.snapshot?.roachClaw else { return "Checking lane" }
        if roachClaw.ready == true { return "Contained lane ready" }
        if roachClaw.ollama.available { return "Contained lane staging" }
        return "Contained lane offline"
    }

    private var cloudLaneText: String {
        let providers = model.snapshot?.providers.providers ?? [:]
        let availableProviders = providers
            .filter { $0.value.available }
            .map(\.key)
            .sorted()

        guard !availableProviders.isEmpty else { return "No cloud lane" }
        return availableProviders.joined(separator: ", ")
    }

    private var exoStatusText: String {
        model.config.distributedInferenceBackend == "exo"
            ? (model.config.exoModelId.isEmpty ? "Exo enabled" : "Exo · \(model.config.exoModelId)")
            : "Exo optional"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            RoachSpotlightPanel(accent: RoachPalette.cyan) {
                VStack(alignment: .leading, spacing: 18) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 18) {
                            HStack(alignment: .top, spacing: 16) {
                                RoachModuleMark(
                                    systemName: WorkspacePane.dev.icon,
                                    size: 56,
                                    isSelected: true,
                                    glow: true
                                )

                                RoachSectionHeader(
                                    "Dev Studio",
                                    title: "Code without leaving the stack.",
                                    detail: "Projects, shell, secrets, and RoachClaw stay in one native dev surface."
                                )
                            }

                            Spacer(minLength: 16)

                            HStack(spacing: 12) {
                                Button("New Project") {
                                    devModel.createProject()
                                }
                                .buttonStyle(RoachPrimaryButtonStyle())

                                Button("Import") {
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

                        VStack(alignment: .leading, spacing: 14) {
                            HStack(alignment: .top, spacing: 16) {
                                RoachModuleMark(
                                    systemName: WorkspacePane.dev.icon,
                                    size: 52,
                                    isSelected: true,
                                    glow: true
                                )

                                RoachSectionHeader(
                                    "Dev Studio",
                                    title: "Code without leaving the stack.",
                                    detail: "Projects, shell, secrets, and RoachClaw stay in one native dev surface."
                                )
                            }

                            HStack(spacing: 12) {
                                Button("New Project") {
                                    devModel.createProject()
                                }
                                .buttonStyle(RoachPrimaryButtonStyle())

                                Button("Import") {
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

                    LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 14) {
                        RoachFeatureTile(
                            "Project",
                            title: devModel.currentProjectName,
                            detail: devModel.activeDocumentLabel,
                            systemName: "shippingbox.fill",
                            accent: RoachPalette.green
                        )
                        RoachFeatureTile(
                            "Assist",
                            title: model.selectedChatModelLabel,
                            detail: roachClawStatusText,
                            systemName: "sparkles",
                            accent: RoachPalette.magenta
                        )
                        RoachFeatureTile(
                            "Secrets",
                            title: "\(devModel.secretRecords.count) stored",
                            detail: "Keychain-backed values stay outside the workspace files.",
                            systemName: "key.fill",
                            accent: RoachPalette.cyan
                        )
                        RoachFeatureTile(
                            "RoachBrain",
                            title: "\(devModel.roachBrainMemories.count) memories",
                            detail: devModel.roachBrainPinnedCount > 0
                                ? "\(devModel.roachBrainPinnedCount) pinned for quick retrieval."
                                : "Recent coding context stays searchable locally.",
                            systemName: "brain.head.profile",
                            accent: RoachPalette.bronze
                        )
                    }

                    Text(model.recommendedLocalModelSummary)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            RoachTag("Local-first", accent: RoachPalette.green)
                            RoachTag("RoachBrain memory", accent: RoachPalette.magenta)
                            RoachTag("Keychain-backed secrets", accent: RoachPalette.cyan)
                            RoachTag("Contained runtime", accent: RoachPalette.bronze)
                            RoachTag(cloudLaneText, accent: cloudLaneText == "No cloud lane" ? RoachPalette.muted : RoachPalette.cyan)
                        }
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            Button("New File") {
                                devModel.createFile()
                            }
                            .buttonStyle(RoachSecondaryButtonStyle())

                            Button("New Folder") {
                                devModel.createFolder()
                            }
                            .buttonStyle(RoachSecondaryButtonStyle())

                            Button("New Scratch") {
                                devModel.createScratchFile()
                            }
                            .buttonStyle(RoachSecondaryButtonStyle())
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Button("New File") {
                                devModel.createFile()
                            }
                            .buttonStyle(RoachSecondaryButtonStyle())

                            Button("New Folder") {
                                devModel.createFolder()
                            }
                            .buttonStyle(RoachSecondaryButtonStyle())

                            Button("New Scratch") {
                                devModel.createScratchFile()
                            }
                            .buttonStyle(RoachSecondaryButtonStyle())
                        }
                    }
                }
            }

            if let lastError = devModel.lastError {
                RoachNotice(title: "Developer workspace notice", detail: lastError)
            } else {
                RoachNotice(title: "Dev Studio", detail: devModel.importStatus)
            }

            HStack(alignment: .top, spacing: 16) {
                fileExplorerColumn
                    .frame(width: 260)

                editorColumn
                    .frame(maxWidth: .infinity)

                sideRail
                    .frame(width: 340)
            }

            terminalColumn
        }
        .task(id: model.storagePath) {
            devModel.configure(storagePath: model.storagePath, installPath: model.installPath)
        }
        .onDisappear {
            devModel.stopTerminalCommand()
        }
    }

    private var fileExplorerColumn: some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Project Files")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(RoachPalette.text)
                    Spacer()
                    RoachTag(devModel.currentProjectName, accent: RoachPalette.bronze)
                    Text("\(devModel.filteredFileTree.count)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(RoachPalette.muted)
                }

                TextField("Filter files or folders", text: $devModel.fileSearchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(RoachPalette.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(RoachPalette.panelRaised.opacity(0.64))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(RoachPalette.border, lineWidth: 1)
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
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(node.id == devModel.activeDocumentID ? RoachPalette.green : RoachPalette.text)
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .frame(minHeight: 360)
            }
        }
    }

    private var editorColumn: some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Code")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(RoachPalette.text)
                        Text(devModel.activeDocumentLabel)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(RoachPalette.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    if let active = devModel.activeDocument {
                        RoachTag(active.isDirty ? "Unsaved" : "Saved", accent: active.isDirty ? RoachPalette.warning : RoachPalette.green)
                    }

                    RoachTag(devModel.activeDocumentLanguage, accent: RoachPalette.cyan)
                    RoachTag("\(devModel.activeDocumentLineCount) lines", accent: RoachPalette.green)
                    RoachTag("\(devModel.activeDocumentCharacterCount) chars", accent: RoachPalette.magenta)

                    Button("Save") {
                        devModel.saveActiveDocument()
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())
                }

                if devModel.openDocuments.isEmpty {
                    Text("Import a project or create a scratch file to open the first editor tab. The editor stays on the code instead of drowning you in chrome.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                        .frame(maxWidth: .infinity, minHeight: 320, alignment: .topLeading)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(devModel.openDocuments) { document in
                                documentTabChip(for: document)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Editing in \(devModel.currentWorkingDirectory())")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(RoachPalette.muted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text("Monospaced editor")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(RoachPalette.green)
                        }

                        if !devModel.inlineSuggestions.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Inline Suggestions")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .tracking(1.1)
                                    .foregroundStyle(RoachPalette.muted)

                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(devModel.inlineSuggestions) { suggestion in
                                            Button {
                                                devModel.insertInlineSuggestion(suggestion)
                                            } label: {
                                                VStack(alignment: .leading, spacing: 4) {
                                                    Text(suggestion.title)
                                                        .font(.system(size: 12, weight: .semibold))
                                                        .foregroundStyle(RoachPalette.text)
                                                    Text(suggestion.detail)
                                                        .font(.system(size: 10, weight: .medium))
                                                        .foregroundStyle(RoachPalette.muted)
                                                        .multilineTextAlignment(.leading)
                                                }
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 10)
                                                .frame(width: 190, alignment: .leading)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                                        .fill(RoachPalette.panelRaised.opacity(0.56))
                                                )
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                                        .stroke(RoachPalette.border, lineWidth: 1)
                                                )
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                            }
                        }

                        TextEditor(text: Binding(
                            get: { devModel.activeDocument?.text ?? "" },
                            set: { devModel.updateActiveDocumentText($0) }
                        ))
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(RoachPalette.text)
                        .scrollContentBackground(.hidden)
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color.black.opacity(0.28),
                                            Color.black.opacity(0.22),
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(RoachPalette.borderStrong, lineWidth: 1)
                        )
                        .frame(minHeight: 420)
                    }
                }
            }
        }
    }

    private var sideRail: some View {
        VStack(alignment: .leading, spacing: 16) {
            RoachSpotlightPanel(accent: RoachPalette.magenta) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("RoachClaw Assist")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(RoachPalette.text)
                        Spacer()
                        RoachTag(model.selectedChatModelLabel, accent: RoachPalette.green)
                    }

                    HStack(spacing: 8) {
                        RoachTag(roachClawStatusText, accent: model.snapshot?.roachClaw.ready == true ? RoachPalette.green : RoachPalette.warning)
                        RoachTag(cloudLaneText, accent: cloudLaneText == "No cloud lane" ? RoachPalette.muted : RoachPalette.cyan)
                        RoachTag(exoStatusText, accent: model.config.distributedInferenceBackend == "exo" ? RoachPalette.magenta : RoachPalette.muted)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Prompt")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .tracking(1.1)
                            .foregroundStyle(RoachPalette.muted)

                        TextEditor(text: $devModel.aiPrompt)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(RoachPalette.text)
                            .scrollContentBackground(.hidden)
                            .padding(12)
                            .frame(minHeight: 120)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: [Color.black.opacity(0.26), Color.black.opacity(0.20)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(RoachPalette.borderStrong, lineWidth: 1)
                            )
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(devModel.assistantPromptPresets, id: \.self) { preset in
                                Button(preset) {
                                    devModel.aiPrompt = preset
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
                                        .stroke(RoachPalette.border, lineWidth: 1)
                                )
                                .foregroundStyle(RoachPalette.text)
                                .font(.system(size: 11, weight: .semibold))
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("RoachBrain")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .tracking(1.1)
                                .foregroundStyle(RoachPalette.muted)
                            Spacer()
                            Text(devModel.roachBrainStatus)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(RoachPalette.muted)
                        }

                        TextField("Search local memory", text: $devModel.roachBrainQuery)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(RoachPalette.text)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(RoachPalette.panelRaised.opacity(0.64))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(RoachPalette.border, lineWidth: 1)
                            )

                        if devModel.roachBrainVisibleMatches.isEmpty {
                            Text("Saved memory appears here after the first assist pass or manual save.")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(RoachPalette.muted)
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(devModel.roachBrainVisibleMatches.prefix(3)) { match in
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            Text(match.memory.title)
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundStyle(RoachPalette.text)
                                                .lineLimit(1)
                                            Spacer()
                                            if match.memory.pinned {
                                                RoachTag("Pinned", accent: RoachPalette.magenta)
                                            }
                                        }

                                        Text(match.memory.summary)
                                            .font(.system(size: 11, weight: .medium))
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
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .fill(Color.black.opacity(0.18))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .stroke(RoachPalette.border, lineWidth: 1)
                                    )
                                }
                            }
                        }
                    }

                    HStack(spacing: 10) {
                        Button("Model Store") {
                            Task {
                                await model.openRoute("/settings/models", title: "Model Store")
                            }
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())

                        Button("AI Settings") {
                            Task {
                                await model.openRoute("/settings/ai", title: "AI Settings")
                            }
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())

                        Button("Save to RoachBrain") {
                            devModel.saveAssistantResponseToRoachBrain()
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())
                        .disabled(devModel.aiResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    Button(devModel.aiIsRunning ? "Thinking…" : "Ask RoachClaw") {
                        Task {
                            await devModel.requestAssistant(using: model)
                        }
                    }
                    .buttonStyle(RoachPrimaryButtonStyle())
                    .disabled(devModel.aiIsRunning)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Response")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .tracking(1.1)
                            .foregroundStyle(RoachPalette.muted)

                        ScrollView(showsIndicators: false) {
                            Text(devModel.aiResponse.isEmpty ? "Assistant output will appear here." : devModel.aiResponse)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(devModel.aiResponse.isEmpty ? RoachPalette.muted : RoachPalette.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(minHeight: 170)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.black.opacity(0.18))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(RoachPalette.border, lineWidth: 1)
                        )
                    }

                    if !devModel.aiResponse.isEmpty {
                        HStack(spacing: 10) {
                            Button("Copy Response") {
                                devModel.copyAssistantResponse()
                            }
                            .buttonStyle(RoachSecondaryButtonStyle())

                            Button("Insert in File") {
                                devModel.insertAssistantResponseIntoActiveDocument()
                            }
                            .buttonStyle(RoachSecondaryButtonStyle())
                            .disabled(devModel.activeDocument == nil)
                        }
                    }
                }
            }

            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Secrets")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(RoachPalette.text)
                        Spacer()
                        Text("\(devModel.secretRecords.count)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
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
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(RoachPalette.panel.opacity(0.9))
                                    )
                                    .overlay(
                                        Capsule(style: .continuous)
                                            .stroke(RoachPalette.border, lineWidth: 1)
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
                                        .stroke(RoachPalette.border, lineWidth: 1)
                                )
                                .foregroundStyle(RoachPalette.text)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            }
                        }
                    }

                    Text("Templates stage the label, key, and scope fields. Values stay in the RoachNet Keychain lane until you reveal or rotate them.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)

                    if !devModel.secretRecords.isEmpty {
                        Picker("Secret", selection: Binding(
                            get: { devModel.selectedSecretID ?? "" },
                            set: { newValue in
                                devModel.selectSecret(devModel.secretRecords.first(where: { $0.id == newValue }))
                            }
                        )) {
                            Text("New Secret").tag("")
                            ForEach(devModel.secretRecords) { record in
                                Text(record.label).tag(record.id)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    RoachInlineField(title: "Label", value: $devModel.secretLabelDraft, placeholder: "GitHub Token")
                    RoachInlineField(title: "Key", value: $devModel.secretKeyDraft, placeholder: "GITHUB_TOKEN")
                    RoachInlineField(title: "Scope", value: $devModel.secretScopeDraft, placeholder: "Dev tools")
                    RoachInlineField(title: "Notes", value: $devModel.secretNotesDraft, placeholder: "Used for release workflows and repo automation")

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Value")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .tracking(1.1)
                            .foregroundStyle(RoachPalette.muted)

                        SecureField("Secret value", text: $devModel.secretValueDraft)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(RoachPalette.text)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: [RoachPalette.panelRaised.opacity(0.72), RoachPalette.panel.opacity(0.62)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(RoachPalette.borderStrong, lineWidth: 1)
                            )
                    }

                    if !devModel.revealedSecretValue.isEmpty {
                        Text("Revealed value: \(devModel.revealedSecretValue)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(RoachPalette.green)
                    }

                    HStack(spacing: 10) {
                        Button("Reveal") {
                            devModel.revealSelectedSecret()
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())
                        .disabled(devModel.selectedSecret == nil)

                        Button("Save Secret") {
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
                        .font(.system(size: 7, weight: .bold))
                    Text(document.relativePath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
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
                        .stroke(isActive ? RoachPalette.green.opacity(0.26) : RoachPalette.border, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            Button {
                devModel.closeDocument(id: document.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(RoachPalette.muted)
                    .frame(width: 18, height: 18)
                    .background(
                        Circle()
                            .fill(Color.black.opacity(0.22))
                    )
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
            .padding(.trailing, 5)
        }
    }

    private var terminalColumn: some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Terminal")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(RoachPalette.text)
                        Text(devModel.currentWorkingDirectory())
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(RoachPalette.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Text(devModel.terminalStatus)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(devModel.terminalIsRunning ? RoachPalette.green : RoachPalette.muted)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(devModel.terminalPresets, id: \.self) { preset in
                            Button(preset) {
                                devModel.terminalCommand = preset
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
                                    .stroke(RoachPalette.border, lineWidth: 1)
                            )
                            .foregroundStyle(RoachPalette.text)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        }
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(devModel.contextualTerminalCommands, id: \.self) { command in
                            Button(command) {
                                devModel.terminalCommand = command
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(RoachPalette.panelSoft.opacity(0.56))
                            )
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(RoachPalette.borderStrong, lineWidth: 1)
                            )
                            .foregroundStyle(RoachPalette.green)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        }
                    }
                }

                HStack(spacing: 12) {
                    TextField("npm test", text: $devModel.terminalCommand)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(RoachPalette.text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(RoachPalette.panelRaised.opacity(0.64))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(RoachPalette.border, lineWidth: 1)
                        )

                    Button(devModel.terminalIsRunning ? "Running…" : "Run") {
                        devModel.runTerminalCommand()
                    }
                    .buttonStyle(RoachPrimaryButtonStyle())
                    .disabled(devModel.terminalIsRunning)

                    Button("Stop") {
                        devModel.stopTerminalCommand()
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())
                    .disabled(!devModel.terminalIsRunning)

                    Button("Clear") {
                        devModel.clearTerminalOutput()
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())

                    Button("Copy") {
                        devModel.copyTerminalOutput()
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())
                    .disabled(devModel.terminalOutput.isEmpty)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Output")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(1.1)
                        .foregroundStyle(RoachPalette.muted)

                    VStack(spacing: 0) {
                        HStack {
                            Circle()
                                .fill(RoachPalette.warning)
                                .frame(width: 10, height: 10)
                            Circle()
                                .fill(RoachPalette.bronze)
                                .frame(width: 10, height: 10)
                            Circle()
                                .fill(RoachPalette.green)
                                .frame(width: 10, height: 10)
                            Spacer()
                            Text("RoachNet Shell")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(RoachPalette.muted)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(RoachPalette.panelRaised.opacity(0.72))

                        ScrollView(showsIndicators: false) {
                            Text(devModel.terminalOutput.isEmpty ? "Shell output will stream here." : devModel.terminalOutput)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(devModel.terminalOutput.isEmpty ? RoachPalette.muted : RoachPalette.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .textSelection(.enabled)
                        }
                        .frame(minHeight: 220)
                        .background(
                            LinearGradient(
                                colors: [Color.black.opacity(0.36), Color.black.opacity(0.28)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(RoachPalette.borderStrong, lineWidth: 1)
                    )
                }
            }
        }
    }
}
