import AppKit
import AVKit
#if canImport(PDFKit)
import PDFKit
#endif
import QuickLookUI
import SwiftUI
import RoachNetDesign

struct PresentedVaultAsset: Identifiable {
    let title: String
    let subtitle: String
    let url: URL

    var id: String { url.path }
}

private extension PresentedVaultAsset {
    var previewKind: VaultPreviewKind {
        VaultPreviewKind.resolve(for: url)
    }

    var isMarkdown: Bool {
        previewKind == .markdown
    }

    var supportsTextEditing: Bool {
        previewKind == .markdown || previewKind == .text
    }

    var isDirectory: Bool {
        previewKind == .folder
    }

    var previewHeadline: String {
        previewKind.shelfLabel
    }

    var previewDetail: String {
        switch previewKind {
        case .markdown:
            return "Edit markdown in place, keep the same file readable in Obsidian, and stop bouncing out to another notes app."
        case .text:
            return "Open plain text, config, and source files inside the vault so the archive behaves like a working library instead of a dead stack of attachments."
        case .image:
            return "Open the image in a built-in lightbox and keep the file anchored to the shelf it came from."
        case .audio:
            return "Play the track in RoachNet, keep the album art and file path in view, and stay inside the library."
        case .video:
            return "Watch the clip in the built-in player instead of throwing the file out to another app."
        case .pdf, .book:
            return "Read the file in the built-in reader so books and docs stay on the same shelf as the rest of the vault."
        case .folder:
            return "Browse the folder contents in one expanded shelf view without dropping out of RoachNet."
        case .generic:
            return "Preview books, media, markdown, and other vault files without leaving the RoachNet shell."
        }
    }

    var isInsideObsidianVault: Bool {
        var currentURL = url.deletingLastPathComponent()
        let fileManager = FileManager.default

        while currentURL.path != "/" {
            if fileManager.fileExists(atPath: currentURL.appendingPathComponent(".obsidian", isDirectory: true).path) {
                return true
            }
            currentURL.deleteLastPathComponent()
        }

        return false
    }
}

private struct NativeQuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        view.previewItem = url as NSURL
    }
}

private struct NativeImagePreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView(frame: .zero)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let imageView = NSImageView(frame: .zero)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.identifier = NSUserInterfaceItemIdentifier("vault-image-preview")

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: documentView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            imageView.widthAnchor.constraint(greaterThanOrEqualToConstant: 420),
            imageView.heightAnchor.constraint(greaterThanOrEqualToConstant: 420),
        ])

        scrollView.documentView = documentView
        updateImage(in: scrollView)
        return scrollView
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        updateImage(in: view)
    }

    private func updateImage(in scrollView: NSScrollView) {
        let imageView = scrollView.documentView?.subviews.compactMap { $0 as? NSImageView }.first
        imageView?.image = NSImage(contentsOf: url)
    }
}

private struct NativeMediaPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView(frame: .zero)
        view.player = AVPlayer(url: url)
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if (view.player?.currentItem?.asset as? AVURLAsset)?.url != url {
            view.player = AVPlayer(url: url)
        }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}

#if canImport(PDFKit)
private struct NativePDFPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView(frame: .zero)
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = false
        view.backgroundColor = .clear
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
    }
}
#endif

private struct VaultRenderedMarkdownView: View {
    let markdown: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let attributed = try? AttributedString(markdown: markdown) {
                    Text(attributed)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(markdown)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct VaultPreviewSurfaceView: View {
    let asset: PresentedVaultAsset
    let onClose: () -> Void
    let onOpenAsset: (URL) -> Void

    @State private var markdownDraft = ""
    @State private var originalMarkdown = ""
    @State private var saveStatusLine: String?
    @State private var loadErrorLine: String?
    @State private var isSavingMarkdown = false
    @State private var folderChildren: [URL] = []
    @State private var folderQuery = ""

    private var hasUnsavedTextChanges: Bool {
        asset.supportsTextEditing && markdownDraft != originalMarkdown
    }

    private var filteredFolderChildren: [URL] {
        let trimmedQuery = folderQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return folderChildren }

        return folderChildren.filter { child in
            child.lastPathComponent.localizedCaseInsensitiveContains(trimmedQuery)
                || child.path.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    private var assetExcerpt: String? {
        if asset.supportsTextEditing {
            return RoachClawContextSupport.normalizedExcerpt(markdownDraft, maxCharacters: 280)
        }
        return RoachClawContextSupport.textExcerpt(for: asset.url, maxCharacters: 280)
    }

    private var markdownWikiLinks: [String] {
        guard asset.isMarkdown else { return [] }
        return VaultPreviewAssetSupport.wikiLinks(in: markdownDraft)
    }

    private var assetFacts: [(String, Color)] {
        var facts: [(String, Color)] = []

        if let fileSize = VaultPreviewAssetSupport.fileSizeLabel(for: asset.url) {
            facts.append(("Size \(fileSize)", RoachPalette.cyan))
        }
        if let modifiedAt = VaultPreviewAssetSupport.modifiedAtLabel(for: asset.url) {
            facts.append(("Updated \(modifiedAt)", RoachPalette.bronze))
        }

        switch asset.previewKind {
        case .markdown, .text:
            facts.append(("\(VaultPreviewAssetSupport.lineCount(for: markdownDraft)) lines", RoachPalette.green))
            facts.append(("\(VaultPreviewAssetSupport.wordCount(for: markdownDraft)) words", RoachPalette.magenta))
            if asset.isMarkdown {
                facts.append(("\(markdownWikiLinks.count) wikilinks", RoachPalette.cyan))
            }
        case .folder:
            facts.append(("\(folderChildren.count) items", RoachPalette.cyan))
        case .image:
            facts.append(("Lightbox", RoachPalette.magenta))
        case .audio:
            facts.append(("Built-in player", RoachPalette.green))
        case .video:
            facts.append(("Built-in screening", RoachPalette.cyan))
        case .pdf, .book:
            facts.append(("Reader surface", RoachPalette.bronze))
        case .generic:
            facts.append(("Quick preview", RoachPalette.cyan))
        }

        return facts
    }

    var body: some View {
        GeometryReader { proxy in
            let isTight = proxy.size.width < 1120

            ZStack {
                RoachBackground()

                VStack(spacing: 16) {
                    header

                    previewBody(isTight: isTight)
                }
                .padding(20)
            }
        }
        .task(id: asset.id) {
            await prepareAsset()
        }
    }

    private var header: some View {
        RoachInsetPanel {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    headerCopy
                    Spacer(minLength: 12)
                    headerActions
                }

                VStack(alignment: .leading, spacing: 14) {
                    headerCopy
                    headerActions
                }
            }
        }
    }

    private var headerCopy: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoachSectionHeader(
                asset.previewHeadline,
                title: asset.title,
                detail: asset.previewDetail
            )

            Text(asset.subtitle)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(RoachPalette.muted)
                .lineLimit(2)
                .truncationMode(.middle)

            HStack(spacing: 8) {
                if asset.isMarkdown {
                    RoachTag("Editable note", accent: RoachPalette.magenta)
                }
                if asset.previewKind == .text {
                    RoachTag("Editable file", accent: RoachPalette.cyan)
                }
                if asset.previewKind == .image {
                    RoachTag("Lightbox", accent: RoachPalette.magenta)
                }
                if asset.previewKind == .audio {
                    RoachTag("Music player", accent: RoachPalette.green)
                }
                if asset.previewKind == .video {
                    RoachTag("Video player", accent: RoachPalette.cyan)
                }
                if asset.previewKind == .pdf || asset.previewKind == .book {
                    RoachTag("Reader", accent: RoachPalette.bronze)
                }
                if asset.isDirectory {
                    RoachTag("Expanded shelf", accent: RoachPalette.cyan)
                }
                if asset.isInsideObsidianVault {
                    RoachTag("Shared with Obsidian", accent: RoachPalette.green)
                }
                if hasUnsavedTextChanges {
                    RoachTag("Unsaved changes", accent: RoachPalette.warning)
                }
            }

            if let loadErrorLine {
                Text(loadErrorLine)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(RoachPalette.warning)
            } else if let saveStatusLine {
                Text(saveStatusLine)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(RoachPalette.muted)
            }
        }
    }

    private var headerActions: some View {
        HStack(spacing: 12) {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([asset.url])
            }
            .buttonStyle(RoachSecondaryButtonStyle())

            Button("Open Externally") {
                NSWorkspace.shared.open(asset.url)
            }
            .buttonStyle(RoachSecondaryButtonStyle())

            if asset.supportsTextEditing {
                Button(isSavingMarkdown ? "Saving..." : (asset.isMarkdown ? "Save Note" : "Save File")) {
                    Task { await saveEditableText() }
                }
                .buttonStyle(RoachPrimaryButtonStyle())
                .disabled(isSavingMarkdown || !hasUnsavedTextChanges)
            }

            Button("Close") {
                onClose()
            }
            .buttonStyle(RoachSecondaryButtonStyle())
        }
    }

    @ViewBuilder
    private func previewBody(isTight: Bool) -> some View {
        switch asset.previewKind {
        case .markdown:
            markdownWorkspace(isTight: isTight)
        case .text:
            textWorkspace(isTight: isTight)
        case .image:
            imageWorkspace
        case .audio, .video:
            mediaWorkspace
        case .pdf:
            pdfWorkspace
        case .book:
            quickLookWorkspace
        case .folder:
            folderWorkspace
        case .generic:
            quickLookWorkspace
        }
    }

    @ViewBuilder
    private func markdownWorkspace(isTight: Bool) -> some View {
        if isTight {
            VStack(spacing: 16) {
                markdownEditorPanel
                markdownPreviewPanel
                assetInsightsPanel
            }
        } else {
            HStack(alignment: .top, spacing: 16) {
                markdownEditorPanel
                    .frame(maxWidth: .infinity)
                VStack(spacing: 16) {
                    markdownPreviewPanel
                    assetInsightsPanel
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private func textWorkspace(isTight: Bool) -> some View {
        if isTight {
            VStack(spacing: 16) {
                textEditorPanel
                textSnapshotPanel
                assetInsightsPanel
            }
        } else {
            HStack(alignment: .top, spacing: 16) {
                textEditorPanel
                    .frame(maxWidth: .infinity)
                VStack(spacing: 16) {
                    textSnapshotPanel
                    assetInsightsPanel
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var imageWorkspace: some View {
        VStack(spacing: 16) {
            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 12) {
                    RoachSectionHeader(
                        "Lightbox",
                        title: "Open the visual without leaving Vault.",
                        detail: "Artwork, scans, covers, and exported frames stay attached to the same library surface instead of bouncing out to Preview."
                    )

                    NativeImagePreview(url: asset.url)
                        .frame(minHeight: 520)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(RoachPalette.border, lineWidth: 1)
                        )
                }
            }

            assetInsightsPanel
        }
    }

    private var mediaWorkspace: some View {
        VStack(spacing: 16) {
            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 12) {
                    RoachSectionHeader(
                        asset.previewKind == .audio ? "Player" : "Viewer",
                        title: asset.previewKind == .audio ? "Built-in listening lane." : "Built-in screening lane.",
                        detail: asset.previewKind == .audio
                            ? "Play the file here and keep the rest of the vault shelf within reach."
                            : "Watch the file here instead of jumping out to another player."
                    )

                    NativeMediaPreview(url: asset.url)
                        .frame(minHeight: 460)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(RoachPalette.border, lineWidth: 1)
                        )
                }
            }

            assetInsightsPanel
        }
    }

    private var quickLookWorkspace: some View {
        VStack(spacing: 16) {
            RoachInsetPanel {
                NativeQuickLookPreview(url: asset.url)
                    .frame(minHeight: 560)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }

            assetInsightsPanel
        }
    }

    private var pdfWorkspace: some View {
        VStack(spacing: 16) {
            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 12) {
                    RoachSectionHeader(
                        "Reader",
                        title: "Read without leaving the shelf.",
                        detail: "PDFs stay inside the vault reader instead of bouncing over to Preview."
                    )

                    #if canImport(PDFKit)
                    NativePDFPreview(url: asset.url)
                        .frame(minHeight: 560)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(RoachPalette.border, lineWidth: 1)
                        )
                    #else
                    NativeQuickLookPreview(url: asset.url)
                        .frame(minHeight: 560)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    #endif
                }
            }

            assetInsightsPanel
        }
    }

    private var folderWorkspace: some View {
        VStack(spacing: 16) {
            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 12) {
                    RoachSectionHeader(
                        "Expanded Shelf",
                        title: "Browse the folder without leaving Vault.",
                        detail: folderChildren.isEmpty
                            ? "This folder is empty."
                            : "Open nested files and subfolders directly inside the vault so the archive behaves like a working library, not a dead Finder handoff."
                    )

                    TextField("Filter this folder", text: $folderQuery)
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

                    if filteredFolderChildren.isEmpty {
                        Text(folderChildren.isEmpty ? "No files were found in this folder." : "No folder items matched that filter.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(RoachPalette.muted)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(filteredFolderChildren, id: \.path) { child in
                                    let kind = VaultPreviewKind.resolve(for: child)
                                    Button {
                                        onOpenAsset(child)
                                    } label: {
                                        HStack(alignment: .top, spacing: 12) {
                                            Image(systemName: shelfIcon(for: kind, isDirectory: child.hasDirectoryPath))
                                                .font(.system(size: 16, weight: .semibold))
                                                .foregroundStyle(shelfAccent(for: kind))
                                                .frame(width: 18)

                                            VStack(alignment: .leading, spacing: 4) {
                                                HStack(spacing: 8) {
                                                    Text(child.lastPathComponent)
                                                        .font(.system(size: 13, weight: .semibold))
                                                        .foregroundStyle(RoachPalette.text)
                                                        .lineLimit(1)
                                                    RoachTag(kind.shelfLabel, accent: shelfAccent(for: kind))
                                                }

                                                Text(child.path)
                                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                                    .foregroundStyle(RoachPalette.muted)
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                            }

                                            Spacer(minLength: 8)

                                            Text("Open in Vault")
                                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                                .tracking(0.9)
                                                .foregroundStyle(shelfAccent(for: kind))
                                        }
                                        .padding(12)
                                        .background(
                                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                                .fill(RoachPalette.panelRaised.opacity(0.72))
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
                        .frame(minHeight: 420)
                    }
                }
            }

            assetInsightsPanel
        }
    }

    private var markdownEditorPanel: some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 12) {
                RoachSectionHeader(
                    "Markdown",
                    title: "Write in the same file.",
                    detail: "This note stays on disk where Obsidian expects it. RoachNet edits the markdown directly instead of keeping a second copy."
                )

                TextEditor(text: $markdownDraft)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(RoachPalette.text)
                    .scrollContentBackground(.hidden)
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(RoachPalette.panelRaised.opacity(0.92))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(RoachPalette.border, lineWidth: 1)
                            )
                    )
                    .frame(minHeight: 460)
            }
        }
    }

    private var textEditorPanel: some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 12) {
                RoachSectionHeader(
                    "Text File",
                    title: "Edit the source in place.",
                    detail: "Plain text, config, and code files stay on the same shelf and can be adjusted without bouncing out to another editor."
                )

                TextEditor(text: $markdownDraft)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(RoachPalette.text)
                    .scrollContentBackground(.hidden)
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(RoachPalette.panelRaised.opacity(0.92))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(RoachPalette.border, lineWidth: 1)
                            )
                    )
                    .frame(minHeight: 460)
            }
        }
    }

    private var markdownPreviewPanel: some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 12) {
                RoachSectionHeader(
                    "Rendered",
                    title: "See the note like a reader.",
                    detail: "Quickly check headings, links, lists, and note flow without leaving the editor lane."
                )

                VaultRenderedMarkdownView(markdown: markdownDraft)
                    .frame(minHeight: 460)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(RoachPalette.panelRaised.opacity(0.76))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(RoachPalette.border, lineWidth: 1)
                            )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
    }

    private var textSnapshotPanel: some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 12) {
                RoachSectionHeader(
                    "Snapshot",
                    title: "Read the file without leaving the lane.",
                    detail: "Keep a plain-text reader next to the editor so config files, logs, and code snippets still feel like part of the same archive."
                )

                ScrollView {
                    Text(markdownDraft.isEmpty ? "No text loaded yet." : markdownDraft)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(markdownDraft.isEmpty ? RoachPalette.muted : RoachPalette.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(18)
                }
                .frame(minHeight: 300)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(RoachPalette.panelRaised.opacity(0.76))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(RoachPalette.border, lineWidth: 1)
                        )
                )
            }
        }
    }

    private var assetInsightsPanel: some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 14) {
                RoachSectionHeader(
                    "Shelf Notes",
                    title: "Keep the file context attached.",
                    detail: "File stats, excerpts, and markdown cues stay inside the preview so Vault feels like an actual library lane instead of a stack of dead launchers."
                )

                if !assetFacts.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(assetFacts.enumerated()), id: \.offset) { item in
                                RoachTag(item.element.0, accent: item.element.1)
                            }
                        }
                    }
                }

                if let assetExcerpt, !assetExcerpt.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Excerpt")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .tracking(1.1)
                            .foregroundStyle(RoachPalette.muted)

                        Text(assetExcerpt)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(RoachPalette.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !markdownWikiLinks.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Obsidian Links")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .tracking(1.1)
                            .foregroundStyle(RoachPalette.muted)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(markdownWikiLinks.prefix(8), id: \.self) { link in
                                    RoachTag(link, accent: RoachPalette.magenta)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func loadEditableText() async {
        do {
            let text = try VaultPreviewAssetSupport.loadText(from: asset.url)
            markdownDraft = text
            originalMarkdown = text
            loadErrorLine = nil
            saveStatusLine = asset.isMarkdown && asset.isInsideObsidianVault
                ? "Live note link is open. RoachNet and Obsidian are reading the same file."
                : (asset.isMarkdown ? "Markdown note loaded from the vault." : "Text file loaded from the vault.")
        } catch {
            loadErrorLine = error.localizedDescription
            saveStatusLine = nil
        }
    }

    private func saveEditableText() async {
        guard asset.supportsTextEditing else { return }

        isSavingMarkdown = true
        defer { isSavingMarkdown = false }

        do {
            try markdownDraft.write(to: asset.url, atomically: true, encoding: .utf8)
            originalMarkdown = markdownDraft
            loadErrorLine = nil
            saveStatusLine = asset.isMarkdown && asset.isInsideObsidianVault
                ? "Saved the note back into the shared Obsidian vault."
                : (asset.isMarkdown ? "Saved the note back into the RoachNet vault." : "Saved the file back into the RoachNet vault.")
        } catch {
            loadErrorLine = error.localizedDescription
            saveStatusLine = nil
        }
    }

    private func prepareAsset() async {
        switch asset.previewKind {
        case .markdown, .text:
            await loadEditableText()
        case .folder:
            await loadFolderContents()
        default:
            break
        }
    }

    private func loadFolderContents() async {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: asset.url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        folderChildren = contents
            .sorted { lhs, rhs in
                if lhs.hasDirectoryPath != rhs.hasDirectoryPath {
                    return lhs.hasDirectoryPath && !rhs.hasDirectoryPath
                }
                return lhs.lastPathComponent.localizedCaseInsensitiveCompare(rhs.lastPathComponent) == .orderedAscending
            }
            .prefix(24)
            .map { $0 }
    }

    private func shelfAccent(for kind: VaultPreviewKind) -> Color {
        switch kind {
        case .markdown:
            return RoachPalette.magenta
        case .text:
            return RoachPalette.cyan
        case .image:
            return RoachPalette.magenta
        case .audio:
            return RoachPalette.green
        case .video:
            return RoachPalette.cyan
        case .pdf, .book:
            return RoachPalette.bronze
        case .folder:
            return RoachPalette.cyan
        case .generic:
            return RoachPalette.green
        }
    }

    private func shelfIcon(for kind: VaultPreviewKind, isDirectory: Bool) -> String {
        if isDirectory {
            return "folder.fill"
        }

        switch kind {
        case .markdown:
            return "note.text"
        case .text:
            return "doc.plaintext"
        case .image:
            return "photo"
        case .audio:
            return "waveform"
        case .video:
            return "film.fill"
        case .pdf:
            return "doc.richtext.fill"
        case .book:
            return "books.vertical.fill"
        case .folder:
            return "folder.fill"
        case .generic:
            return "doc.fill"
        }
    }
}
