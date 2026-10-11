@preconcurrency import CoreBluetooth
import Foundation
import SwiftUI
import RoachNetDesign

enum RoachMapViewerMode: String, CaseIterable, Identifiable, Hashable {
    case drive = "Drive"
    case terrain = "Terrain"
    case vault = "Vault"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .drive:
            return "point.topleft.down.curvedto.point.bottomright.up.fill"
        case .terrain:
            return "map.fill"
        case .vault:
            return "archivebox.fill"
        }
    }

    var accent: Color {
        switch self {
        case .drive:
            return RoachPalette.green
        case .terrain:
            return RoachPalette.cyan
        case .vault:
            return RoachPalette.magenta
        }
    }
}

struct RoachMapCollectionDisplay: Identifiable, Hashable {
    let slug: String
    let name: String
    let detail: String
    let installedCount: Int
    let totalCount: Int
    let resourceCount: Int
    let resourceTitles: [String]
    /// Every installed `.pmtiles` file to draw, world overview first. Empty draws the placeholder atlas.
    var packFiles: [String] = []
    /// This collection's own installed packs, which the map frames when it is selected.
    var focusFiles: [String] = []

    var id: String { slug }
    var isReady: Bool { totalCount > 0 && installedCount >= totalCount }
    var readinessFraction: Double {
        guard totalCount > 0 else { return 0 }
        return min(1, max(0, Double(installedCount) / Double(totalCount)))
    }

    var readinessLabel: String {
        totalCount > 0 ? "\(installedCount) / \(totalCount)" : "\(installedCount)"
    }

    var stateLabel: String {
        isReady ? "Ready" : "Needs pack"
    }
}

enum RoachPhoneLocationPayloadError: LocalizedError, Equatable {
    case empty
    case payloadTooLarge
    case unsupportedFormat
    case missingCoordinate
    case invalidCoordinate

    var errorDescription: String? {
        switch self {
        case .empty:
            return "GPS packet is empty."
        case .payloadTooLarge:
            return "GPS packet is too large for the RoachPhone bridge."
        case .unsupportedFormat:
            return "GPS packet must be JSON or lat,lon CSV."
        case .missingCoordinate:
            return "GPS packet is missing latitude or longitude."
        case .invalidCoordinate:
            return "GPS packet contains an invalid coordinate."
        }
    }
}

struct RoachPhoneLocationFix: Codable, Hashable, Identifiable {
    let latitude: Double
    let longitude: Double
    let accuracyMeters: Double?
    let speedMetersPerSecond: Double?
    let courseDegrees: Double?
    let altitudeMeters: Double?
    let timestamp: Date
    let sourceName: String

    var id: String {
        "\(sourceName)-\(timestamp.timeIntervalSince1970)-\(latitude)-\(longitude)"
    }

    var coordinateLabel: String {
        String(format: "%.5f, %.5f", latitude, longitude)
    }

    static let samplePayload = """
    {"lat":39.76862,"lon":-86.15823,"accuracy":7.5,"speed":12.4,"course":244,"altitude":218,"source":"RoachPhone"}
    """
}

enum RoachPhoneLocationPayloadParser {
    static let maxPayloadCharacters = 4096

    static func parse(_ rawPayload: String, now: Date = Date()) throws -> RoachPhoneLocationFix {
        let trimmed = rawPayload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RoachPhoneLocationPayloadError.empty }
        guard trimmed.count <= maxPayloadCharacters else { throw RoachPhoneLocationPayloadError.payloadTooLarge }

        if trimmed.hasPrefix("{") {
            guard let data = trimmed.data(using: .utf8) else {
                throw RoachPhoneLocationPayloadError.unsupportedFormat
            }

            let envelope = try JSONDecoder().decode(RoachPhoneLocationPayloadEnvelope.self, from: data)
            return try makeFix(
                latitude: envelope.latitude,
                longitude: envelope.longitude,
                accuracyMeters: envelope.accuracyMeters,
                speedMetersPerSecond: envelope.speedMetersPerSecond,
                courseDegrees: envelope.courseDegrees,
                altitudeMeters: envelope.altitudeMeters,
                timestamp: envelope.timestamp ?? now,
                sourceName: envelope.sourceName ?? "RoachPhone"
            )
        }

        let fields = trimmed
            .replacingOccurrences(of: "\n", with: ",")
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

        guard fields.count >= 2 else { throw RoachPhoneLocationPayloadError.unsupportedFormat }
        guard let latitude = Double(fields[0]), let longitude = Double(fields[1]) else {
            throw RoachPhoneLocationPayloadError.missingCoordinate
        }

        return try makeFix(
            latitude: latitude,
            longitude: longitude,
            accuracyMeters: doubleValue(fields, at: 2),
            speedMetersPerSecond: doubleValue(fields, at: 3),
            courseDegrees: doubleValue(fields, at: 4),
            altitudeMeters: doubleValue(fields, at: 5),
            timestamp: dateValue(fields, at: 6) ?? now,
            sourceName: stringValue(fields, at: 7) ?? "RoachPhone"
        )
    }

    private static func makeFix(
        latitude: Double?,
        longitude: Double?,
        accuracyMeters: Double?,
        speedMetersPerSecond: Double?,
        courseDegrees: Double?,
        altitudeMeters: Double?,
        timestamp: Date,
        sourceName: String
    ) throws -> RoachPhoneLocationFix {
        guard let latitude, let longitude else {
            throw RoachPhoneLocationPayloadError.missingCoordinate
        }
        guard (-90...90).contains(latitude), (-180...180).contains(longitude) else {
            throw RoachPhoneLocationPayloadError.invalidCoordinate
        }

        return RoachPhoneLocationFix(
            latitude: latitude,
            longitude: longitude,
            accuracyMeters: accuracyMeters,
            speedMetersPerSecond: speedMetersPerSecond,
            courseDegrees: courseDegrees.map { normalizedCourse($0) },
            altitudeMeters: altitudeMeters,
            timestamp: timestamp,
            sourceName: sourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "RoachPhone" : sourceName
        )
    }

    private static func doubleValue(_ fields: [String], at index: Int) -> Double? {
        guard fields.indices.contains(index), !fields[index].isEmpty else { return nil }
        return Double(fields[index])
    }

    private static func stringValue(_ fields: [String], at index: Int) -> String? {
        guard fields.indices.contains(index) else { return nil }
        let value = fields[index].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func dateValue(_ fields: [String], at index: Int) -> Date? {
        guard let value = stringValue(fields, at: index) else { return nil }
        return parseDate(value)
    }

    private static func normalizedCourse(_ value: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: 360)
        return remainder < 0 ? remainder + 360 : remainder
    }

    fileprivate static func parseDate(_ value: String) -> Date? {
        if let seconds = Double(value) {
            return Date(timeIntervalSince1970: seconds)
        }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }

        return ISO8601DateFormatter().date(from: value)
    }
}

private struct RoachPhoneLocationPayloadEnvelope: Decodable {
    let latitude: Double?
    let longitude: Double?
    let accuracyMeters: Double?
    let speedMetersPerSecond: Double?
    let courseDegrees: Double?
    let altitudeMeters: Double?
    let timestamp: Date?
    let sourceName: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: RoachDynamicCodingKey.self)
        latitude = Self.decodeDouble(container, keys: ["latitude", "lat"])
        longitude = Self.decodeDouble(container, keys: ["longitude", "lon", "lng"])
        accuracyMeters = Self.decodeDouble(container, keys: ["accuracyMeters", "accuracy", "horizontalAccuracy"])
        speedMetersPerSecond = Self.decodeDouble(container, keys: ["speedMetersPerSecond", "speed", "speedMps"])
        courseDegrees = Self.decodeDouble(container, keys: ["courseDegrees", "course", "heading"])
        altitudeMeters = Self.decodeDouble(container, keys: ["altitudeMeters", "altitude", "alt"])
        sourceName = Self.decodeString(container, keys: ["sourceName", "source", "device", "name"])

        if let rawTimestamp = Self.decodeString(container, keys: ["timestamp", "time", "createdAt"]) {
            timestamp = RoachPhoneLocationPayloadParser.parseDate(rawTimestamp)
        } else if let seconds = Self.decodeDouble(container, keys: ["timestamp", "time", "createdAt"]) {
            timestamp = Date(timeIntervalSince1970: seconds)
        } else {
            timestamp = nil
        }
    }

    private static func decodeDouble(
        _ container: KeyedDecodingContainer<RoachDynamicCodingKey>,
        keys: [String]
    ) -> Double? {
        for key in keys {
            let codingKey = RoachDynamicCodingKey(stringValue: key)
            if let value = try? container.decode(Double.self, forKey: codingKey) {
                return value
            }
            if let stringValue = try? container.decode(String.self, forKey: codingKey),
               let value = Double(stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return value
            }
        }
        return nil
    }

    private static func decodeString(
        _ container: KeyedDecodingContainer<RoachDynamicCodingKey>,
        keys: [String]
    ) -> String? {
        for key in keys {
            let codingKey = RoachDynamicCodingKey(stringValue: key)
            if let value = try? container.decode(String.self, forKey: codingKey) {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }
}

private struct RoachDynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

struct RoachMapNavigationSnapshot: Equatable {
    static let liveFixInterval: TimeInterval = 20
    static let degradedAccuracyMeters = 75.0

    let latestFix: RoachPhoneLocationFix?
    let previousFix: RoachPhoneLocationFix?
    let now: Date

    var isLive: Bool {
        guard let latestFix else { return false }
        return abs(now.timeIntervalSince(latestFix.timestamp)) < Self.liveFixInterval
    }

    var reliabilityLabel: String {
        guard let latestFix else { return "Waiting" }
        if !isLive {
            return "Stale"
        }
        guard let accuracy = latestFix.accuracyMeters else {
            return "Unrated"
        }
        return accuracy <= Self.degradedAccuracyMeters ? "Good" : "Weak"
    }

    var reliabilityAccent: Color {
        switch reliabilityLabel {
        case "Good":
            return RoachPalette.green
        case "Weak", "Unrated":
            return RoachPalette.bronze
        default:
            return RoachPalette.warning
        }
    }

    var ageLabel: String {
        guard let latestFix else { return "No fix" }
        let seconds = max(0, Int(now.timeIntervalSince(latestFix.timestamp).rounded()))
        return seconds < 60 ? "\(seconds)s ago" : "\(seconds / 60)m ago"
    }

    var speedLabel: String {
        guard let metersPerSecond = latestFix?.speedMetersPerSecond else { return "Idle" }
        return String(format: "%.0f mph", metersPerSecond * 2.2369362921)
    }

    var headingLabel: String {
        guard let degrees = latestFix?.courseDegrees else { return "No heading" }
        return "\(Self.compassPoint(for: degrees)) \(Int(degrees.rounded()))°"
    }

    var accuracyLabel: String {
        guard let meters = latestFix?.accuracyMeters else { return "Unknown" }
        if meters >= 1609.344 {
            return String(format: "%.1f mi", meters / 1609.344)
        }
        return String(format: "%.0f m", meters)
    }

    var stepDistanceLabel: String {
        guard
            let previousFix,
            let latestFix,
            previousFix != latestFix
        else {
            return "0 ft"
        }
        let meters = Self.distanceMeters(from: previousFix, to: latestFix)
        return meters >= 1609.344
            ? String(format: "%.1f mi", meters / 1609.344)
            : String(format: "%.0f ft", meters * 3.280839895)
    }

    static func compassPoint(for degrees: Double) -> String {
        let normalized = degrees.truncatingRemainder(dividingBy: 360)
        let positive = normalized < 0 ? normalized + 360 : normalized
        let directions = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let index = Int((positive + 22.5) / 45.0) % directions.count
        return directions[index]
    }

    static func distanceMeters(from lhs: RoachPhoneLocationFix, to rhs: RoachPhoneLocationFix) -> Double {
        let earthRadiusMeters = 6_371_000.0
        let lat1 = lhs.latitude * .pi / 180
        let lat2 = rhs.latitude * .pi / 180
        let deltaLat = (rhs.latitude - lhs.latitude) * .pi / 180
        let deltaLon = (rhs.longitude - lhs.longitude) * .pi / 180
        let a = sin(deltaLat / 2) * sin(deltaLat / 2)
            + cos(lat1) * cos(lat2) * sin(deltaLon / 2) * sin(deltaLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return earthRadiusMeters * c
    }
}

enum RoachPhoneBridgeConnectionState: Equatable {
    case idle
    case waitingForBluetooth
    case unsupported
    case poweredOff
    case unauthorized
    case scanning
    case connecting(String)
    case listening(String)
    case disconnected(String)
    case failed(String)

    var label: String {
        switch self {
        case .idle:
            return "Idle"
        case .waitingForBluetooth:
            return "Bluetooth"
        case .unsupported:
            return "Unsupported"
        case .poweredOff:
            return "Off"
        case .unauthorized:
            return "Blocked"
        case .scanning:
            return "Scanning"
        case let .connecting(name):
            return "Pairing \(name)"
        case let .listening(name):
            return "Live \(name)"
        case .disconnected:
            return "Disconnected"
        case .failed:
            return "Needs retry"
        }
    }

    var detail: String {
        switch self {
        case .idle:
            return "Ready to scan for RoachPhone GPS."
        case .waitingForBluetooth:
            return "Waiting for Bluetooth state."
        case .unsupported:
            return "This Mac does not expose CoreBluetooth."
        case .poweredOff:
            return "Turn on Bluetooth to scan."
        case .unauthorized:
            return "Allow Bluetooth access for RoachNet."
        case .scanning:
            return "Looking for a RoachNet GPS beacon."
        case let .connecting(name):
            return "Connecting to \(name)."
        case let .listening(name):
            return "Receiving GPS packets from \(name)."
        case let .disconnected(name):
            return "\(name) disconnected."
        case let .failed(reason):
            return reason
        }
    }
}

struct RoachOpenMapSource: Identifiable, Hashable {
    let id: String
    let name: String
    let role: String
    let detail: String
    let status: String
    let accent: Color

    static let defaults: [RoachOpenMapSource] = [
        RoachOpenMapSource(
            id: "osm",
            name: "OpenStreetMap",
            role: "Base data",
            detail: "OSM extracts with attribution; avoids bulk scraping.",
            status: "ODbL",
            accent: RoachPalette.green
        ),
        RoachOpenMapSource(
            id: "openmaptiles",
            name: "OpenMapTiles",
            role: "Vector packs",
            detail: "Vector tiles and MBTiles.",
            status: "Vector",
            accent: RoachPalette.cyan
        ),
        RoachOpenMapSource(
            id: "osrm",
            name: "OSRM",
            role: "Driving routes",
            detail: "Routes and map matching.",
            status: "Routes",
            accent: RoachPalette.magenta
        ),
        RoachOpenMapSource(
            id: "valhalla",
            name: "Valhalla",
            role: "Offline routing",
            detail: "Local routing tiles.",
            status: "Tiles",
            accent: RoachPalette.bronze
        ),
    ]
}

struct RoachPhoneGPSDevice: Identifiable, Hashable {
    let id: UUID
    let name: String
    let rssi: Int
    let lastSeen: Date

    var signalLabel: String {
        "\(rssi) dBm"
    }
}

final class RoachPhoneLocationBridge: NSObject, ObservableObject {
    static let gpsServiceUUIDString = "E4B29778-2F25-4C70-9B4A-0F9D1D481105"
    static let gpsCharacteristicUUIDString = "E4B29779-2F25-4C70-9B4A-0F9D1D481105"
    private static var gpsServiceUUID: CBUUID { CBUUID(string: gpsServiceUUIDString) }
    private static var gpsCharacteristicUUID: CBUUID { CBUUID(string: gpsCharacteristicUUIDString) }

    @Published private(set) var connectionState: RoachPhoneBridgeConnectionState = .idle
    @Published private(set) var discoveredDevices: [RoachPhoneGPSDevice] = []
    @Published private(set) var latestFix: RoachPhoneLocationFix?
    @Published private(set) var routeSamples: [RoachPhoneLocationFix] = []
    @Published private(set) var lastPayloadError: String?

    private var centralManager: CBCentralManager?
    private var peripheralRegistry: [UUID: CBPeripheral] = [:]
    private var connectedPeripheral: CBPeripheral?

    var isScanning: Bool {
        if case .scanning = connectionState {
            return true
        }
        return false
    }

    var statusLabel: String {
        connectionState.label
    }

    func startScanning() {
        lastPayloadError = nil
        if centralManager == nil {
            connectionState = .waitingForBluetooth
            centralManager = CBCentralManager(delegate: self, queue: .main)
            return
        }
        scanIfReady()
    }

    func stopScanning() {
        centralManager?.stopScan()
        if isScanning {
            connectionState = .idle
        }
    }

    func connect(_ device: RoachPhoneGPSDevice) {
        guard let peripheral = peripheralRegistry[device.id], let centralManager else {
            connectionState = .failed("RoachNet lost that phone advertisement.")
            return
        }

        stopScanning()
        connectionState = .connecting(device.name)
        connectedPeripheral = peripheral
        peripheral.delegate = self
        centralManager.connect(peripheral, options: nil)
    }

    func disconnect() {
        guard let connectedPeripheral, let centralManager else {
            connectionState = .idle
            return
        }
        centralManager.cancelPeripheralConnection(connectedPeripheral)
    }

    func ingestManualPayload(_ payload: String) {
        do {
            let fix = try RoachPhoneLocationPayloadParser.parse(payload)
            apply(fix)
            connectionState = .listening(fix.sourceName)
            lastPayloadError = nil
        } catch {
            lastPayloadError = error.localizedDescription
            connectionState = .failed(error.localizedDescription)
        }
    }

    func useDemoFix() {
        let offset = Double(routeSamples.count % 9)
        let payload = """
        {"lat":\(39.76840 + offset * 0.00045),"lon":\(-86.15810 - offset * 0.00038),"accuracy":\(7 + offset),"speed":\(10.5 + offset * 0.9),"course":\(230 + offset * 4),"source":"RoachPhone Demo"}
        """
        ingestManualPayload(payload)
    }

    func resetRoute() {
        routeSamples = []
        latestFix = nil
        lastPayloadError = nil
        if case .failed = connectionState {
            connectionState = .idle
        }
    }

    private func scanIfReady() {
        guard let centralManager else { return }

        switch centralManager.state {
        case .poweredOn:
            discoveredDevices = []
            peripheralRegistry = [:]
            connectionState = .scanning
            centralManager.scanForPeripherals(
                withServices: [Self.gpsServiceUUID],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            )
        case .poweredOff:
            connectionState = .poweredOff
        case .unauthorized:
            connectionState = .unauthorized
        case .unsupported:
            connectionState = .unsupported
        case .resetting, .unknown:
            connectionState = .waitingForBluetooth
        @unknown default:
            connectionState = .failed("Unknown Bluetooth state.")
        }
    }

    private func apply(_ fix: RoachPhoneLocationFix) {
        latestFix = fix
        routeSamples.append(fix)
        if routeSamples.count > 120 {
            routeSamples.removeFirst(routeSamples.count - 120)
        }
    }

    private func name(for peripheral: CBPeripheral, advertisementData: [String: Any]? = nil) -> String {
        if let localName = advertisementData?[CBAdvertisementDataLocalNameKey] as? String, !localName.isEmpty {
            return localName
        }
        return peripheral.name?.isEmpty == false ? peripheral.name! : "RoachPhone"
    }
}

extension RoachPhoneLocationBridge: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        scanIfReady()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let device = RoachPhoneGPSDevice(
            id: peripheral.identifier,
            name: name(for: peripheral, advertisementData: advertisementData),
            rssi: RSSI.intValue,
            lastSeen: Date()
        )
        peripheralRegistry[device.id] = peripheral

        discoveredDevices.removeAll { $0.id == device.id }
        discoveredDevices.append(device)
        discoveredDevices.sort { lhs, rhs in
            if lhs.rssi != rhs.rssi {
                return lhs.rssi > rhs.rssi
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectedPeripheral = peripheral
        peripheral.delegate = self
        connectionState = .listening(name(for: peripheral))
        peripheral.discoverServices([Self.gpsServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectionState = .failed(error?.localizedDescription ?? "RoachPhone connection failed.")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connectedPeripheral = nil
        connectionState = error.map { .failed($0.localizedDescription) } ?? .disconnected(name(for: peripheral))
    }
}

extension RoachPhoneLocationBridge: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            connectionState = .failed(error.localizedDescription)
            return
        }

        for service in peripheral.services ?? [] where service.uuid == Self.gpsServiceUUID {
            peripheral.discoverCharacteristics([Self.gpsCharacteristicUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            connectionState = .failed(error.localizedDescription)
            return
        }

        guard let characteristic = service.characteristics?.first(where: { $0.uuid == Self.gpsCharacteristicUUID }) else {
            connectionState = .failed("RoachPhone GPS characteristic was not found.")
            return
        }

        if characteristic.properties.contains(.notify) {
            peripheral.setNotifyValue(true, for: characteristic)
        }
        if characteristic.properties.contains(.read) {
            peripheral.readValue(for: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            lastPayloadError = error.localizedDescription
            return
        }

        guard
            characteristic.uuid == Self.gpsCharacteristicUUID,
            let data = characteristic.value,
            let payload = String(data: data, encoding: .utf8)
        else {
            return
        }

        ingestManualPayload(payload)
    }
}

struct RoachNativeMapViewer: View {
    let collection: RoachMapCollectionDisplay?
    let mode: RoachMapViewerMode
    @Binding var zoomLevel: Double
    let latestFix: RoachPhoneLocationFix?
    let routeSamples: [RoachPhoneLocationFix]
    let installBusy: Bool
    let onInstallSelected: () -> Void
    let onOpenWebAtlas: () -> Void
    @State private var appeared = false
    @State private var controlsHovered = false

    private var snapshot: RoachMapNavigationSnapshot {
        RoachMapNavigationSnapshot(
            latestFix: latestFix,
            previousFix: routeSamples.dropLast().last,
            now: Date()
        )
    }

    var body: some View {
        RoachSpotlightPanel(accent: mode.accent) {
            VStack(alignment: .leading, spacing: 18) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 18) {
                        mapCanvas
                            .id(mode)
                            .transition(.opacity.combined(with: .scale(scale: 0.985)))
                            .frame(minWidth: 420, minHeight: 360)
                        mapControls
                            .frame(minWidth: 300, idealWidth: 340, maxWidth: 380)
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        mapCanvas
                            .id(mode)
                            .transition(.opacity.combined(with: .scale(scale: 0.985)))
                            .frame(minHeight: 340)
                        mapControls
                    }
                }
            }
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 8)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: mode)
        .onAppear {
            withAnimation(.spring(response: 0.36, dampingFraction: 0.88)) {
                appeared = true
            }
        }
    }

    private var hasPacks: Bool { !(collection?.packFiles.isEmpty ?? true) }

    @ViewBuilder
    private var mapCanvas: some View {
        if let files = collection?.packFiles, !files.isEmpty {
            RoachTileMapView(files: files, focusFiles: collection?.focusFiles ?? [], accent: mode.accent, latestFix: latestFix, routeSamples: routeSamples)
        } else {
            placeholderCanvas
        }
    }

    private var placeholderCanvas: some View {
        RoachMapCanvas(
            title: collection?.name ?? "RoachAtlas",
            subtitle: collection?.stateLabel ?? "No pack selected",
            mode: mode,
            zoomLevel: zoomLevel,
            latestFix: latestFix,
            routeSamples: routeSamples,
            seed: collection?.slug ?? "roachnet"
        )
    }

    private var mapControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: mode.systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(mode.accent)
                    .frame(width: 38, height: 38)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(mode.accent.opacity(0.13))
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(collection?.name ?? "RoachAtlas")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(RoachPalette.text)
                        .lineLimit(2)
                    Text(collection?.detail ?? "Install a map pack to anchor the native viewer.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                RoachTag(mode.rawValue, accent: mode.accent)
                RoachTag(snapshot.isLive ? "Live GPS" : "Offline", accent: snapshot.isLive ? RoachPalette.green : RoachPalette.bronze)
                RoachTag(snapshot.reliabilityLabel, accent: snapshot.reliabilityAccent)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 136), spacing: 10)], spacing: 10) {
                RoachMapStat(label: "Speed", value: snapshot.speedLabel)
                RoachMapStat(label: "Heading", value: snapshot.headingLabel)
                RoachMapStat(label: "Accuracy", value: snapshot.accuracyLabel)
                RoachMapStat(label: "Step", value: snapshot.stepDistanceLabel)
            }

            if !hasPacks {
                VStack(alignment: .leading, spacing: 8) {
                    Text("ZOOM")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(RoachPalette.muted)
                    Slider(value: $zoomLevel, in: 0.3...1.0)
                        .tint(mode.accent)
                }
            } else {
                Text("Drag to pan, pinch or double-click to zoom. Everything here is drawn from the packs on this Mac.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(RoachPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    Button {
                        onInstallSelected()
                    } label: {
                        Label(installBusy ? "Queueing" : (collection?.isReady == true ? "Refresh Pack" : "Install Pack"), systemImage: collection?.isReady == true ? "arrow.clockwise" : "square.and.arrow.down.fill")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(RoachPrimaryButtonStyle())
                    .disabled(collection == nil || installBusy)

                    webAtlasButton
                }

                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        onInstallSelected()
                    } label: {
                        Label(installBusy ? "Queueing" : (collection?.isReady == true ? "Refresh Pack" : "Install Pack"), systemImage: collection?.isReady == true ? "arrow.clockwise" : "square.and.arrow.down.fill")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(RoachPrimaryButtonStyle())
                    .disabled(collection == nil || installBusy)

                    webAtlasButton
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(RoachPalette.panelRaised.opacity(0.74))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(controlsHovered ? mode.accent.opacity(0.34) : RoachPalette.borderStrong, lineWidth: 1)
        )
        .shadow(color: controlsHovered ? mode.accent.opacity(0.10) : .clear, radius: 18, y: 10)
        .onHover { controlsHovered = $0 }
        .animation(.spring(response: 0.24, dampingFraction: 0.86), value: controlsHovered)
    }

    private var webAtlasButton: some View {
        Button {
            onOpenWebAtlas()
        } label: {
            Label("Native Atlas", systemImage: "map.fill")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(RoachSecondaryButtonStyle())
    }
}

private struct RoachMapCanvas: View {
    let title: String
    let subtitle: String
    let mode: RoachMapViewerMode
    let zoomLevel: Double
    let latestFix: RoachPhoneLocationFix?
    let routeSamples: [RoachPhoneLocationFix]
    let seed: String
    @State private var pulse = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                drawBackground(context: context, size: size)
                drawTopography(context: context, size: size)
                drawRoute(context: context, size: size)
                drawPins(context: context, size: size)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(RoachPalette.text)
                            .lineLimit(2)
                        Text(subtitle)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(mode.accent)
                    }
                    Spacer()
                    RoachTag(latestFix == nil ? "Offline view" : "Phone locked", accent: latestFix == nil ? RoachPalette.bronze : RoachPalette.green)
                }

                Spacer()

                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(latestFix?.coordinateLabel ?? "No phone fix")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(RoachPalette.text)
                        Text(latestFix?.sourceName ?? "RoachNet native atlas")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(RoachPalette.muted)
                    }
                    Spacer()
                    Text("\(Int((zoomLevel * 100).rounded()))%")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(RoachPalette.cyan)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            Capsule(style: .continuous)
                                .fill(RoachPalette.panelRaised.opacity(0.82))
                        )
                }

                Text("Install a map pack to draw the real map here.")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(RoachPalette.muted.opacity(0.78))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(mode.accent.opacity(0.28), lineWidth: 1)
        )
        .shadow(color: mode.accent.opacity(latestFix == nil ? 0.08 : 0.18), radius: latestFix == nil ? 14 : 24, y: 14)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(RoachPalette.panel.opacity(0.96))
        )
        .onAppear {
            withAnimation(.easeInOut(duration: 1.45).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private func drawBackground(context: GraphicsContext, size: CGSize) {
        let rect = CGRect(origin: .zero, size: size)
        context.fill(
            Path(rect),
            with: .linearGradient(
                Gradient(colors: [
                    RoachPalette.backgroundRaised,
                    RoachPalette.panel,
                    Color.black.opacity(0.88),
                ]),
                startPoint: .zero,
                endPoint: CGPoint(x: size.width, y: size.height)
            )
        )

        let gridSpacing = max(30, 74 * zoomLevel)
        var grid = Path()
        var x: CGFloat = 0
        while x <= size.width {
            grid.move(to: CGPoint(x: x, y: 0))
            grid.addLine(to: CGPoint(x: x, y: size.height))
            x += gridSpacing
        }

        var y: CGFloat = 0
        while y <= size.height {
            grid.move(to: CGPoint(x: 0, y: y))
            grid.addLine(to: CGPoint(x: size.width, y: y))
            y += gridSpacing
        }

        context.stroke(grid, with: .color(RoachPalette.cyan.opacity(0.10)), lineWidth: 1)
    }

    private func drawTopography(context: GraphicsContext, size: CGSize) {
        let accent = mode.accent
        for index in 0..<5 {
            let inset = CGFloat(index) * 26 + CGFloat(28 * (1 - zoomLevel))
            let rect = CGRect(
                x: size.width * 0.12 + inset,
                y: size.height * 0.10 + inset * 0.62,
                width: max(20, size.width * 0.72 - inset * 1.2),
                height: max(20, size.height * 0.70 - inset)
            )
            context.stroke(
                Path(ellipseIn: rect),
                with: .color(accent.opacity(0.10 + Double(index) * 0.012)),
                lineWidth: 1.2
            )
        }

        var arterial = Path()
        let points = seededPoints(in: size)
        guard let first = points.first else { return }
        arterial.move(to: first)
        for point in points.dropFirst() {
            arterial.addCurve(
                to: point,
                control1: CGPoint(x: point.x - size.width * 0.10, y: point.y - 22),
                control2: CGPoint(x: point.x - size.width * 0.04, y: point.y + 28)
            )
        }
        context.stroke(arterial, with: .color(RoachPalette.bronze.opacity(0.38)), lineWidth: 2.4)
    }

    private func drawRoute(context: GraphicsContext, size: CGSize) {
        let routePoints = normalizedRoutePoints(in: size)
        guard routePoints.count > 1 else { return }

        var path = Path()
        path.move(to: routePoints[0])
        for point in routePoints.dropFirst() {
            path.addLine(to: point)
        }

        context.stroke(path, with: .color(RoachPalette.green.opacity(0.28)), lineWidth: 8)
        context.stroke(path, with: .color(RoachPalette.green.opacity(0.92)), lineWidth: 3)
    }

    private func drawPins(context: GraphicsContext, size: CGSize) {
        let routePoints = normalizedRoutePoints(in: size)
        let pinPoints = routePoints.isEmpty ? Array(seededPoints(in: size).prefix(3)) : [routePoints.last!]

        for (index, point) in pinPoints.enumerated() {
            let color = index == pinPoints.count - 1 && latestFix != nil ? RoachPalette.green : RoachPalette.magenta
            context.fill(Path(ellipseIn: CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14)), with: .color(color))
            let livePin = index == pinPoints.count - 1 && latestFix != nil
            let ringSize: CGFloat = livePin && pulse ? 40 : 30
            context.stroke(
                Path(ellipseIn: CGRect(x: point.x - ringSize / 2, y: point.y - ringSize / 2, width: ringSize, height: ringSize)),
                with: .color(color.opacity(livePin && pulse ? 0.16 : 0.28)),
                lineWidth: livePin && pulse ? 3 : 2
            )
        }
    }

    private func seededPoints(in size: CGSize) -> [CGPoint] {
        let hash = abs(seed.hashValue)
        let wobble = CGFloat(hash % 19) / 100
        return [
            CGPoint(x: size.width * (0.10 + wobble), y: size.height * 0.72),
            CGPoint(x: size.width * 0.28, y: size.height * (0.60 - wobble / 2)),
            CGPoint(x: size.width * 0.47, y: size.height * (0.48 + wobble / 2)),
            CGPoint(x: size.width * 0.66, y: size.height * 0.33),
            CGPoint(x: size.width * (0.88 - wobble), y: size.height * 0.20),
        ]
    }

    private func normalizedRoutePoints(in size: CGSize) -> [CGPoint] {
        guard routeSamples.count > 1 else {
            return []
        }

        let latitudes = routeSamples.map(\.latitude)
        let longitudes = routeSamples.map(\.longitude)
        let minLat = latitudes.min() ?? 0
        let maxLat = latitudes.max() ?? 0
        let minLon = longitudes.min() ?? 0
        let maxLon = longitudes.max() ?? 0
        let latRange = max(0.00001, maxLat - minLat)
        let lonRange = max(0.00001, maxLon - minLon)
        let inset: CGFloat = 54

        return routeSamples.map { fix in
            let xRatio = (fix.longitude - minLon) / lonRange
            let yRatio = 1 - ((fix.latitude - minLat) / latRange)
            return CGPoint(
                x: inset + CGFloat(xRatio) * max(1, size.width - inset * 2),
                y: inset + CGFloat(yRatio) * max(1, size.height - inset * 2)
            )
        }
    }
}

private struct RoachMapStat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(1.1)
                .foregroundStyle(RoachPalette.muted)
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(RoachPalette.text)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(RoachPalette.panelGlass)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(RoachPalette.border, lineWidth: 1)
        )
    }
}

struct RoachPhoneTrackingPanel: View {
    @ObservedObject var bridge: RoachPhoneLocationBridge
    @Binding var manualPayload: String

    private var snapshot: RoachMapNavigationSnapshot {
        RoachMapNavigationSnapshot(
            latestFix: bridge.latestFix,
            previousFix: bridge.routeSamples.dropLast().last,
            now: Date()
        )
    }

    var body: some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        RoachKicker("RoachPhone GPS")
                        Text("Phone tracking")
                            .font(.system(size: 19, weight: .bold, design: .rounded))
                            .foregroundStyle(RoachPalette.text)
                        Text(bridge.connectionState.detail)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(RoachPalette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    RoachTag(bridge.statusLabel, accent: bridge.latestFix == nil ? RoachPalette.bronze : RoachPalette.green)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        phoneActionButtons
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        phoneActionButtons
                    }
                }

                if bridge.isScanning && bridge.discoveredDevices.isEmpty {
                    RoachNotice(
                        title: "Scanning",
                        detail: "Keep RoachPhone nearby with GPS bridge on.",
                        accent: RoachPalette.cyan,
                        systemName: "dot.radiowaves.left.and.right"
                    )
                }

                if !bridge.discoveredDevices.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(bridge.discoveredDevices.prefix(4)) { device in
                            Button {
                                bridge.connect(device)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "iphone.radiowaves.left.and.right")
                                        .foregroundStyle(RoachPalette.green)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(device.name)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(RoachPalette.text)
                                        Text(device.signalLabel)
                                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                                            .foregroundStyle(RoachPalette.muted)
                                    }
                                    Spacer()
                                    Image(systemName: "link")
                                        .foregroundStyle(RoachPalette.cyan)
                                }
                                .padding(10)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(RoachPalette.panelRaised.opacity(0.58))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(RoachPalette.border, lineWidth: 1)
                                )
                            }
                            .buttonStyle(RoachCardButtonStyle())
                        }
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 136), spacing: 10)], spacing: 10) {
                    RoachMapStat(label: "Fix", value: snapshot.ageLabel)
                    RoachMapStat(label: "Speed", value: snapshot.speedLabel)
                    RoachMapStat(label: "Heading", value: snapshot.headingLabel)
                    RoachMapStat(label: "Quality", value: snapshot.reliabilityLabel)
                }

                VStack(alignment: .leading, spacing: 8) {
                    TextField("GPS JSON or CSV packet", text: $manualPayload, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(RoachPalette.text)
                        .lineLimit(2...4)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(RoachPalette.panelRaised.opacity(0.70))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(RoachPalette.border, lineWidth: 1)
                        )

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            Button {
                                bridge.ingestManualPayload(manualPayload)
                            } label: {
                                Label("Ingest Payload", systemImage: "arrow.down.doc.fill")
                                    .labelStyle(.titleAndIcon)
                            }
                            .buttonStyle(RoachPrimaryButtonStyle())

                            Button {
                                bridge.disconnect()
                            } label: {
                                Label("Disconnect", systemImage: "xmark.circle")
                                    .labelStyle(.titleAndIcon)
                            }
                            .buttonStyle(RoachSecondaryButtonStyle())
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Button {
                                bridge.ingestManualPayload(manualPayload)
                            } label: {
                                Label("Ingest Payload", systemImage: "arrow.down.doc.fill")
                                    .labelStyle(.titleAndIcon)
                            }
                            .buttonStyle(RoachPrimaryButtonStyle())

                            Button {
                                bridge.disconnect()
                            } label: {
                                Label("Disconnect", systemImage: "xmark.circle")
                                    .labelStyle(.titleAndIcon)
                            }
                            .buttonStyle(RoachSecondaryButtonStyle())
                        }
                    }
                }

                if let error = bridge.lastPayloadError {
                    Text(error)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(RoachPalette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var phoneActionButtons: some View {
        Button {
            bridge.isScanning ? bridge.stopScanning() : bridge.startScanning()
        } label: {
            Label(bridge.isScanning ? "Stop" : "Scan", systemImage: bridge.isScanning ? "stop.circle.fill" : "dot.radiowaves.left.and.right")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(RoachPrimaryButtonStyle())

        Menu {
            Button("Use Demo Fix") {
                bridge.useDemoFix()
            }

            Button("Reset Route") {
                bridge.resetRoute()
            }
        } label: {
            Label("Tools", systemImage: "ellipsis.circle")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(RoachSecondaryButtonStyle())
    }
}

struct RoachMapSourceReadinessPanel: View {
    let sources: [RoachOpenMapSource]
    let selectedCollection: RoachMapCollectionDisplay?
    let routeSamples: [RoachPhoneLocationFix]

    var body: some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    RoachSectionHeader(
                        "Open Data",
                        title: "Map data.",
                        detail: nil
                    )
                    Spacer()
                    RoachTag(selectedCollection?.isReady == true ? "Pack ready" : "Pack needed", accent: selectedCollection?.isReady == true ? RoachPalette.green : RoachPalette.bronze)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], alignment: .leading, spacing: 12) {
                    ForEach(sources) { source in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .top, spacing: 10) {
                                Circle()
                                    .fill(source.accent)
                                    .frame(width: 9, height: 9)
                                    .padding(.top, 5)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(source.name)
                                        .font(.system(size: 14, weight: .bold, design: .rounded))
                                        .foregroundStyle(RoachPalette.text)
                                    Text(source.role)
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(source.accent)
                                }
                                Spacer()
                                RoachTag(source.status, accent: source.accent)
                            }

                            Text(source.detail)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(RoachPalette.muted)
                                .lineLimit(1)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(RoachPalette.panelRaised.opacity(0.58))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(RoachPalette.border, lineWidth: 1)
                        )
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        RoachTag("Trace samples \(routeSamples.count)", accent: routeSamples.isEmpty ? RoachPalette.bronze : RoachPalette.green)
                        RoachTag("No bulk tile scraping", accent: RoachPalette.warning)
                        RoachTag("Local-first GPS", accent: RoachPalette.green)
                    }
                }
            }
        }
    }
}

struct RoachMapPackShelf: View {
    let collections: [RoachMapCollectionDisplay]
    @Binding var selectedSlug: String?
    let activeActionIDs: Set<String>

    var body: some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    RoachSectionHeader("Map Packs", title: "Atlas shelf.", detail: nil)
                    Spacer()
                    RoachTag("\(collections.count) packs", accent: RoachPalette.cyan)
                }

                if collections.isEmpty {
                    RoachNotice(
                        title: "No map packs loaded",
                        detail: "Refresh runtime or install the base atlas.",
                        accent: RoachPalette.warning,
                        systemName: "map"
                    )
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], alignment: .leading, spacing: 12) {
                        ForEach(collections) { collection in
                            Button {
                                selectedSlug = collection.slug
                            } label: {
                                RoachMapPackCard(
                                    collection: collection,
                                    isSelected: selectedSlug == collection.slug,
                                    isBusy: activeActionIDs.contains("map-\(collection.slug)")
                                )
                            }
                            .buttonStyle(RoachCardButtonStyle())
                            .accessibilityLabel(Text(collection.name))
                            .accessibilityHint(Text(collection.stateLabel))
                        }
                    }
                }
            }
        }
    }
}

private struct RoachMapPackCard: View {
    let collection: RoachMapCollectionDisplay
    let isSelected: Bool
    let isBusy: Bool
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: collection.isReady ? "map.fill" : "square.and.arrow.down.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(collection.isReady ? RoachPalette.green : RoachPalette.cyan)
                    .frame(width: 38, height: 38)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill((collection.isReady ? RoachPalette.green : RoachPalette.cyan).opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: 5) {
                    Text(collection.name)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(RoachPalette.text)
                        .lineLimit(2)
                    Text(collection.detail)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(RoachPalette.border.opacity(0.65))
                    Capsule(style: .continuous)
                        .fill(collection.isReady ? RoachPalette.green : RoachPalette.cyan)
                        .frame(width: max(12, proxy.size.width * CGFloat(collection.readinessFraction)))
                }
            }
            .frame(height: 7)

            HStack(spacing: 8) {
                Text(collection.readinessLabel)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(collection.isReady ? RoachPalette.green : RoachPalette.cyan)
                Spacer()
                Text(isBusy ? "Queueing" : collection.stateLabel)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isBusy ? RoachPalette.warning : (collection.isReady ? RoachPalette.green : RoachPalette.bronze))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 156, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isSelected ? RoachPalette.panelSoft.opacity(0.84) : RoachPalette.panelRaised.opacity(0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(isSelected ? RoachPalette.green.opacity(0.42) : RoachPalette.border, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .scaleEffect(hovered ? 1.012 : 1.0)
        .offset(y: hovered ? -1 : 0)
        .shadow(color: isSelected || hovered ? RoachPalette.green.opacity(0.12) : .clear, radius: hovered ? 16 : 10, y: hovered ? 8 : 5)
        .onHover { hovered = $0 }
        .animation(.spring(response: 0.24, dampingFraction: 0.86), value: hovered)
        .animation(.spring(response: 0.24, dampingFraction: 0.86), value: isSelected)
        .help(collection.name)
    }
}
