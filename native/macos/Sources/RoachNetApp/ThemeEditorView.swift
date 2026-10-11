import AppKit
import RoachNetDesign
import SwiftUI

/// Edits a user theme with a live preview and readability checks. Changes are
/// written to the theme file on Save; RoachNet picks the file up right away.
struct ThemeEditorView: View {
    @ObservedObject var store: RoachThemeStore
    @State var document: RoachThemeDocument
    let baseURL: URL?
    let onClose: () -> Void

    @State private var editingDark = true
    @State private var errorText: String?
    @State private var saved = false

    init(store: RoachThemeStore, document: RoachThemeDocument, baseURL: URL?, onClose: @escaping () -> Void) {
        self.store = store
        self._document = State(initialValue: document)
        self.baseURL = baseURL
        self.onClose = onClose
        self._editingDark = State(initialValue: document.dark != nil)
    }

    private var draftTheme: RoachResolvedTheme {
        RoachThemeResolver.resolve(
            document: document,
            settings: RoachThemeSettings(themeID: document.id, appearance: editingDark ? .dark : .light),
            systemIsDark: editingDark,
            baseURL: baseURL
        )
    }

    private var modeBinding: Binding<RoachThemeModeSpec?> {
        Binding(
            get: { editingDark ? document.dark : document.light },
            set: { value in
                if editingDark { document.dark = value } else { document.light = value }
            }
        )
    }

    var body: some View {
        let theme = draftTheme
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Edit Theme")
                        .font(.roach(size: 16, weight: .bold, design: .rounded))
                    Text(document.id)
                        .font(.roach(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(RoachPalette.muted)
                }
                Spacer()
                if let errorText {
                    Text(errorText)
                        .font(.roach(size: 11, weight: .semibold))
                        .foregroundStyle(RoachPalette.danger)
                        .lineLimit(2)
                }
                Button("Close") { onClose() }
                    .buttonStyle(RoachSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(saved ? "Saved" : "Save") { save(use: false) }
                    .buttonStyle(RoachSecondaryButtonStyle())
                Button("Save and Use") { save(use: true) }
                    .buttonStyle(RoachPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)

            Divider()

            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        detailsSection
                        modeSection
                        if modeBinding.wrappedValue != nil {
                            paletteSection(theme)
                            backgroundSection(theme)
                        }
                        typeSection
                        shapeSection
                    }
                    .padding(16)
                }
                .frame(minWidth: 460)

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    RoachThemePreviewCard(theme: theme, detailed: true)
                        .frame(height: 220)
                    contrastList(theme)
                    if !theme.problems.isEmpty {
                        ForEach(theme.problems, id: \.self) { problem in
                            Text(problem)
                                .font(.roach(size: 11, weight: .medium))
                                .foregroundStyle(RoachPalette.warning)
                        }
                    }
                    Spacer()
                }
                .padding(16)
                .frame(width: 340)
            }
        }
        .frame(minWidth: 860, minHeight: 620)
        .roachThemed()
        .onChange(of: document) { _, _ in saved = false }
    }

    // MARK: Sections

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            title("Details")
            TextField("Name", text: $document.name)
            TextField("Description", text: Binding(
                get: { document.description ?? "" },
                set: { document.description = $0.isEmpty ? nil : $0 }
            ))
            TextField("Author", text: Binding(
                get: { document.author ?? "" },
                set: { document.author = $0.isEmpty ? nil : $0 }
            ))
            TextField("Tags, separated by commas", text: Binding(
                get: { (document.tags ?? []).joined(separator: ", ") },
                set: { value in
                    let tags = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
                    document.tags = tags.isEmpty ? nil : tags
                }
            ))
        }
        .textFieldStyle(.roundedBorder)
    }

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            title("Mode")
            Picker("Editing", selection: $editingDark) {
                Text("Dark").tag(true)
                Text("Light").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 260)

            if modeBinding.wrappedValue == nil {
                HStack(spacing: 8) {
                    Text("This theme has no \(editingDark ? "dark" : "light") mode yet.")
                        .font(.roach(size: 12, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                    Button("Start from Signal") {
                        let signal = RoachBuiltInThemes.defaultTheme
                        modeBinding.wrappedValue = editingDark ? signal.dark : signal.light
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())
                    if let other = editingDark ? document.light : document.dark {
                        Button("Copy the \(editingDark ? "light" : "dark") mode") {
                            modeBinding.wrappedValue = RoachThemeModeSpec(palette: nil, background: other.background)
                        }
                        .buttonStyle(RoachSecondaryButtonStyle())
                    }
                }
            } else if document.dark != nil && document.light != nil {
                Button("Remove the \(editingDark ? "dark" : "light") mode") {
                    modeBinding.wrappedValue = nil
                    editingDark.toggle()
                }
                .buttonStyle(RoachSecondaryButtonStyle())
            }
        }
    }

    private func paletteSection(_ theme: RoachResolvedTheme) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            title("Colors")
            Text("Leave a color on Auto and RoachNet works it out from the background, text and accent.")
                .font(.roach(size: 11, weight: .medium))
                .foregroundStyle(RoachPalette.muted)
            ForEach(RoachColorTokenGroup.allCases) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.rawValue)
                        .font(.roach(size: 12, weight: .bold))
                        .foregroundStyle(RoachPalette.text)
                    ForEach(group.tokens) { token in
                        tokenRow(token, resolved: theme.rgba(token))
                    }
                }
            }
        }
    }

    private func tokenRow(_ token: RoachColorToken, resolved: RoachRGBA) -> some View {
        let explicit = modeBinding.wrappedValue?.palette?[token.key]
        let translucent = [RoachColorToken.glass, .specular, .border, .borderStrong, .shadow, .muted].contains(token)
        return HStack(spacing: 10) {
            ColorPicker("", selection: Binding(
                get: { resolved.color },
                set: { color in setToken(token, RoachColorBridge.hex(color, keepAlpha: translucent)) }
            ), supportsOpacity: translucent)
            .labelsHidden()
            .frame(width: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(token.label)
                    .font(.roach(size: 12, weight: .semibold))
                    .foregroundStyle(RoachPalette.text)
                Text(token.help)
                    .font(.roach(size: 10, weight: .medium))
                    .foregroundStyle(RoachPalette.muted)
                    .lineLimit(1)
            }
            Spacer()
            TextField("Auto", text: Binding(
                get: { explicit ?? "" },
                set: { value in
                    let trimmed = value.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty { setToken(token, nil) } else if RoachRGBA(trimmed) != nil { setToken(token, trimmed) }
                }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.roach(size: 11, weight: .medium, design: .monospaced))
            .frame(width: 150)
            .help(explicit == nil ? "Auto: \(resolved.hex)" : "Set in this theme")
            if explicit != nil {
                Button {
                    setToken(token, nil)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(RoachUtilityButtonStyle())
                .help("Back to Auto")
            }
        }
    }

    private func setToken(_ token: RoachColorToken, _ value: String?) {
        var mode = modeBinding.wrappedValue ?? RoachThemeModeSpec()
        var palette = mode.palette ?? [:]
        palette[token.key] = value
        mode.palette = palette.isEmpty ? nil : palette
        modeBinding.wrappedValue = mode
    }

    private func backgroundSection(_ theme: RoachResolvedTheme) -> some View {
        let spec = modeBinding.wrappedValue?.background ?? RoachThemeBackgroundSpec()
        func setBackground(_ change: (inout RoachThemeBackgroundSpec) -> Void) {
            var mode = modeBinding.wrappedValue ?? RoachThemeModeSpec()
            var background = mode.background ?? RoachThemeBackgroundSpec()
            change(&background)
            mode.background = background
            modeBinding.wrappedValue = mode
        }
        return VStack(alignment: .leading, spacing: 8) {
            title("Background")
            Picker("Style", selection: Binding(
                get: { spec.style ?? theme.background.style.rawValue },
                set: { value in setBackground { $0.style = value } }
            )) {
                ForEach(RoachBackgroundStyle.allCases) { style in
                    Text(style.label).tag(style.rawValue)
                }
            }
            .frame(maxWidth: 300)
            Text(theme.background.style.summary)
                .font(.roach(size: 11, weight: .medium))
                .foregroundStyle(RoachPalette.muted)
            if theme.background.style == .image || spec.style == RoachBackgroundStyle.image.rawValue {
                TextField("Picture file next to the theme (for example backdrop.jpg)", text: Binding(
                    get: { spec.image ?? "" },
                    set: { value in setBackground { $0.image = value.isEmpty ? nil : value } }
                ))
                .textFieldStyle(.roundedBorder)
                slider("Dim", spec.imageDim ?? 0.35, 0...0.95) { value in setBackground { $0.imageDim = value } }
                slider("Blur", spec.imageBlur ?? 0, 0...40) { value in setBackground { $0.imageBlur = value } }
            }
            slider("Strength", spec.intensity ?? theme.background.intensity, 0...1.5) { value in setBackground { $0.intensity = value } }
            slider("Speed", spec.speed ?? theme.background.speed, 0.25...3) { value in setBackground { $0.speed = value } }
            slider("Vignette", spec.vignette ?? theme.background.vignette, 0...1) { value in setBackground { $0.vignette = value } }
            HStack(spacing: 16) {
                Toggle("Motion", isOn: Binding(
                    get: { spec.motion ?? true },
                    set: { value in setBackground { $0.motion = value } }
                ))
                if theme.background.style == .particles {
                    Toggle("Rise (off: fall)", isOn: Binding(
                        get: { spec.rise ?? true },
                        set: { value in setBackground { $0.rise = value } }
                    ))
                }
            }
            .toggleStyle(.switch)
        }
    }

    private var typeSection: some View {
        let typography = document.typography ?? RoachThemeTypographySpec()
        func setType(_ change: (inout RoachThemeTypographySpec) -> Void) {
            var next = typography
            change(&next)
            document.typography = next
        }
        return VStack(alignment: .leading, spacing: 8) {
            title("Type")
            HStack(spacing: 12) {
                RoachFontPicker(title: "Headings", selection: Binding(get: { typography.display }, set: { value in setType { $0.display = value } }))
                RoachFontPicker(title: "Body", selection: Binding(get: { typography.body }, set: { value in setType { $0.body = value } }))
                RoachFontPicker(title: "Mono", selection: Binding(get: { typography.mono }, set: { value in setType { $0.mono = value } }))
            }
            slider("Text size", typography.scale ?? 1, 0.8...1.4) { value in setType { $0.scale = value } }
        }
    }

    private var shapeSection: some View {
        let shape = document.shape ?? RoachThemeShapeSpec()
        let effects = document.effects ?? RoachThemeEffectsSpec()
        return VStack(alignment: .leading, spacing: 8) {
            title("Shape and effects")
            slider("Corner roundness", shape.radiusScale ?? 1, 0...2) { value in
                var next = shape; next.radiusScale = value; document.shape = next
            }
            slider("Border width", shape.borderWidth ?? 1, 0.5...3) { value in
                var next = shape; next.borderWidth = value; document.shape = next
            }
            slider("Glass", effects.glass ?? 1, 0...2) { value in
                var next = effects; next.glass = value; document.effects = next
            }
            slider("Glow", effects.glow ?? 1, 0...2) { value in
                var next = effects; next.glow = value; document.effects = next
            }
            slider("Shadows", effects.shadow ?? 1, 0...2) { value in
                var next = effects; next.shadow = value; document.effects = next
            }
        }
    }

    private func contrastList(_ theme: RoachResolvedTheme) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            title("Readability")
            ForEach(RoachThemeValidator.contrastChecks(for: theme)) { check in
                HStack(spacing: 6) {
                    Image(systemName: check.passes ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(check.passes ? RoachPalette.success : RoachPalette.warning)
                    Text(check.label)
                    Spacer()
                    Text(String(format: "%.1f / %.1f", check.ratio, check.minimum))
                        .font(.roach(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(RoachPalette.muted)
                }
                .font(.roach(size: 11, weight: .medium))
            }
        }
    }

    // MARK: Helpers

    private func title(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.roach(size: 11, weight: .semibold, design: .monospaced))
            .tracking(1.1)
            .foregroundStyle(RoachPalette.muted)
    }

    private func slider(_ label: String, _ value: Double, _ range: ClosedRange<Double>, set: @escaping @MainActor (Double) -> Void) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.roach(size: 12, weight: .semibold))
                .frame(width: 130, alignment: .leading)
            Slider(value: Binding(get: { value }, set: { newValue in MainActor.assumeIsolated { set(newValue) } }), in: range)
            Text(String(format: "%.2f", value))
                .font(.roach(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(RoachPalette.muted)
                .frame(width: 44, alignment: .trailing)
        }
    }

    private func save(use: Bool) {
        document.name = document.name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try store.saveUserTheme(document, assetsFrom: baseURL)
            saved = true
            errorText = nil
            if use, let entry = store.themes.first(where: { $0.id == document.id }) {
                store.select(entry)
                onClose()
            }
        } catch {
            errorText = error.localizedDescription
        }
    }
}
