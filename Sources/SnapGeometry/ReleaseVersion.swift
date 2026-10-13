/// Dotted release versions such as "0.3.0" or a "v0.3.0" tag. Missing
/// components count as zero, so "1.2" equals "1.2.0".
public struct ReleaseVersion: Comparable, CustomStringConvertible {
    public let components: [Int]
    public init?(_ text: String) {
        var trimmed = Substring(text)
        if trimmed.first == "v" || trimmed.first == "V" { trimmed = trimmed.dropFirst() }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        components = parts.map { $0! }
    }
    public var description: String { components.map(String.init).joined(separator: ".") }
    private func value(at index: Int) -> Int { index < components.count ? components[index] : 0 }
    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        for i in 0..<max(lhs.components.count, rhs.components.count) where lhs.value(at: i) != rhs.value(at: i) {
            return lhs.value(at: i) < rhs.value(at: i)
        }
        return false
    }
    public static func == (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}
