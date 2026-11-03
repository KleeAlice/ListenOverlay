import Foundation

enum ChineseDisplay {
    static func text(_ text: String, simplified: Bool = true) -> String {
        guard simplified else { return text }
        return text.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? text
    }
}
