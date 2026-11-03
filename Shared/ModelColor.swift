import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }

    /// The color depends only on the model name, never on its rank:
    /// the widget and the window paint the same model the same way.
    static func model(_ name: String) -> Color { Color(hex: ModelPalette.hex(name)) }
}
