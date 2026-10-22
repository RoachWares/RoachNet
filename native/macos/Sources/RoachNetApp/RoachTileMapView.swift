import RoachNetDesign
import SwiftUI

enum RoachMapPaint: Int, CaseIterable {
    case earth, landcoverForest, landcoverGrass, landcoverIce, landcoverUrban
    case park, industrial, institution, airport, sand
    case water, waterLine
    case building
    case rail, path, minorRoad, mediumRoad, majorRoad, highway
    case boundaryRegion, boundaryCountry

    var color: Color {
        switch self {
        case .earth: return Color(red: 0.090, green: 0.098, blue: 0.129)
        case .landcoverForest: return Color(red: 0.055, green: 0.110, blue: 0.086)
        case .landcoverGrass: return Color(red: 0.067, green: 0.098, blue: 0.082)
        case .landcoverIce: return Color(red: 0.115, green: 0.130, blue: 0.165)
        case .landcoverUrban: return Color(red: 0.082, green: 0.086, blue: 0.114)
        case .park: return Color(red: 0.063, green: 0.133, blue: 0.098)
        case .industrial: return Color(red: 0.094, green: 0.086, blue: 0.114)
        case .institution: return Color(red: 0.106, green: 0.086, blue: 0.133)
        case .airport: return Color(red: 0.090, green: 0.098, blue: 0.125)
        case .sand: return Color(red: 0.118, green: 0.110, blue: 0.090)
        case .water: return Color(red: 0.035, green: 0.082, blue: 0.157)
        case .waterLine: return Color(red: 0.055, green: 0.157, blue: 0.267)
        case .building: return Color(red: 0.135, green: 0.140, blue: 0.188)
        case .rail: return Color(red: 0.235, green: 0.239, blue: 0.302)
        case .path: return Color(red: 0.200, green: 0.208, blue: 0.255)
        case .minorRoad: return Color(red: 0.235, green: 0.243, blue: 0.298)
        case .mediumRoad: return Color(red: 0.322, green: 0.329, blue: 0.400)
        case .majorRoad: return Color(red: 0.443, green: 0.451, blue: 0.533)
        case .highway: return Color(red: 0.690, green: 0.424, blue: 0.941)
        case .boundaryRegion: return Color(red: 0.290, green: 0.271, blue: 0.392)
        case .boundaryCountry: return Color(red: 0.471, green: 0.396, blue: 0.659)
        }
    }

    var isLine: Bool { rawValue >= RoachMapPaint.waterLine.rawValue && self != .building }

    func width(at zoom: Double) -> CGFloat {
        let growth = CGFloat(min(max((zoom - 5) / 7, 0.35), 2.4))
        switch self {
        case .highway: return 2.0 * growth
        case .majorRoad: return 1.5 * growth
        case .mediumRoad: return 1.1 * growth
        case .minorRoad: return 0.8 * growth
        case .path, .rail: return 0.6 * growth
        case .waterLine: return 0.9 * growth
        case .boundaryCountry: return 1.3
        case .boundaryRegion: return 0.8
        default: return 1
        }
    }

    var dash: [CGFloat] {
        switch self {
        case .boundaryRegion: return [5, 3]
        case .rail: return [3, 3]
        case .path: return [2, 2]
        default: return []
        }
    }

    static func classify(layer: String, _ feature: RoachMVTFeature) -> RoachMapPaint? {
        let kind = feature.properties["kind"]?.string ?? feature.properties["pmap:kind"]?.string ?? ""
        switch layer {
        case "earth": return feature.kind == .polygon ? .earth : nil
        case "water": return feature.kind == .polygon ? .water : (feature.kind == .line ? .waterLine : nil)
        case "landcover":
            switch kind {
            case "forest", "wood": return .landcoverForest
            case "grassland", "farmland", "scrub": return .landcoverGrass
            case "glacier": return .landcoverIce
            case "urban_area": return .landcoverUrban
            case "barren": return .sand
            default: return nil
            }
        case "landuse":
            guard feature.kind == .polygon else { return nil }
            switch kind {
            case "park", "nature_reserve", "forest", "wood", "golf_course", "garden", "grass", "national_park",
                "protected_area", "recreation_ground", "cemetery", "playground", "pitch":
                return .park
            case "industrial", "military", "railway", "quarry", "landfill": return .industrial
            case "hospital", "school", "university", "college": return .institution
            case "aerodrome", "airport", "runway", "taxiway", "apron": return .airport
            case "beach", "sand": return .sand
            default: return nil
            }
        case "buildings": return feature.kind == .polygon ? .building : nil
        case "roads":
            guard feature.kind == .line else { return nil }
            switch kind {
            case "highway": return .highway
            case "major_road": return .majorRoad
            case "medium_road": return .mediumRoad
            case "minor_road": return .minorRoad
            case "path": return .path
            case "rail": return .rail
            default: return nil
            }
        case "transit": return kind == "rail" && feature.kind == .line ? .rail : nil
        case "boundaries":
            guard feature.kind == .line else { return nil }
            let level = feature.properties["kind_detail"]?.number ?? feature.properties["admin_level"]?.number ?? 4
            return kind == "country" || level <= 2 ? .boundaryCountry : .boundaryRegion
        default: return nil
        }
    }
}

struct RoachMapLabel {
    var text: String
    var point: CGPoint
    var tier: Int
    var rank: Double

    var fontSize: CGFloat { [13, 11.5, 12.5, 11, 10][min(tier, 4)] }
    var weight: Font.Weight { tier <= 2 ? .semibold : .medium }
    var color: Color {
        tier == 0
            ? Color.white.opacity(0.78)
            : tier == 1
                ? Color(red: 0.70, green: 0.62, blue: 0.86)
                : tier == 4 ? Color.white.opacity(0.52) : Color.white.opacity(0.86)
    }
}

struct RoachRenderedTile {
    var paths: [RoachMapPaint: Path] = [:]
    var labels: [RoachMapLabel] = []
    var isEmpty: Bool { paths.isEmpty && labels.isEmpty }

    static let empty = RoachRenderedTile()

    static func build(_ layers: [RoachMVTLayer], zoom: Int) -> RoachRenderedTile {
        var tile = RoachRenderedTile()
        for layer in layers {
            let scale = 1 / layer.extent
            if layer.name == "places" {
                for feature in layer.features where feature.kind == .point {
                    guard let name = feature.properties["name:en"]?.string ?? feature.properties["name"]?.string,
                        !name.isEmpty, let point = feature.geometry.first?.first
                    else { continue }
                    let kind = feature.properties["kind"]?.string ?? feature.properties["pmap:kind"]?.string ?? ""
                    let tier: Int
                    switch kind {
                    case "country": tier = 0
                    case "region": tier = 1
                    case "locality":
                        let population = feature.properties["population_rank"]?.number ?? 0
                        tier = population >= 10 ? 2 : 3
                    case "neighbourhood", "macrohood": tier = 4
                    default: continue
                    }
                    if tier == 4 && zoom < 13 { continue }
                    let rank =
                        feature.properties["population_rank"]?.number ?? feature.properties["sort_key"].map {
                            -($0.number ?? 0)
                        } ?? 0
                    tile.labels.append(
                        RoachMapLabel(
                            text: name, point: CGPoint(x: point.x * scale, y: point.y * scale), tier: tier, rank: rank))
                }
                continue
            }
            for feature in layer.features {
                guard let paint = RoachMapPaint.classify(layer: layer.name, feature) else { continue }
                var path = tile.paths[paint] ?? Path()
                for part in feature.geometry where part.count > 1 {
                    path.move(to: CGPoint(x: part[0].x * scale, y: part[0].y * scale))
                    for point in part.dropFirst() { path.addLine(to: CGPoint(x: point.x * scale, y: point.y * scale)) }
                    if !paint.isLine { path.closeSubpath() }
                }
                tile.paths[paint] = path
            }
        }
        return tile
    }
}

@MainActor
final class RoachTileStore: ObservableObject {
    struct Key: Hashable {
        let archive: Int
        let z: Int
        let x: Int
        let y: Int
    }

    @Published private(set) var version = 0
    @Published private(set) var problem: String?
    private(set) var archives: [RoachPMTilesArchive] = []
    private var paths: [String] = []
    private var cache: [Key: RoachRenderedTile] = [:]
    private var order: [Key] = []
    private var inflight: Set<Key> = []
    private(set) var generation = 0
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .userInitiated
        return queue
    }()

    func open(_ files: [String]) {
        guard files != paths else { return }
        paths = files
        generation += 1
        queue.cancelAllOperations()
        cache.removeAll()
        order.removeAll()
        inflight.removeAll()
        var opened: [RoachPMTilesArchive] = []
        var failures: [String] = []
        for file in files {
            do {
                let archive = try RoachPMTilesArchive(path: file)
                if archive.isVector {
                    opened.append(archive)
                } else {
                    failures.append("\(archive.name) isn't a vector pack, so Maps can't draw it")
                }
            } catch {
                failures.append("\(URL(fileURLWithPath: file).lastPathComponent): \(error.localizedDescription)")
            }
        }
        archives = opened.sorted { $0.header.maxZoom < $1.header.maxZoom }
        problem = failures.isEmpty ? nil : failures.joined(separator: " · ")
        version += 1
    }

    func focusBounds(_ focus: [String]) -> CGRect? {
        let focused = archives.filter { focus.contains($0.path) && $0.header.maxZoom > 8 }
        let regional = focused.isEmpty ? archives.filter { $0.header.maxZoom > 8 } : focused
        let pool = regional.isEmpty ? archives : regional
        guard !pool.isEmpty else { return nil }
        let boxes = pool.map { archive -> CGRect in
            var minLon = archive.header.minLon
            var maxLon = archive.header.maxLon
            if regional.count > 0, maxLon - minLon > 300 {
                minLon = -180
                maxLon = -129
            }
            let topLeft = RoachMercator.project(lon: minLon, lat: archive.header.maxLat)
            let bottomRight = RoachMercator.project(lon: maxLon, lat: archive.header.minLat)
            return CGRect(
                x: topLeft.x, y: topLeft.y, width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
        }
        return boxes.reduce(CGRect.null) { $0.union($1) }
    }

    var maxZoom: Int { archives.map(\.header.maxZoom).max() ?? 15 }

    func tile(_ key: Key) -> RoachRenderedTile? {
        if let tile = cache[key] { return tile }
        guard !inflight.contains(key), key.archive < archives.count else { return nil }
        inflight.insert(key)
        let archive = archives[key.archive]
        let generation = self.generation
        queue.addOperation { [weak self] in
            var rendered = RoachRenderedTile.empty
            if let data = try? archive.tile(z: key.z, x: key.x, y: key.y), let layers = try? RoachMVT.decode(data) {
                rendered = RoachRenderedTile.build(layers, zoom: key.z)
            }
            Task { @MainActor [weak self] in self?.store(key, rendered, generation: generation) }
        }
        return nil
    }

    func store(_ key: Key, _ tile: RoachRenderedTile, generation: Int) {
        guard generation == self.generation else { return }
        inflight.remove(key)
        guard key.archive < archives.count else { return }
        cache[key] = tile
        order.append(key)
        if order.count > 384 { cache.removeValue(forKey: order.removeFirst()) }
        version += 1
    }
}

struct RoachTileMapView: View {
    let files: [String]
    var focusFiles: [String] = []
    let accent: Color
    let latestFix: RoachPhoneLocationFix?
    let routeSamples: [RoachPhoneLocationFix]

    @StateObject private var store = RoachTileStore()
    @State private var center = CGPoint(x: 0.5, y: 0.5)
    @State private var zoom: Double = 2
    @State private var dragOrigin: CGPoint?
    @State private var pinchOrigin: Double?
    @State private var fitted = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Canvas(rendersAsynchronously: false) { context, size in
                    draw(&context, size: size)
                }
                .background(Color(red: 0.035, green: 0.082, blue: 0.157))
                .gesture(panGesture(size: proxy.size))
                .simultaneousGesture(pinchGesture)
                .onTapGesture(count: 2) { setZoom(zoom + 1) }

                overlay(size: proxy.size)
            }
            .onAppear {
                store.open(files)
                fit(size: proxy.size)
            }
            .onChange(of: files) { _, newFiles in
                store.open(newFiles)
                fitted = false
                fit(size: proxy.size)
            }
            .onChange(of: focusFiles) { _, _ in
                withAnimation(.easeOut(duration: 0.3)) { fit(size: proxy.size) }
            }
            .onChange(of: proxy.size) { _, newSize in if !fitted { fit(size: newSize) } }
        }
        .clipShape(RoundedRectangle(cornerRadius: RoachMetrics.radius(26), style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RoachMetrics.radius(26), style: .continuous).stroke(
                accent.opacity(0.28), lineWidth: RoachMetrics.line(1))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Offline map")
    }

    private func worldSize(_ zoom: Double) -> Double { 256 * pow(2, zoom) }

    private func screen(_ world: CGPoint, size: CGSize) -> CGPoint {
        let scale = worldSize(zoom)
        return CGPoint(
            x: (world.x - center.x) * scale + size.width / 2, y: (world.y - center.y) * scale + size.height / 2)
    }

    private func setZoom(_ value: Double) {
        withAnimation(.easeOut(duration: 0.18)) { zoom = min(max(value, 0), Double(store.maxZoom) + 2.5) }
    }

    private func fit(size: CGSize) {
        if let raw = ProcessInfo.processInfo.environment["ROACHNET_MAP_INITIAL_VIEW"] {
            let parts = raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 3 {
                center = RoachMercator.project(lon: parts[1], lat: parts[0])
                zoom = parts[2]
                fitted = true
                return
            }
        }
        guard size.width > 10, size.height > 10, let bounds = store.focusBounds(focusFiles), !bounds.isNull else {
            return
        }
        center = CGPoint(x: bounds.midX, y: bounds.midY)
        let span = max(bounds.width, 1e-9)
        let height = max(bounds.height, 1e-9)
        let fitZoom = log2(min(size.width / (span * 256), size.height / (height * 256)) * 0.92)
        zoom = min(max(fitZoom, 0), Double(store.maxZoom))
        fitted = true
    }

    private func panGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let origin = dragOrigin ?? center
                if dragOrigin == nil { dragOrigin = center }
                let scale = worldSize(zoom)
                center = CGPoint(
                    x: min(max(origin.x - value.translation.width / scale, 0), 1),
                    y: min(max(origin.y - value.translation.height / scale, 0), 1))
            }
            .onEnded { _ in dragOrigin = nil }
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let origin = pinchOrigin ?? zoom
                if pinchOrigin == nil { pinchOrigin = zoom }
                zoom = min(max(origin + log2(max(value.magnification, 0.01)), 0), Double(store.maxZoom) + 2.5)
            }
            .onEnded { _ in pinchOrigin = nil }
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        _ = store.version
        let scale = worldSize(zoom)
        let half = CGSize(width: size.width / 2 / scale, height: size.height / 2 / scale)
        let visible = CGRect(
            x: center.x - half.width, y: center.y - half.height, width: half.width * 2, height: half.height * 2)
        var labels: [(RoachMapLabel, CGPoint)] = []

        for (index, archive) in store.archives.enumerated() {
            let header = archive.header
            if header.maxLon - header.minLon < 300 {
                let topLeft = RoachMercator.project(lon: header.minLon, lat: header.maxLat)
                let bottomRight = RoachMercator.project(lon: header.maxLon, lat: header.minLat)
                if !visible.intersects(
                    CGRect(
                        x: topLeft.x, y: topLeft.y, width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
                ) {
                    continue
                }
            }
            let z = min(max(Int(zoom.rounded(.down)), archive.header.minZoom), archive.header.maxZoom)
            let n = 1 << z
            let tileWorld = 1 / Double(n)
            let tileScreen = tileWorld * scale
            let minX = max(0, Int(floor(visible.minX * Double(n))))
            let maxX = min(n - 1, Int(floor(visible.maxX * Double(n))))
            let minY = max(0, Int(floor(visible.minY * Double(n))))
            let maxY = min(n - 1, Int(floor(visible.maxY * Double(n))))
            guard minX <= maxX, minY <= maxY, (maxX - minX + 1) * (maxY - minY + 1) <= 400 else { continue }
            for x in minX...maxX {
                for y in minY...maxY {
                    let key = RoachTileStore.Key(archive: index, z: z, x: x, y: y)
                    guard let tile = store.tile(key), !tile.isEmpty else { continue }
                    let origin = screen(CGPoint(x: Double(x) * tileWorld, y: Double(y) * tileWorld), size: size)
                    var layer = context
                    layer.translateBy(x: origin.x - 0.5, y: origin.y - 0.5)
                    layer.scaleBy(x: tileScreen + 1, y: tileScreen + 1)
                    layer.clip(to: Path(CGRect(x: 0, y: 0, width: 1, height: 1)))
                    for paint in RoachMapPaint.allCases {
                        guard let path = tile.paths[paint] else { continue }
                        if paint == .building && zoom < 13.5 { continue }
                        if paint.isLine {
                            let width = paint.width(at: zoom) / (tileScreen + 1)
                            layer.stroke(
                                path, with: .color(paint.color),
                                style: StrokeStyle(
                                    lineWidth: width, lineCap: .round, lineJoin: .round,
                                    dash: paint.dash.map { $0 / (tileScreen + 1) }))
                        } else {
                            layer.fill(path, with: .color(paint.color))
                        }
                    }
                    for label in tile.labels {
                        labels.append(
                            (
                                label,
                                CGPoint(
                                    x: origin.x + label.point.x * tileScreen, y: origin.y + label.point.y * tileScreen)
                            ))
                    }
                }
            }
        }

        drawRoute(&context, size: size)
        drawLabels(&context, labels, size: size)
        drawFix(&context, size: size)
    }

    private func drawLabels(_ context: inout GraphicsContext, _ labels: [(RoachMapLabel, CGPoint)], size: CGSize) {
        var placed: [CGRect] = []
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: -40, dy: -20)
        let sorted = labels.sorted { ($0.0.tier, -$0.0.rank) < ($1.0.tier, -$1.0.rank) }
        var seen: Set<String> = []
        for (label, point) in sorted.prefix(400) where bounds.contains(point) {
            if label.tier == 0 && zoom > 7 { continue }
            if label.tier == 1 && zoom > 9 { continue }
            let key = "\(label.text)|\(Int(point.x / 40))|\(Int(point.y / 40))"
            if seen.contains(key) { continue }
            let width = CGFloat(label.text.count) * label.fontSize * 0.56 + 8
            let rect = CGRect(
                x: point.x - width / 2, y: point.y - label.fontSize, width: width, height: label.fontSize * 1.6)
            if placed.contains(where: { $0.intersects(rect) }) { continue }
            placed.append(rect)
            seen.insert(key)
            let text = Text(label.tier == 0 ? label.text.uppercased() : label.text)
                .font(.roach(size: label.fontSize, weight: label.weight, design: .default))
                .foregroundColor(label.color)
            context.draw(
                Text(label.tier == 0 ? label.text.uppercased() : label.text)
                    .font(.roach(size: label.fontSize, weight: label.weight))
                    .foregroundColor(.black.opacity(0.7)), at: CGPoint(x: point.x + 0.8, y: point.y + 0.8))
            context.draw(text, at: point)
        }
    }

    private func drawRoute(_ context: inout GraphicsContext, size: CGSize) {
        let points = routeSamples.map { screen(RoachMercator.project(lon: $0.longitude, lat: $0.latitude), size: size) }
        guard points.count > 1 else { return }
        var path = Path()
        path.addLines(points)
        context.stroke(
            path, with: .color(RoachPalette.green.opacity(0.85)),
            style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
    }

    private func drawFix(_ context: inout GraphicsContext, size: CGSize) {
        guard let fix = latestFix else { return }
        let point = screen(RoachMercator.project(lon: fix.longitude, lat: fix.latitude), size: size)
        context.fill(
            Path(ellipseIn: CGRect(x: point.x - 11, y: point.y - 11, width: 22, height: 22)),
            with: .color(RoachPalette.green.opacity(0.22)))
        context.fill(
            Path(ellipseIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)),
            with: .color(RoachPalette.green))
        context.stroke(
            Path(ellipseIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)),
            with: .color(.black.opacity(0.6)), lineWidth: RoachMetrics.line(1))
    }

    private func overlay(size: CGSize) -> some View {
        VStack(alignment: .leading) {
            HStack(alignment: .top) {
                if let problem = store.problem {
                    Text(problem)
                        .font(.roach(size: 11, weight: .semibold))
                        .foregroundStyle(RoachPalette.warning)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(RoachPalette.panelRaised.opacity(0.9)))
                }
                Spacer()
                VStack(spacing: 6) {
                    mapButton("plus", "Zoom in") { setZoom(zoom + 1) }
                    mapButton("minus", "Zoom out") { setZoom(zoom - 1) }
                    mapButton("scope", "Zoom to the pack") {
                        withAnimation(.easeOut(duration: 0.25)) { fit(size: size) }
                    }
                    if let fix = latestFix {
                        mapButton("location.fill", "Center on the phone") {
                            withAnimation(.easeOut(duration: 0.25)) {
                                center = RoachMercator.project(lon: fix.longitude, lat: fix.latitude)
                                zoom = max(zoom, 13)
                            }
                        }
                    }
                }
            }
            Spacer()
            HStack {
                Text(coordinateLabel)
                    .font(.roach(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(RoachPalette.text.opacity(0.85))
                Spacer()
                Text("© OpenStreetMap contributors · Protomaps")
                    .font(.roach(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(RoachPalette.muted.opacity(0.85))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: RoachMetrics.radius(10), style: .continuous).fill(
                    Color.black.opacity(0.45)))
        }
        .padding(12)
    }

    private var coordinateLabel: String {
        let location = RoachMercator.unproject(center)
        return String(format: "%.4f, %.4f · z%.1f", location.lat, location.lon, zoom)
    }

    private func mapButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.roach(size: 13, weight: .bold))
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: RoachMetrics.radius(9), style: .continuous).fill(
                        RoachPalette.panelRaised.opacity(0.92))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: RoachMetrics.radius(9), style: .continuous).stroke(
                        RoachPalette.borderStrong, lineWidth: RoachMetrics.line(1)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(RoachPalette.text)
        .help(label)
        .accessibilityLabel(label)
    }
}
