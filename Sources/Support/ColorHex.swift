import AppKit
import SwiftUI

extension Color {
    /// "RRGGBB" (or "#RRGGBB"); invalid input falls back to white.
    init(hex: String, opacity: Double = 1) {
        let clean = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        let rgb = UInt32(clean, radix: 16) ?? 0xFFFFFF
        self.init(.sRGB, red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255,
                  blue: Double(rgb & 255) / 255, opacity: opacity)
    }

    var hexString: String? {
        guard let color = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        func channel(_ value: CGFloat) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
        return String(format: "%02X%02X%02X", channel(color.redComponent), channel(color.greenComponent), channel(color.blueComponent))
    }

    /// Hue wheel colour; hue wraps, so callers can pass a running phase.
    static func wheel(_ hue: Double, saturation: Double = 1, brightness: Double = 1) -> Color {
        let h = hue - floor(hue)
        return Color(hue: h, saturation: saturation, brightness: brightness)
    }
}

enum HexColor {
    static func isValid(_ value: String) -> Bool {
        value.utf8.count == 6 && value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }

    static func luminance(_ hex: String) -> Double {
        let rgb = UInt32(hex, radix: 16) ?? 0xFFFFFF
        return (Double((rgb >> 16) & 255) * 0.2126 + Double((rgb >> 8) & 255) * 0.7152 + Double(rgb & 255) * 0.0722) / 255
    }

    /// Mix two colours; used for album-tinted cards.
    static func mix(_ a: String, _ b: String, _ amount: Double) -> String {
        let x = UInt32(a, radix: 16) ?? 0, y = UInt32(b, radix: 16) ?? 0
        func c(_ v: UInt32, _ shift: UInt32) -> Double { Double((v >> shift) & 255) }
        let parts = [16, 8, 0].map { shift -> Int in
            Int((c(x, UInt32(shift)) * (1 - amount) + c(y, UInt32(shift)) * amount).rounded())
        }
        return String(format: "%02X%02X%02X", parts[0], parts[1], parts[2])
    }
}
