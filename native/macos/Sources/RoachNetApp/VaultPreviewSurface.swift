import AVKit
import AppKit
import QuickLookUI
import RoachNetDesign
import SwiftUI

#if canImport(PDFKit)
import PDFKit
#endif

struct PresentedVaultAsset: Identifiable {
    let title: String
    let subtitle: String
    let url: URL

    var id: String { url.path }
}

extension PresentedVaultAsset {
    fileprivate var previewKind: VaultPreviewKind {
        VaultPreviewKind.resolve(for: url)
    }

    fileprivate var isMarkdown: Bool {
        previewKind == .markdown
    }

    fileprivate var supportsTextEditing: Bool {
        previewKind == .markdown || previewKind == .text
    }

    fileprivate var isDirectory: Bool {
        previewKind == .folder
    }

    fileprivate var previewHeadline: String {
        previewKind.shelfLabel
    }

    fileprivate var previewDetail: String {
        switch previewKind {
        case .markdown:
            return "Edit the Markdown file in place. Obsidian and other editors open the same file."
        case .text:
            return "Open plain text, config, and source files in the Vault."
        case .image:
            return "Inspect the image in a built-in lightbox."
        case .audio:
            return "Play the track without leaving the library."
        case .video:
            return "Watch the clip in the built-in player."
        case .pdf, .book:
            return "Read books and docs on the same shelf as the rest of the Vault."
        case .archive:
            return "Look inside the package without switching to Finder."
        case .folder:
            return "Browse the folder's contents without switching to Finder."
        case .generic:
            return "Preview this vault file inside RoachNet."
        }
    }

    fileprivate var isInsideObsidianVault: Bool {
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
        view.showsFullScreenToggleButton = true
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
    let scaleFactor: CGFloat

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView(frame: .zero)
        view.autoScales = true
        view.minScaleFactor = 0.55
        view.maxScaleFactor = 3.0
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = false
        view.backgroundColor = .clear
        view.document = PDFDocument(url: url)
        view.scaleFactor = scaleFactor
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
        view.scaleFactor = scaleFactor
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
    @State private var readerScale = 1.0

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

    private var speechActionPlans: [RoachSpeechVaultActionPlan] {
        RoachSpeechVaultActionPlan.plans(for: asset.previewKind, sourceURL: asset.url)
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
            facts.append(
                (
                    "\(RoachCopy.count(VaultPreviewAssetSupport.lineCount(for: markdownDraft), "line"))",
                    RoachPalette.green
                ))
            facts.append(
                (
                    "\(RoachCopy.count(VaultPreviewAssetSupport.wordCount(for: markdownDraft), "word"))",
                    RoachPalette.magenta
                ))
            if asset.isMarkdown {
                facts.append(("\(RoachCopy.count(markdownWikiLinks.count, "wikilink"))", RoachPalette.cyan))
            }
        case .folder:
            facts.append(("\(RoachCopy.count(folderChildren.count, "item"))", RoachPalette.cyan))
        case .image:
            facts.append(("Lightbox", RoachPalette.magenta))
        case .audio:
            facts.append(("Built-in player", RoachPalette.green))
        case .video:
            facts.append(("Built-in player", RoachPalette.cyan))
        case .pdf, .book:
            facts.append(("Built-in reader", RoachPalette.bronze))
        case .archive:
            facts.append(("Archive package", RoachPalette.cyan))
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
                .font(.roach(size: 12, weight: .medium, design: .monospaced))
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
                if asset.previewKind == .archive {
                    RoachTag("Archive", accent: RoachPalette.cyan)
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
                    .font(.roach(size: 12, weight: .medium))
                    .foregroundStyle(RoachPalette.warning)
            } else if let saveStatusLine {
                Text(saveStatusLine)
                    .font(.roach(size: 12, weight: .medium))
                    .foregroundStyle(RoachPalette.muted)
            }
        }
    }

    private var headerActions: some View {
        HStack(spacing: 12) {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([asset.url])
            } label: {
                Label("Reveal", systemImage: "folder")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(RoachSecondaryButtonStyle())

            Button {
                NSWorkspace.shared.open(asset.url)
            } label: {
                Label("Open", systemImage: "arrow.up.forward.app")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(RoachSecondaryButtonStyle())

            if asset.supportsTextEditing {
                Button {
                    Task { await saveEditableText() }
                } label: {
                    Label(isSavingMarkdown ? "Saving" : "Save", systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(RoachPrimaryButtonStyle())
                .disabled(isSavingMarkdown || !hasUnsavedTextChanges)
            }

            Button {
                onClose()
            } label: {
                Label("Close", systemImage: "xmark")
                    .labelStyle(.titleAndIcon)
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
            bookWorkspace
        case .archive:
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
                        title: "Visual preview.",
                        detail: "Artwork, scans, covers, and frames open here without leaving the Vault."
                    )

                    NativeImagePreview(url: asset.url)
                        .frame(minHeight: 520)
                        .clipShape(RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous)
                                .stroke(RoachPalette.border, lineWidth: RoachMetrics.line(1))
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
                        title: asset.previewKind == .audio ? "Local player." : "Local video player.",
                        detail: asset.previewKind == .audio
                            ? "It plays from your vault on this Mac, so nothing asks you to sign in."
                            : "It plays from your vault on this Mac, so you don't need a browser."
                    )

                    mediaDock

                    NativeMediaPreview(url: asset.url)
                        .frame(minHeight: 460)
                        .clipShape(RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous)
                                .stroke(RoachPalette.border, lineWidth: RoachMetrics.line(1))
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
                    .clipShape(RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous))
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
                        title: "Read inside the Vault.",
                        detail: "PDFs open here with zoom and file details. Nothing goes to a cloud reader."
                    )

                    readerDock(kind: "PDF")

                    #if canImport(PDFKit)
                    NativePDFPreview(url: asset.url, scaleFactor: CGFloat(readerScale))
                        .frame(minHeight: 560)
                        .clipShape(RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous)
                                .stroke(RoachPalette.border, lineWidth: RoachMetrics.line(1))
                        )
                    #else
                    NativeQuickLookPreview(url: asset.url)
                        .frame(minHeight: 560)
                        .clipShape(RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous))
                    #endif
                }
            }

            assetInsightsPanel
        }
    }

    private var bookWorkspace: some View {
        VStack(spacing: 16) {
            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 12) {
                    RoachSectionHeader(
                        "Reader",
                        title: "Book shelf.",
                        detail: "EPUBs and other e-book formats open in their own reader inside the Vault."
                    )

                    readerDock(
                        kind: asset.url.pathExtension.uppercased().isEmpty
                            ? "Book" : asset.url.pathExtension.uppercased())

                    NativeQuickLookPreview(url: asset.url)
                        .frame(minHeight: 560)
                        .clipShape(RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous)
                                .stroke(RoachPalette.border, lineWidth: RoachMetrics.line(1))
                        )
                }
            }

            assetInsightsPanel
        }
    }

    private var mediaDock: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                RoachTag(
                    asset.previewKind == .audio ? "Audio" : "Video",
                    accent: asset.previewKind == .audio ? RoachPalette.green : RoachPalette.cyan)
                RoachTag("Fullscreen control", accent: RoachPalette.magenta)
                if let fileSize = VaultPreviewAssetSupport.fileSizeLabel(for: asset.url) {
                    RoachTag(fileSize, accent: RoachPalette.bronze)
                }
                RoachTag(asset.url.pathExtension.uppercased(), accent: RoachPalette.cyan)
            }
        }
    }

    private func readerDock(kind: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                readerDockContent(kind: kind)
            }

            VStack(alignment: .leading, spacing: 10) {
                readerDockContent(kind: kind)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: RoachMetrics.radius(16), style: .continuous)
                .fill(RoachPalette.panelRaised.opacity(0.58))
        )
        .overlay(
            RoundedRectangle(cornerRadius: RoachMetrics.radius(16), style: .continuous)
                .stroke(RoachPalette.border, lineWidth: RoachMetrics.line(1))
        )
    }

    @ViewBuilder
    private func readerDockContent(kind: String) -> some View {
        RoachTag(kind, accent: RoachPalette.bronze)
        RoachTag("\(Int((readerScale * 100).rounded()))%", accent: RoachPalette.cyan)

        Button {
            readerScale = max(0.65, readerScale - 0.10)
        } label: {
            Label("Smaller", systemImage: "minus.magnifyingglass")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(RoachSecondaryButtonStyle())

        Button {
            readerScale = min(2.2, readerScale + 0.10)
        } label: {
            Label("Larger", systemImage: "plus.magnifyingglass")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(RoachSecondaryButtonStyle())

        Button {
            readerScale = 1.0
        } label: {
            Label("Reset", systemImage: "arrow.counterclockwise")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(RoachSecondaryButtonStyle())
    }

    private var folderWorkspace: some View {
        VStack(spacing: 16) {
            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 12) {
                    RoachSectionHeader(
                        "Expanded shelf",
                        title: "Browse this folder.",
                        detail: folderChildren.isEmpty
                            ? "This folder is empty."
                            : "Open nested files without leaving the Vault."
                    )

                    TextField("Filter this folder", text: $folderQuery)
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

                    if filteredFolderChildren.isEmpty {
                        RoachNotice(
                            title: folderChildren.isEmpty ? "Folder is empty" : "No matches",
                            detail: folderChildren.isEmpty
                                ? "There's nothing in this folder to open yet."
                                : "Change the filter.",
                            accent: RoachPalette.cyan,
                            systemName: folderChildren.isEmpty ? "folder" : "magnifyingglass"
                        )
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
                                                .font(.roach(size: 16, weight: .semibold))
                                                .foregroundStyle(shelfAccent(for: kind))
                                                .frame(width: 18)

                                            VStack(alignment: .leading, spacing: 4) {
                                                HStack(spacing: 8) {
                                                    Text(child.lastPathComponent)
                                                        .font(.roach(size: 13, weight: .semibold))
                                                        .foregroundStyle(RoachPalette.text)
                                                        .lineLimit(1)
                                                    RoachTag(kind.shelfLabel, accent: shelfAccent(for: kind))
                                                }

                                                Text(child.path)
                                                    .font(.roach(size: 11, weight: .medium, design: .monospaced))
                                                    .foregroundStyle(RoachPalette.muted)
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                            }

                                            Spacer(minLength: 8)

                                            Text("Open in Vault")
                                                .font(.roach(size: 10, weight: .bold, design: .monospaced))
                                                .tracking(0.9)
                                                .foregroundStyle(shelfAccent(for: kind))
                                        }
                                        .padding(12)
                                        .background(
                                            RoundedRectangle(cornerRadius: RoachMetrics.radius(16), style: .continuous)
                                                .fill(RoachPalette.panelRaised.opacity(0.72))
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
                    title: "Edit Markdown in place.",
                    detail: "The same file Obsidian and other editors open."
                )

                TextEditor(text: $markdownDraft)
                    .font(.roach(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(RoachPalette.text)
                    .scrollContentBackground(.hidden)
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous)
                            .fill(RoachPalette.panelRaised.opacity(0.92))
                            .overlay(
                                RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous)
                                    .stroke(RoachPalette.border, lineWidth: RoachMetrics.line(1))
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
                    "Text file",
                    title: "Edit the source in place.",
                    detail: "Plain text, config, and code stay editable here."
                )

                TextEditor(text: $markdownDraft)
                    .font(.roach(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(RoachPalette.text)
                    .scrollContentBackground(.hidden)
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous)
                            .fill(RoachPalette.panelRaised.opacity(0.92))
                            .overlay(
                                RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous)
                                    .stroke(RoachPalette.border, lineWidth: RoachMetrics.line(1))
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
                    title: "Reader view.",
                    detail: "Headings, links, lists."
                )

                VaultRenderedMarkdownView(markdown: markdownDraft)
                    .frame(minHeight: 460)
                    .background(
                        RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous)
                            .fill(RoachPalette.panelRaised.opacity(0.76))
                            .overlay(
                                RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous)
                                    .stroke(RoachPalette.border, lineWidth: RoachMetrics.line(1))
                            )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous))
            }
        }
    }

    private var textSnapshotPanel: some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 12) {
                RoachSectionHeader(
                    "Snapshot",
                    title: "Plain-text reader.",
                    detail: "Logs, configs, snippets."
                )

                ScrollView {
                    Text(markdownDraft.isEmpty ? "No text loaded yet." : markdownDraft)
                        .font(.roach(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(markdownDraft.isEmpty ? RoachPalette.muted : RoachPalette.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(18)
                }
                .frame(minHeight: 300)
                .background(
                    RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous)
                        .fill(RoachPalette.panelRaised.opacity(0.76))
                        .overlay(
                            RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous)
                                .stroke(RoachPalette.border, lineWidth: RoachMetrics.line(1))
                        )
                )
            }
        }
    }

    private var assetInsightsPanel: some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 14) {
                RoachSectionHeader(
                    "Shelf notes",
                    title: "File context.",
                    detail: "Stats and excerpts for this file."
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
                            .font(.roach(size: 11, weight: .semibold, design: .monospaced))
                            .tracking(1.1)
                            .foregroundStyle(RoachPalette.muted)

                        Text(assetExcerpt)
                            .font(.roach(size: 13, weight: .medium))
                            .foregroundStyle(RoachPalette.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !markdownWikiLinks.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Obsidian links")
                            .font(.roach(size: 11, weight: .semibold, design: .monospaced))
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

                if !speechActionPlans.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("RoachSpeech")
                            .font(.roach(size: 11, weight: .semibold, design: .monospaced))
                            .tracking(1.1)
                            .foregroundStyle(RoachPalette.muted)

                        let runtime = RoachSpeechNativeRuntime.status()
                        let voiceProfile = RoachSpeechVoiceProfile.systemDefault
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 170), spacing: 8)], alignment: .leading, spacing: 8
                        ) {
                            ForEach(speechActionPlans, id: \.action) { plan in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(plan.action.displayName)
                                        .font(.roach(size: 12, weight: .semibold))
                                        .foregroundStyle(RoachPalette.text)
                                    Text(plan.statusLabel(runtime: runtime, voiceProfile: voiceProfile))
                                        .font(.roach(size: 11, weight: .medium))
                                        .foregroundStyle(RoachPalette.muted)
                                        .lineLimit(2)
                                    if let outputURL = plan.outputURL {
                                        Text(outputURL.lastPathComponent)
                                            .font(.roach(size: 10, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(RoachPalette.cyan)
                                            .lineLimit(1)
                                    }
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: RoachMetrics.radius(14), style: .continuous)
                                        .fill(RoachPalette.panelRaised.opacity(0.54))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: RoachMetrics.radius(14), style: .continuous)
                                        .stroke(
                                            plan.isReady(runtime: runtime, voiceProfile: voiceProfile)
                                                ? RoachPalette.green.opacity(0.42) : RoachPalette.border,
                                            lineWidth: RoachMetrics.line(1))
                                )
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
            saveStatusLine =
                asset.isMarkdown && asset.isInsideObsidianVault
                ? "Live link to Obsidian is on. RoachNet and Obsidian are reading the same file."
                : (asset.isMarkdown ? "Markdown note loaded from the Vault." : "Text file loaded from the Vault.")
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
            saveStatusLine =
                asset.isMarkdown && asset.isInsideObsidianVault
                ? "Saved the note back into the shared Obsidian vault."
                : (asset.isMarkdown ? "Saved the note back into the Vault." : "Saved the file back into the Vault.")
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
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: asset.url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []

        folderChildren =
            contents
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
        case .archive:
            return RoachPalette.cyan
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
        case .archive:
            return "archivebox.fill"
        case .folder:
            return "folder.fill"
        case .generic:
            return "doc.fill"
        }
    }
}
