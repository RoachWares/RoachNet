import XCTest
@testable import RoachNetApp

final class DevWorkspaceSupportTests: XCTestCase {
    func testTerminalTranscriptParsesPromptMetadataAndKeepsVisiblePrompt() {
        let chunk = "__RN_PROMPT__/Users/example/RoachNet__STATUS__0__\nroachnet % "

        let parsed = DeveloperTerminalTranscript.consume(chunk)

        XCTAssertEqual(parsed.prompt?.workingDirectory, "/Users/example/RoachNet")
        XCTAssertEqual(parsed.prompt?.exitCode, 0)
        XCTAssertEqual(parsed.visibleText, "roachnet % ")
    }

    func testTerminalTranscriptStripsAnsiSequencesFromVisibleText() {
        let chunk = "\u{001B}[32mready\u{001B}[0m\r\nnext"

        let parsed = DeveloperTerminalTranscript.consume(chunk)

        XCTAssertEqual(parsed.visibleText, "ready\nnext")
        XCTAssertNil(parsed.prompt)
    }

    func testTerminalBootstrapLineKeepsPromptDirectoryVariableSeparated() {
        XCTAssertEqual(
            DeveloperTerminalSession.promptBootstrapLine,
            #"precmd() { print -r -- "__RN_PROMPT__${PWD}__STATUS__$?__"; }"#
        )
    }

    func testInlineAssistCleanerPrefersCodeFenceContents() {
        let raw = """
        Here is the next block.

        ```swift
        let output = value + 1
        return output
        ```
        """

        XCTAssertEqual(
            DeveloperInlineAssistSupport.cleanedCompletion(from: raw),
            """
            let output = value + 1
            return output
            """
        )
    }

    func testInlinePromptDirectiveParsesCommentRequestFromBufferTail() {
        let source = """
        struct Demo {
            func run() {
                print("ready")
            }
        }

        // roachclaw: add a debug logger after the print call
        """

        let directive = DeveloperInlineAssistSupport.promptDirective(in: source, fileExtension: "swift")

        XCTAssertEqual(directive?.instruction, "add a debug logger after the print call")
        XCTAssertEqual(directive?.rawLine, "// roachclaw: add a debug logger after the print call")
    }

    func testIntegratingAcceptedCompletionReplacesInlinePromptDirective() {
        let source = """
        func install() {
            prepare()
            // roachclaw: write the success log line next
        }
        """

        let updated = DeveloperInlineAssistSupport.integratingAcceptedCompletion(
            """
            logger.info("install ready")
            """,
            into: source,
            fileExtension: "swift"
        )

        XCTAssertEqual(
            updated,
            """
            func install() {
                prepare()
                logger.info("install ready")
            }
            """
        )
    }

    func testInlineAssistFailureSuppressesRawWarmupErrorsWhenNoModelIsReady() {
        let presentation = DeveloperInlineAssistSupport.failurePresentation(
            description: "POST /api/ollama/chat failed with status 500.",
            roachClawReady: false,
            hasCloudFallback: false,
            automatic: true
        )

        XCTAssertEqual(
            presentation.status,
            "RoachClaw needs a live model before inline assist can stage the next lines."
        )
        XCTAssertNil(presentation.surfacedError)
    }

    func testInlineAssistFailureKeepsUnderlyingErrorWhenRoachClawWasAlreadyReady() {
        let presentation = DeveloperInlineAssistSupport.failurePresentation(
            description: "POST /api/ollama/chat failed with status 500.",
            roachClawReady: true,
            hasCloudFallback: false,
            automatic: true
        )

        XCTAssertEqual(presentation.status, "Inline assist could not finish this pass.")
        XCTAssertEqual(presentation.surfacedError, "POST /api/ollama/chat failed with status 500.")
    }

    func testInlineAssistFailureSuppressesCancelledErrors() {
        let presentation = DeveloperInlineAssistSupport.failurePresentation(
            description: "The operation was cancelled.",
            roachClawReady: true,
            hasCloudFallback: false,
            automatic: true
        )

        XCTAssertEqual(
            presentation.status,
            "Inline assist standing by."
        )
        XCTAssertNil(presentation.surfacedError)
    }

    func testWorkspacePathLabelRedactsMachineSpecificInstallName() {
        XCTAssertEqual(
            DeveloperWorkspacePathLabel.displayName(
                title: "Install",
                path: "/Users/example/RoachNet.regressioncheck"
            ),
            "Contained app"
        )
    }

    func testWorkspacePathLabelUsesLastPathComponentForProjectFolders() {
        XCTAssertEqual(
            DeveloperWorkspacePathLabel.displayName(
                title: "Workspace",
                path: "/Volumes/Shared/DEVPROJECTS/RoachNet/projects"
            ),
            "projects"
        )
    }

    func testWorkspacePanePrefersPinnedDetailSurfaceForDevOnly() {
        XCTAssertTrue(WorkspacePane.dev.prefersPinnedDetailSurface)
        XCTAssertFalse(WorkspacePane.home.prefersPinnedDetailSurface)
    }

    func testRuntimeSurfacePathLabelRedactsInstallRoots() {
        XCTAssertEqual(
            RuntimeSurfacePathLabel.displayValue(
                "/Users/example/RoachNet.regressioncheck",
                kind: .installRoot
            ),
            "Contained app"
        )
    }

    func testRuntimeSurfacePathLabelKeepsGenericStorageName() {
        XCTAssertEqual(
            RuntimeSurfacePathLabel.displayValue(
                "/Users/example/RoachNet.regressioncheck/storage",
                kind: .storageRoot
            ),
            "storage"
        )
    }

    func testRuntimeSurfacePathLabelRedactsVaultFolderPaths() {
        XCTAssertEqual(
            RuntimeSurfacePathLabel.displayValue(
                "/Users/example/RoachNet.regressioncheck/storage/vault",
                kind: .vaultFolder
            ),
            "Contained vault"
        )
    }

    func testRuntimeSurfacePathLabelShortensLogFilePaths() {
        XCTAssertEqual(
            RuntimeSurfacePathLabel.displayValue(
                "/Users/example/RoachNet.regressioncheck/storage/logs/roachnet-server.log",
                kind: .logFile
            ),
            "roachnet-server.log"
        )
    }

    func testTerminalBootstrapNoiseFilterRemovesPromptSetupEchoes() {
        let raw = """
        Brennans-Mac-Mini% PPROMPT=$'%F{75}%n@%m%f %F{82}%~%f %# '
        %
        roach@Brennans-Mac-Mini ~/project % RRPROMPT=''
        %
        roach@Brennans-Mac-Mini ~/project %
        """

        XCTAssertEqual(
            DeveloperTerminalTranscript.stripBootstrapNoise(from: raw),
            ""
        )
    }
}
