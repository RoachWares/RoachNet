import AppKit
import CoreText
import Foundation
import SwiftUI

public enum RoachBundledFace: String, CaseIterable, Sendable, Identifiable {
    case anybody = "anybody"
    case schibstedGrotesk = "schibsted-grotesk"
    case jetBrainsMono = "jetbrains-mono"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .anybody: return "Anybody"
        case .schibstedGrotesk: return "Schibsted Grotesk"
        case .jetBrainsMono: return "JetBrains Mono"
        }
    }

    public init?(key: String) {
        let folded = key.lowercased().replacingOccurrences(of: " ", with: "-")
        switch folded {
        case "anybody": self = .anybody
        case "schibsted-grotesk", "schibstedgrotesk": self = .schibstedGrotesk
        case "jetbrains-mono", "jetbrainsmono": self = .jetBrainsMono
        default: return nil
        }
    }

    var isMonospaced: Bool { self == .jetBrainsMono }

    fileprivate func fileStem(italic: Bool) -> (latin: String, latinExt: String) {
        let style = italic ? "italic" : "normal"
        switch self {
        case .anybody:
            return ("anybody-latin-standard-\(style)", "anybody-latin-ext-standard-\(style)")
        case .schibstedGrotesk:
            return ("schibsted-grotesk-latin-wght-\(style)", "schibsted-grotesk-latin-ext-wght-\(style)")
        case .jetBrainsMono:
            return ("jetbrains-mono-latin-wght-\(style)", "jetbrains-mono-latin-ext-wght-\(style)")
        }
    }

    fileprivate var weightRange: ClosedRange<Double> {
        switch self {
        case .anybody: return 100...900
        case .schibstedGrotesk: return 400...900
        case .jetBrainsMono: return 100...800
        }
    }

    fileprivate var hasWidthAxis: Bool { self == .anybody }
}

public enum RoachFonts {
    public static let displayWeight: Double = 820
    public static let displayWidth: Double = 112
    public static let displayMinimumSize: CGFloat = 17

    static let bundleName = "RoachNetMac_RoachNetDesign.bundle"
    private static let weightAxis = NSNumber(value: 0x7767_6874)
    private static let widthAxis = NSNumber(value: 0x7764_7468)

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var descriptors: [String: CTFontDescriptor] = [:]
        var fonts: [String: CTFont] = [:]
        var fontsFolder: URL??
    }

    private static let cache = Cache()

    public static var fontsFolder: URL? {
        cache.lock.lock()
        defer { cache.lock.unlock() }
        if let known = cache.fontsFolder { return known }
        let found = locateFontsFolder()
        cache.fontsFolder = .some(found)
        return found
    }

    public static var isAvailable: Bool {
        RoachBundledFace.allCases.allSatisfy { descriptor(for: $0, italic: false) != nil }
    }

    private static func locateFontsFolder() -> URL? {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL { candidates.append(resources) }
        candidates.append(Bundle.main.bundleURL)
        let library = Bundle(for: Cache.self)
        if let resources = library.resourceURL { candidates.append(resources) }
        candidates.append(library.bundleURL)
        candidates.append(library.bundleURL.deletingLastPathComponent())
        if let executable = Bundle.main.executableURL { candidates.append(executable.deletingLastPathComponent()) }
        for base in candidates {
            for folder in [
                base.appendingPathComponent(bundleName).appendingPathComponent("Fonts"),
                base.appendingPathComponent(bundleName).appendingPathComponent("Contents/Resources/Fonts"),
            ] {
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    return folder
                }
            }
        }
        return nil
    }

    private static func fileDescriptor(_ stem: String) -> CTFontDescriptor? {
        guard let folder = fontsFolder else { return nil }
        let url = folder.appendingPathComponent(stem + ".woff2")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor]
        return descriptors?.first
    }

    static func descriptor(for face: RoachBundledFace, italic: Bool) -> CTFontDescriptor? {
        let key = "\(face.rawValue)|\(italic)"
        cache.lock.lock()
        if let known = cache.descriptors[key] {
            cache.lock.unlock()
            return known
        }
        cache.lock.unlock()

        let stems = face.fileStem(italic: italic)
        guard let latin = fileDescriptor(stems.latin) else { return nil }
        var result = latin
        if let extended = fileDescriptor(stems.latinExt) {
            result = CTFontDescriptorCreateCopyWithAttributes(
                latin,
                [kCTFontCascadeListAttribute: [extended]] as CFDictionary
            )
        }
        cache.lock.lock()
        cache.descriptors[key] = result
        cache.lock.unlock()
        return result
    }

    public static func ctFont(
        _ face: RoachBundledFace,
        size: CGFloat,
        weight: Double,
        width: Double? = nil,
        italic: Bool = false
    ) -> CTFont? {
        let clampedWeight = min(max(weight, face.weightRange.lowerBound), face.weightRange.upperBound)
        let clampedWidth = face.hasWidthAxis ? min(max(width ?? 100, 50), 150) : nil
        let key = "\(face.rawValue)|\(italic)|\(size)|\(clampedWeight)|\(clampedWidth ?? 0)"
        cache.lock.lock()
        if let known = cache.fonts[key] {
            cache.lock.unlock()
            return known
        }
        cache.lock.unlock()

        guard let base = descriptor(for: face, italic: italic) else { return nil }
        var variation: [NSNumber: NSNumber] = [weightAxis: NSNumber(value: clampedWeight)]
        if let clampedWidth { variation[widthAxis] = NSNumber(value: clampedWidth) }
        let varied = CTFontDescriptorCreateCopyWithAttributes(
            base,
            [kCTFontVariationAttribute: variation] as CFDictionary
        )
        let font = CTFontCreateWithFontDescriptor(varied, size, nil)
        cache.lock.lock()
        cache.fonts[key] = font
        cache.lock.unlock()
        return font
    }

    public static func numericWeight(_ weight: Font.Weight) -> Double {
        switch weight {
        case .ultraLight: return 200
        case .thin: return 100
        case .light: return 300
        case .medium: return 500
        case .semibold: return 600
        case .bold: return 700
        case .heavy: return 800
        case .black: return 900
        default: return 400
        }
    }

    public static func numericWeight(_ weight: NSFont.Weight) -> Double {
        switch weight {
        case .ultraLight: return 200
        case .thin: return 100
        case .light: return 300
        case .medium: return 500
        case .semibold: return 600
        case .bold: return 700
        case .heavy: return 800
        case .black: return 900
        default: return 400
        }
    }
}
