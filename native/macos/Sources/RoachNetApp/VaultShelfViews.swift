import AppKit
import QuickLookThumbnailing
import SwiftUI
import RoachNetDesign

@MainActor
private enum VaultShelfMetadataSupport {
    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static func tags(for url: URL, extraTags: [String]) -> [String] {
        var tags = extraTags
        let resourceValues = try? url.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey,
            .isDirectoryKey,
        ])

        if !(resourceValues?.isDirectory ?? false) {
            let fileExtension = url.pathExtension.uppercased()
            if !fileExtension.isEmpty {
                tags.append(fileExtension)
            }
            if let size = resourceValues?.fileSize {
                tags.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
            }
        }

        if let modifiedAt = resourceValues?.contentModificationDate {
            tags.append(relativeDateFormatter.localizedString(for: modifiedAt, relativeTo: Date()))
        }

        var seen = Set<String>()
        return tags.filter { tag in
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            return seen.insert(trimmed).inserted
        }
    }
}

@MainActor
private final class VaultThumbnailModel: ObservableObject {
    private static let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 256
        return cache
    }()

    @Published var image: NSImage?

    init(url: URL, size: CGSize) {
        let cacheKey = url as NSURL
        image = Self.cache.object(forKey: cacheKey)
        guard image == nil else { return }
        Task { await loadThumbnail(for: url, size: size) }
    }

    private func loadThumbnail(for url: URL, size: CGSize) async {
        let cacheKey = url as NSURL
        if let cached = Self.cache.object(forKey: cacheKey) {
            image = cached
            return
        }

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .all
        )

        do {
            let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            Self.cache.setObject(representation.nsImage, forKey: cacheKey)
            image = representation.nsImage
        } catch {
            image = nil
        }
    }
}

private struct VaultThumbnailView: View {
    let url: URL
    let accent: Color
    let fallbackSystemName: String
    let idlePhase: Bool
    let isHovered: Bool

    @StateObject private var thumbnailModel: VaultThumbnailModel

    init(
        url: URL,
        accent: Color,
        fallbackSystemName: String,
        idlePhase: Bool,
        isHovered: Bool
    ) {
        self.url = url
        self.accent = accent
        self.fallbackSystemName = fallbackSystemName
        self.idlePhase = idlePhase
        self.isHovered = isHovered
        _thumbnailModel = StateObject(
            wrappedValue: VaultThumbnailModel(url: url, size: CGSize(width: 220, height: 220))
        )
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            accent.opacity(isHovered ? 0.28 : 0.18),
                            Color.black.opacity(0.08),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(accent.opacity(isHovered ? 0.55 : 0.28), lineWidth: 1.2)

            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            accent.opacity(isHovered ? 0.36 : 0.22),
                            Color.clear,
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: 20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)

            Circle()
                .fill(accent.opacity(isHovered ? 0.22 : 0.12))
                .blur(radius: isHovered ? 28 : 20)
                .scaleEffect(isHovered ? 1.14 : (idlePhase ? 1.04 : 0.96))
                .offset(x: isHovered ? 22 : -14, y: isHovered ? -18 : 10)

            if let image = thumbnailModel.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .scaleEffect(isHovered ? 1.1 : 1.03)
                    .saturation(isHovered ? 1.05 : 0.96)
                    .overlay(
                        LinearGradient(
                            colors: [
                                Color.black.opacity(0.0),
                                Color.black.opacity(0.12),
                                Color.black.opacity(0.22),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(idlePhase ? 0.14 : 0.04),
                                Color.white.opacity(0.0),
                            ],
                            startPoint: .topLeading,
                            endPoint: .center
                        )
                    )
            } else {
                Image(systemName: fallbackSystemName)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(accent)
                    .rotationEffect(.degrees(isHovered ? -6 : (idlePhase ? -3 : 3)))
                    .scaleEffect(isHovered ? 1.1 : 1.0)
            }

            LinearGradient(
                colors: [
                    Color.white.opacity(isHovered ? 0.20 : 0.12),
                    Color.white.opacity(0.0),
                ],
                startPoint: .topLeading,
                endPoint: .center
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            Capsule(style: .continuous)
                .fill(accent.opacity(isHovered ? 0.24 : 0.14))
                .frame(width: 120, height: 6)
                .blur(radius: isHovered ? 8 : 6)
                .offset(y: 80)
        }
        .shadow(color: accent.opacity(isHovered ? 0.34 : 0.16), radius: isHovered ? 18 : 10, y: 10)
        .rotation3DEffect(.degrees(isHovered ? 5 : (idlePhase ? 2 : -2)), axis: (x: 1, y: 0, z: 0), perspective: 0.8)
        .rotationEffect(.degrees(isHovered ? -1.5 : (idlePhase ? -0.7 : 0.7)))
        .offset(y: isHovered ? -3 : (idlePhase ? -1.5 : 1.5))
        .animation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true), value: idlePhase)
        .animation(.spring(response: 0.26, dampingFraction: 0.82), value: isHovered)
    }
}

private struct VaultGlyphTileView: View {
    let accent: Color
    let fallbackSystemName: String
    let idlePhase: Bool
    let isHovered: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            accent.opacity(isHovered ? 0.26 : 0.18),
                            Color.black.opacity(0.08),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(accent.opacity(isHovered ? 0.55 : 0.28), lineWidth: 1.2)

            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            accent.opacity(isHovered ? 0.34 : 0.22),
                            Color.clear,
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: 20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)

            Circle()
                .fill(accent.opacity(isHovered ? 0.24 : 0.16))
                .blur(radius: isHovered ? 26 : 18)
                .scaleEffect(isHovered ? 1.12 : (idlePhase ? 1.04 : 0.98))

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(idlePhase ? 0.12 : 0.04),
                            Color.white.opacity(0.0),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .padding(12)

            Image(systemName: fallbackSystemName)
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(accent)
                .rotationEffect(.degrees(isHovered ? -8 : (idlePhase ? -4 : 4)))
                .scaleEffect(isHovered ? 1.12 : 1.0)
                .shadow(color: accent.opacity(isHovered ? 0.44 : 0.22), radius: isHovered ? 18 : 10, y: 8)

            LinearGradient(
                colors: [
                    Color.white.opacity(isHovered ? 0.18 : 0.10),
                    Color.white.opacity(0.0),
                ],
                startPoint: .topLeading,
                endPoint: .center
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            Capsule(style: .continuous)
                .fill(accent.opacity(isHovered ? 0.22 : 0.12))
                .frame(width: 120, height: 6)
                .blur(radius: isHovered ? 8 : 6)
                .offset(y: 80)
        }
        .shadow(color: accent.opacity(isHovered ? 0.34 : 0.16), radius: isHovered ? 18 : 10, y: 10)
        .rotation3DEffect(.degrees(isHovered ? 5 : (idlePhase ? 2 : -2)), axis: (x: 1, y: 0, z: 0), perspective: 0.8)
        .rotationEffect(.degrees(isHovered ? -1.5 : (idlePhase ? -0.7 : 0.7)))
        .offset(y: isHovered ? -3 : (idlePhase ? -1.5 : 1.5))
        .animation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true), value: idlePhase)
        .animation(.spring(response: 0.26, dampingFraction: 0.82), value: isHovered)
    }
}

private struct VaultMetadataStrip: View {
    let tags: [String]
    let accent: Color

    var body: some View {
        if !tags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(tags.prefix(4), id: \.self) { tag in
                        RoachTag(tag, accent: accent)
                    }
                }
            }
        }
    }
}

struct VaultShelfCard: View {
    let url: URL
    let title: String
    let detail: String
    let pathLabel: String
    let kindLabel: String
    let actionLabel: String
    let accent: Color
    let fallbackSystemName: String
    let extraTags: [String]

    @State private var isHovered = false
    @State private var idlePhase = false
    @State private var isPressed = false

    private var metadataTags: [String] {
        VaultShelfMetadataSupport.tags(for: url, extraTags: extraTags)
    }

    var body: some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    RoachTag(kindLabel, accent: accent)
                    Spacer(minLength: 8)
                    Text(actionLabel)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(1.0)
                        .foregroundStyle(accent)
                }

                VaultThumbnailView(
                    url: url,
                    accent: accent,
                    fallbackSystemName: fallbackSystemName,
                    idlePhase: idlePhase,
                    isHovered: isHovered
                )
                .frame(height: 168)

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(RoachPalette.text)
                        .lineLimit(2)

                    Text(detail)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                        .lineLimit(3)

                    Text(pathLabel)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(RoachPalette.muted)
                        .lineLimit(2)
                }

                VaultMetadataStrip(tags: metadataTags, accent: accent)
            }
        }
        .scaleEffect(isPressed ? 0.988 : (isHovered ? 1.024 : 1.0))
        .rotation3DEffect(.degrees(isPressed ? 6 : (isHovered ? 2.5 : 0)), axis: (x: 1, y: 0, z: 0), perspective: 0.9)
        .onHover { hovered in
            withAnimation(.spring(response: 0.24, dampingFraction: 0.84)) {
                isHovered = hovered
            }
        }
        .onLongPressGesture(minimumDuration: 0, maximumDistance: 24, pressing: { pressing in
            withAnimation(.spring(response: 0.2, dampingFraction: 0.84)) {
                isPressed = pressing
            }
        }, perform: {})
        .onAppear {
            idlePhase = true
        }
    }
}

struct VaultVirtualShelfCard: View {
    let title: String
    let detail: String
    let pathLabel: String
    let kindLabel: String
    let actionLabel: String
    let accent: Color
    let fallbackSystemName: String
    let extraTags: [String]

    @State private var isHovered = false
    @State private var idlePhase = false
    @State private var isPressed = false

    var body: some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    RoachTag(kindLabel, accent: accent)
                    Spacer(minLength: 8)
                    Text(actionLabel)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(1.0)
                        .foregroundStyle(accent)
                }

                VaultGlyphTileView(
                    accent: accent,
                    fallbackSystemName: fallbackSystemName,
                    idlePhase: idlePhase,
                    isHovered: isHovered
                )
                .frame(height: 168)

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(RoachPalette.text)
                        .lineLimit(2)

                    Text(detail)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                        .lineLimit(3)

                    Text(pathLabel)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(RoachPalette.muted)
                        .lineLimit(2)
                }

                VaultMetadataStrip(tags: extraTags, accent: accent)
            }
        }
        .scaleEffect(isPressed ? 0.988 : (isHovered ? 1.024 : 1.0))
        .rotation3DEffect(.degrees(isPressed ? 6 : (isHovered ? 2.5 : 0)), axis: (x: 1, y: 0, z: 0), perspective: 0.9)
        .onHover { hovered in
            withAnimation(.spring(response: 0.24, dampingFraction: 0.84)) {
                isHovered = hovered
            }
        }
        .onLongPressGesture(minimumDuration: 0, maximumDistance: 24, pressing: { pressing in
            withAnimation(.spring(response: 0.2, dampingFraction: 0.84)) {
                isPressed = pressing
            }
        }, perform: {})
        .onAppear {
            idlePhase = true
        }
    }
}
