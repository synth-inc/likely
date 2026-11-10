import Foundation

/// Fills `{{name}}` placeholders in the search prompt template (PromptTemplate in the app). Split out so
/// it can be unit tested.
public enum PromptRendering {
    /// Placeholders older versions offered, which saved custom templates may still contain. They're
    /// filled with nothing: `{{screenshot}}` said where the screenshot was, and Likely no longer takes
    /// screenshots.
    public static let retired = ["screenshot"]

    public static func render(_ template: String, values: [String: String]) -> String {
        var filled = values
        for name in retired where filled[name] == nil { filled[name] = "" }
        return filled.reduce(template) { $0.replacingOccurrences(of: "{{\($1.key)}}", with: $1.value) }
    }
}
