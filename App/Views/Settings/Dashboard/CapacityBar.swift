import SwiftUI

/// 粗容量条；有用量时至少露出一个圆点，避免极小比例看起来像空盘。
struct CapacityBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let width = fraction > 0 ? max(proxy.size.width * fraction, height) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(Color.accentColor.gradient).frame(width: width)
            }
        }
        .accessibilityHidden(true)
    }
}
