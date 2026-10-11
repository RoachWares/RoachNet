import AppKit
import RoachNetDesign
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Appearance: pick a theme, layer snippets, fine-tune, check
/// readability, and make your own.
struct AppearanceSettingsView: View {
    @ObservedObject var store: RoachThemeStore
    @State private var themeFilter: ThemeFilter = .all
    @State private var search = ""
    @State private var session: ThemeEditSession?
    @State private var errorText: String?

    enum ThemeFilter: String, CaseIterable, Identifiable {
        case all, dark, light, yours, packs, retro, seasonal, calm, vivid, accessible

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: return "All"
            case .dark: return "Dark"
            case .light: return "Light"
            case .yours: return "Yours"
            case .packs: return "From packs"
            case .retro: return "Retro"
            case .seasonal: return "Seasonal"
            case .calm: return "Calm"
            case .vivid: return "Vivid"
            case .accessible: return "High contrast"
            }
        }

        func matches(_ entry: RoachThemeEntry) -> Bool {
            let tags = Set(entry.document.tags ?? [])
            switch self {
            case .all: return true
            case .dark: return entry.document.dark != nil
            case .light: return entry.document.light != nil
            case .yours: return entry.isUserTheme
            case .packs:
                if case .pack = entry.source { return true }
                return false
            case .retro: return tags.contains("retro") || tags.contains("mono")
            case .seasonal: return tags.contains("seasonal")
            case .calm: return tags.contains("calm") || tags.contains("neutral")
            case .vivid: return tags.contains("vivid")
            case .accessible: return tags.contains("high-contrast") || tags.contains("accessibility")
            }
        }
    }

    private var filteredThemes: [RoachThemeEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return store.themes.filter { entry in
            guard themeFilter.matches(entry) else { return false }
            guard !query.isEmpty else { return true }
            let haystack = ([entry.document.name, entry.document.description ?? "", entry.sourceLabel] + (entry.document.tags ?? []))
                .joined(separator: " ").lowercased()
            return haystack.contains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            currentThemePanel
            galleryPanel
            snippetsPanel
            fineTunePanel
            readabilityPanel
            if !allProblems.isEmpty {
                problemsPanel
            }
        }
        .sheet(item: $session) { session in
            ThemeEditorView(store: store, document: session.document, baseURL: session.baseURL) {
                self.session = nil
            }
        }
        .alert("Appearance", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
    }

    // MARK: Current theme

    private var currentThemePanel: some View {
        RoachInsetPanel {
            HStack(alignment: .top, spacing: 16) {
                RoachThemePreviewCard(theme: store.active, detailed: true)
                    .frame(width: 236, height: 148)

                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("Theme")
                    Text(store.activeEntry?.document.name ?? "Signal")
                        .font(.roach(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(RoachPalette.text)
                    if let description = store.activeEntry?.document.description {
                        Text(description)
                            .font(.roach(size: 12, weight: .medium))
                            .foregroundStyle(RoachPalette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Picker("Mode", selection: Binding(
                        get: { store.settings.appearance },
                        set: { value in store.update { $0.appearance = value } }
                    )) {
                        ForEach(RoachAppearancePreference.allCases) { preference in
                            Text(preference.label).tag(preference)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 340)

                    if let note = variantNote {
                        Text(note)
                            .font(.roach(size: 11, weight: .medium))
                            .foregroundStyle(RoachPalette.warning)
                    }

                    RoachFlowLayout(spacing: 8) {
                        Button {
                            customizeActive()
                        } label: {
                            Label(store.activeEntry?.isUserTheme == true ? "Edit Theme" : "Customize", systemImage: "slider.horizontal.below.square.and.square.filled")
                        }
                        .buttonStyle(RoachPrimaryButtonStyle())

                        Button {
                            importThemeFile()
                        } label: {
                            Label("Import…", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())

                        if let entry = store.activeEntry {
                            Button {
                                export(entry)
                            } label: {
                                Label("Export…", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(RoachSecondaryButtonStyle())
                        }

                        Button {
                            store.revealThemesFolder()
                        } label: {
                            Label("Themes Folder", systemImage: "folder")
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())

                        Button {
                            store.reload()
                            store.lastMessage = "Reloaded \(store.themes.count) themes and \(store.snippets.count) snippets."
                        } label: {
                            Label("Reload", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())
                    }

                    if let message = store.lastMessage {
                        Text(message)
                            .font(.roach(size: 11, weight: .medium))
                            .foregroundStyle(RoachPalette.muted)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var variantNote: String? {
        guard let entry = store.activeEntry else { return nil }
        let wantsLight = store.settings.appearance == .light
            || (store.settings.appearance == .system && !RoachThemeStore.systemIsDark())
        if wantsLight && entry.document.light == nil { return "\(entry.document.name) has no light mode, so RoachNet shows its dark mode." }
        if !wantsLight && entry.document.dark == nil { return "\(entry.document.name) has no dark mode, so RoachNet shows its light mode." }
        return nil
    }

    // MARK: Gallery

    private var galleryPanel: some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    sectionTitle("Themes · \(store.themes.count)")
                    Spacer()
                    TextField("Search themes", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                }

                RoachFlowLayout(spacing: 6) {
                        ForEach(ThemeFilter.allCases) { option in
                            Button {
                                themeFilter = option
                            } label: {
                                Text(option.label)
                                    .font(.roach(size: 11, weight: .semibold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .foregroundStyle(themeFilter == option ? RoachPalette.onAccent : RoachPalette.text)
                                    .background(
                                        Capsule().fill(themeFilter == option ? RoachPalette.green : RoachPalette.panelRaised)
                                    )
                                    .overlay(Capsule().stroke(RoachPalette.border, lineWidth: RoachMetrics.line(1)))
                            }
                            .buttonStyle(.plain)
                        }
                }

                if filteredThemes.isEmpty {
                    Text("No themes match.")
                        .font(.roach(size: 12, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 178, maximum: 240), spacing: 12)], alignment: .leading, spacing: 12) {
                        ForEach(filteredThemes) { entry in
                            ThemeGalleryCard(
                                entry: entry,
                                preview: store.preview(entry),
                                isActive: entry.id == store.settings.themeID
                            ) {
                                store.select(entry)
                            }
                            .contextMenu {
                                Button("Use \(entry.document.name)") { store.select(entry) }
                                Button("Duplicate and Edit…") { duplicateAndEdit(entry) }
                                if entry.isUserTheme {
                                    Button("Edit…") { session = ThemeEditSession(document: entry.document, baseURL: entry.baseURL) }
                                }
                                Button("Export…") { export(entry) }
                                if entry.isUserTheme {
                                    Divider()
                                    Button("Move to Trash", role: .destructive) {
                                        do { try store.trash(entry) } catch { errorText = error.localizedDescription }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Snippets

    private var snippetsPanel: some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    sectionTitle("Snippets")
                    Spacer()
                    Text("Small overrides layered on any theme, in order.")
                        .font(.roach(size: 11, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                }
                ForEach(store.snippets) { snippet in
                    snippetRow(snippet)
                }
            }
        }
    }

    private func snippetRow(_ snippet: RoachSnippetEntry) -> some View {
        let enabled = store.settings.snippets.contains(snippet.id)
        let position = store.settings.snippets.firstIndex(of: snippet.id)
        return HStack(alignment: .center, spacing: 10) {
            Toggle("", isOn: Binding(get: { enabled }, set: { store.setSnippet(snippet.id, enabled: $0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(snippet.hasErrors)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(snippet.document.name)
                        .font(.roach(size: 13, weight: .semibold))
                        .foregroundStyle(RoachPalette.text)
                    if snippet.source != .builtIn {
                        RoachTag(snippet.source == .user ? "Yours" : "Pack", accent: RoachPalette.cyan)
                    }
                    if let position {
                        Text("#\(position + 1)")
                            .font(.roach(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(RoachPalette.green)
                    }
                }
                Text(snippet.hasErrors ? (snippet.issues.first?.message ?? "") : (snippet.document.description ?? ""))
                    .font(.roach(size: 11, weight: .medium))
                    .foregroundStyle(snippet.hasErrors ? RoachPalette.danger : RoachPalette.muted)
            }
            Spacer()
            if enabled, store.settings.snippets.count > 1 {
                Button { store.moveSnippet(snippet.id, by: -1) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(RoachUtilityButtonStyle())
                    .help("Apply earlier")
                Button { store.moveSnippet(snippet.id, by: 1) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(RoachUtilityButtonStyle())
                    .help("Apply later")
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Fine tuning, readability, problems, actions

extension AppearanceSettingsView {
    private var fineTunePanel: some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    sectionTitle("Fine tuning")
                    Spacer()
                    if store.settings.hasOverrides {
                        Button("Reset to Theme") { store.resetOverrides() }
                            .buttonStyle(RoachSecondaryButtonStyle())
                    }
                }

                HStack(spacing: 12) {
                    ColorPicker("Accent", selection: Binding(
                        get: { store.active[.accent] },
                        set: { color in store.update { $0.accent = RoachColorBridge.hex(color) } }
                    ), supportsOpacity: false)
                    .font(.roach(size: 12, weight: .semibold))
                    if store.settings.accent != nil {
                        Button("Theme Accent") { store.update { $0.accent = nil } }
                            .buttonStyle(RoachSecondaryButtonStyle())
                    }
                    Spacer()
                }

                HStack(spacing: 12) {
                    RoachFontPicker(title: "Headings", selection: Binding(
                        get: { store.settings.displayFont },
                        set: { value in store.update { $0.displayFont = value } }
                    ))
                    RoachFontPicker(title: "Body", selection: Binding(
                        get: { store.settings.bodyFont },
                        set: { value in store.update { $0.bodyFont = value } }
                    ))
                    RoachFontPicker(title: "Mono", selection: Binding(
                        get: { store.settings.monoFont },
                        set: { value in store.update { $0.monoFont = value } }
                    ))
                }

                slider("Text size", value: Binding(
                    get: { store.settings.textScale ?? store.active.typography.scale },
                    set: { value in store.update { $0.textScale = value } }
                ), range: 0.8...1.4, format: { "\(Int(($0 * 100).rounded()))%" })

                slider("Corner roundness", value: Binding(
                    get: { store.settings.radiusScale ?? store.active.radiusScale },
                    set: { value in store.update { $0.radiusScale = value } }
                ), range: 0...2, format: { $0 < 0.05 ? "Square" : "\(Int(($0 * 100).rounded()))%" })

                slider("Glass", value: Binding(
                    get: { store.settings.glass ?? store.active.glass },
                    set: { value in store.update { $0.glass = value } }
                ), range: 0...2, format: { $0 < 0.05 ? "Off" : "\(Int(($0 * 100).rounded()))%" })

                HStack(spacing: 12) {
                    Picker("Background", selection: Binding(
                        get: { store.settings.backgroundStyle ?? "" },
                        set: { value in store.update { $0.backgroundStyle = value.isEmpty ? nil : value } }
                    )) {
                        Text("Theme default (\(store.active.background.style.label))").tag("")
                        Divider()
                        ForEach(RoachBackgroundStyle.allCases.filter { $0 != .image }) { style in
                            Text(style.label).tag(style.rawValue)
                        }
                    }
                    .frame(maxWidth: 320)

                    Toggle("Motion", isOn: Binding(
                        get: { store.settings.backgroundMotion ?? store.active.background.motion },
                        set: { value in store.update { $0.backgroundMotion = value } }
                    ))
                    .toggleStyle(.switch)
                    Spacer()
                }
                .font(.roach(size: 12, weight: .semibold))

                Text(store.active.background.style.summary + (NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? " Reduce Motion is on in macOS, so it holds still." : ""))
                    .font(.roach(size: 11, weight: .medium))
                    .foregroundStyle(RoachPalette.muted)

                slider("Background strength", value: Binding(
                    get: { store.settings.backgroundIntensity ?? store.active.background.intensity },
                    set: { value in store.update { $0.backgroundIntensity = value } }
                ), range: 0...1.5, format: { $0 < 0.05 ? "Off" : "\(Int(($0 * 100).rounded()))%" })
            }
        }
    }

    private var readabilityPanel: some View {
        let checks = RoachThemeValidator.contrastChecks(for: store.active)
        let failing = checks.filter { !$0.passes }
        return RoachInsetPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    sectionTitle("Readability")
                    Spacer()
                    Text(failing.isEmpty ? "Every check passes." : "\(failing.count) of \(checks.count) checks are below the WCAG target.")
                        .font(.roach(size: 11, weight: .semibold))
                        .foregroundStyle(failing.isEmpty ? RoachPalette.success : RoachPalette.warning)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 8)], alignment: .leading, spacing: 6) {
                    ForEach(checks) { check in
                        HStack(spacing: 6) {
                            Image(systemName: check.passes ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(check.passes ? RoachPalette.success : RoachPalette.warning)
                            Text(check.label)
                                .foregroundStyle(RoachPalette.text)
                            Spacer(minLength: 4)
                            Text(String(format: "%.1f:1", check.ratio))
                                .font(.roach(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(RoachPalette.muted)
                        }
                        .font(.roach(size: 11, weight: .medium))
                    }
                }
            }
        }
    }

    private var allProblems: [String] {
        var lines = store.problems
        lines += store.active.problems
        if let entry = store.activeEntry {
            lines += entry.issues.filter { $0.severity == .error }.map { "\(entry.document.name): \($0.message)" }
        }
        return Array(NSOrderedSet(array: lines)) as? [String] ?? lines
    }

    private var problemsPanel: some View {
        RoachNotice(
            title: "Some theme files need attention",
            detail: allProblems.prefix(6).joined(separator: "\n"),
            accent: RoachPalette.warning
        )
    }

    func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.roach(size: 11, weight: .semibold, design: .monospaced))
            .tracking(1.1)
            .foregroundStyle(RoachPalette.muted)
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, format: @escaping (Double) -> String) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.roach(size: 12, weight: .semibold))
                .foregroundStyle(RoachPalette.text)
                .frame(width: 150, alignment: .leading)
            Slider(value: value, in: range)
            Text(format(value.wrappedValue))
                .font(.roach(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(RoachPalette.muted)
                .frame(width: 64, alignment: .trailing)
        }
    }

    private func customizeActive() {
        guard let entry = store.activeEntry else { return }
        if entry.isUserTheme {
            session = ThemeEditSession(document: entry.document, baseURL: entry.baseURL)
        } else {
            duplicateAndEdit(entry)
        }
    }

    private func duplicateAndEdit(_ entry: RoachThemeEntry) {
        do {
            let copy = try store.duplicate(entry)
            store.select(copy)
            session = ThemeEditSession(document: copy.document, baseURL: copy.baseURL)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func importThemeFile() {
        let panel = NSOpenPanel()
        panel.title = "Import a theme or snippet"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        var imported: [String] = []
        for url in panel.urls {
            do {
                imported.append(try store.importFile(at: url))
            } catch {
                errorText = "\(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        if imported.count == 1, let id = imported.first, let entry = store.themes.first(where: { $0.id == id }) {
            store.select(entry)
        }
    }

    private func export(_ entry: RoachThemeEntry) {
        let panel = NSSavePanel()
        panel.title = "Export \(entry.document.name)"
        panel.nameFieldStringValue = entry.id + RoachThemeDocument.fileSuffix
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.export(entry, to: url)
            store.lastMessage = "Exported \(entry.document.name) to \(url.lastPathComponent)."
        } catch {
            errorText = error.localizedDescription
        }
    }
}

struct ThemeEditSession: Identifiable {
    let id = UUID()
    var document: RoachThemeDocument
    var baseURL: URL?
}

/// Converts SwiftUI colors to theme hex strings.
enum RoachColorBridge {
    static func hex(_ color: Color, keepAlpha: Bool = false) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        let rgba = RoachRGBA(
            red: Double(ns.redComponent),
            green: Double(ns.greenComponent),
            blue: Double(ns.blueComponent),
            alpha: keepAlpha ? Double(ns.alphaComponent) : 1
        )
        return rgba.hex
    }
}

/// A font role picker: theme default, the system designs, or any installed family.
struct RoachFontPicker: View {
    let title: String
    @Binding var selection: String?

    private static let families = RoachFontFace.installedFamilies()

    var body: some View {
        Picker(title, selection: Binding(
            get: { selection ?? "" },
            set: { selection = $0.isEmpty ? nil : $0 }
        )) {
            Text("Theme default").tag("")
            Divider()
            Text("System").tag("system")
            Text("System Rounded").tag("system-rounded")
            Text("System Serif").tag("system-serif")
            Text("System Mono").tag("system-mono")
            Divider()
            ForEach(Self.families, id: \.self) { family in
                Text(family).tag(family)
            }
        }
        .font(.roach(size: 12, weight: .semibold))
        .frame(maxWidth: 240)
    }
}

/// A gallery tile: a small live sample of the theme plus its name.
struct ThemeGalleryCard: View {
    let entry: RoachThemeEntry
    let preview: RoachResolvedTheme
    let isActive: Bool
    let onSelect: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                RoachThemePreviewCard(theme: preview, detailed: false)
                    .frame(height: 104)
                HStack(spacing: 6) {
                    Text(entry.document.name)
                        .font(.roach(size: 12, weight: .bold))
                        .foregroundStyle(RoachPalette.text)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    if entry.document.dark != nil {
                        Image(systemName: "moon.fill").help("Has a dark mode")
                    }
                    if entry.document.light != nil {
                        Image(systemName: "sun.max.fill").help("Has a light mode")
                    }
                }
                .font(.roach(size: 10, weight: .semibold))
                .foregroundStyle(RoachPalette.muted)
                Text(entry.hasErrors ? "Has errors; see Readability and problems." : entry.sourceLabel)
                    .font(.roach(size: 10, weight: .medium))
                    .foregroundStyle(entry.hasErrors ? RoachPalette.danger : RoachPalette.muted)
                    .lineLimit(1)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: RoachMetrics.radius(14), style: .continuous)
                    .fill(RoachPalette.panelRaised.opacity(hovered ? 0.95 : 0.75))
            )
            .overlay(
                RoundedRectangle(cornerRadius: RoachMetrics.radius(14), style: .continuous)
                    .stroke(isActive ? RoachPalette.green : RoachPalette.border, lineWidth: RoachMetrics.line(isActive ? 2 : 1))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel("\(entry.document.name) theme\(isActive ? ", in use" : "")")
    }
}

/// A miniature RoachNet window drawn entirely in `theme`'s colors and type,
/// independent of the active theme.
struct RoachThemePreviewCard: View {
    let theme: RoachResolvedTheme
    let detailed: Bool

    var body: some View {
        let radius = 12 * theme.radiusScale
        let scale = theme.typography.scale
        ZStack(alignment: .topLeading) {
            RoachThemeBackdrop(theme: theme, reduceMotion: true)
            VStack(alignment: .leading, spacing: detailed ? 8 : 5) {
                HStack(spacing: 4) {
                    ForEach([RoachColorToken.accent, .accentSecondary, .accentTertiary, .accentInfo], id: \.self) { token in
                        Circle().fill(theme[token]).frame(width: 8, height: 8)
                    }
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("RoachClaw")
                        .font(theme.typography.display.font(size: (detailed ? 15 : 11) * scale, weight: .bold))
                        .foregroundStyle(theme[.text])
                    Text("Local model ready · 98 tok/s")
                        .font(theme.typography.body.font(size: (detailed ? 11 : 8.5) * scale, weight: .medium))
                        .foregroundStyle(theme[.muted])
                        .lineLimit(1)
                    if detailed {
                        Text("~/RoachNet/vault")
                            .font(theme.typography.mono.font(size: 10 * scale, weight: .medium))
                            .foregroundStyle(theme[.accentInfo])
                    }
                    HStack(spacing: 5) {
                        Text("Run")
                            .font(theme.typography.display.font(size: (detailed ? 10 : 8) * scale, weight: .semibold))
                            .foregroundStyle(theme[.onAccent])
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(theme[.accent]))
                        Text("Stop")
                            .font(theme.typography.display.font(size: (detailed ? 10 : 8) * scale, weight: .semibold))
                            .foregroundStyle(theme[.text])
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(theme[.panelSoft]))
                            .overlay(Capsule().stroke(theme[.borderStrong], lineWidth: theme.borderWidth))
                        if detailed {
                            Circle().fill(theme[.success]).frame(width: 6, height: 6)
                            Circle().fill(theme[.warning]).frame(width: 6, height: 6)
                            Circle().fill(theme[.danger]).frame(width: 6, height: 6)
                        }
                    }
                }
                .padding(detailed ? 10 : 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(theme[.panel].opacity(0.94))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .stroke(theme[.border], lineWidth: theme.borderWidth)
                )
            }
            .padding(detailed ? 12 : 8)
        }
        .clipShape(RoundedRectangle(cornerRadius: max(4, radius * 0.9), style: .continuous))
        .environment(\.colorScheme, theme.colorScheme)
        .accessibilityHidden(true)
    }
}
