import SwiftUI

struct BatteryGauge: View {
    let remaining: Double?
    var compact = false
    var muted = false

    private var color: Color {
        if muted { return .secondary }
        guard let remaining else { return .secondary }
        if remaining < 20 { return .red }
        if remaining < 50 { return .orange }
        return .green
    }

    private var text: String {
        guard let remaining else { return "--" }
        return "\(Int(remaining.rounded()))%"
    }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: compact ? 2.5 : 4)
                .strokeBorder(.primary.opacity(0.65), lineWidth: 1)
            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: compact ? 1.5 : 3)
                    .fill(color.opacity(muted ? 0.45 : 0.62))
                    .frame(width: max(0, (geometry.size.width - 4) * ((remaining ?? 0) / 100)))
                    .padding(2)
            }
            Text(text)
                .font(.system(size: compact ? 8 : 10, weight: .bold, design: .rounded))
                .monospacedDigit()
                .frame(maxWidth: .infinity)
                .foregroundStyle(.primary)
        }
        .frame(width: compact ? 38 : 65, height: compact ? 13 : 21)
        .accessibilityLabel("Codex 剩余额度 \(text)")
    }
}
