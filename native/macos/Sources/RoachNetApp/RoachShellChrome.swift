import AppKit
import RoachNetDesign
import SwiftUI

struct RoachLiveChip: View {
    let label: String
    let isLive: Bool

    var body: some View {
        let tint = isLive ? RoachPalette.signal : RoachPalette.warning
        HStack(spacing: 6) {
            RoachLED(tint, size: 5, pulses: !isLive)
            Text(label)
                .font(.roach(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(RoachPalette.text)
                .lineLimit(1)
        }
        .padding(.leading, 6)
        .padding(.trailing, 9)
        .frame(minHeight: 22)
        .background(Capsule(style: .continuous).fill(RoachPalette.panelRaised.opacity(0.7)))
        .overlay(Capsule(style: .continuous).strokeBorder(tint.opacity(0.4), lineWidth: RoachMetrics.line(1)))
        .accessibilityElement(children: .combine)
    }
}
