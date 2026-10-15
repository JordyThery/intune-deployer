import Foundation

/// Classifies a `.mobileconfig` file as a custom configuration profile.
///
/// Signed profiles (CMS/DER-wrapped plists) are reported as unsupported for
/// now rather than silently mis-parsed.
nonisolated enum MobileConfigInference {
    struct Detection: Sendable {
        let displayName: String?
        /// Text used for token scanning (XML form of the plist).
        let scannableText: String?
        let reason: String
    }

    enum Outcome: Sendable {
        case item(Detection)
        case skip(reason: String)
    }

    static func classify(data: Data) -> Outcome {
        guard !data.isEmpty else { return .skip(reason: "Empty file") }

        var plist: Any?
        do {
            plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        } catch {
            plist = nil
        }

        guard let dict = plist as? [String: Any] else {
            // CMS-signed profiles are DER sequences starting with 0x30.
            if data.first == 0x30 {
                return .skip(reason: "Signed .mobileconfig (CMS-wrapped) is not supported yet — export an unsigned profile")
            }
            return .skip(reason: "Not a readable property list")
        }

        let displayName = dict["PayloadDisplayName"] as? String

        // Token scanning needs text; re-serialise as XML so binary plists work too.
        let scannableText: String?
        if let xmlData = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) {
            scannableText = String(data: xmlData, encoding: .utf8)
        } else {
            scannableText = String(data: data, encoding: .utf8)
        }

        return .item(Detection(
            displayName: displayName,
            scannableText: scannableText,
            reason: "Property list with PayloadDisplayName \(displayName.map { "\u{201C}\($0)\u{201D}" } ?? "missing (using filename)")"
        ))
    }
}
