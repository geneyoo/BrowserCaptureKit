import Foundation

/// Customer-service chat-widget vendor, deterministically inferred from the
/// security origin of the frame a captured event came from.
///
/// This is the `vendorHint` of the frozen capture-envelope contract (`v1`): the
/// kit produces it, the server's vendor registry keys its parser on it. It is a
/// *hint*, not authority — `nil` means "unknown origin", never "no widget".
///
/// Raw values are the exact strings the capture envelope carries
/// (`docs/copilot-lane-contracts.md` §1), so encoding is `rawValue`.
public enum BrowserVendor: String, Equatable, Sendable, CaseIterable {
    case livePerson
    case zendesk
    case amazonConnect
    case intercom
    case salesforce
    case genesys

    /// Registered origin suffixes per vendor. Matched against the frame host as
    /// a label-boundary suffix (so `x.liveperson.net` matches `liveperson.net`
    /// but `evilliveperson.net` does not). Kept deliberately small — the
    /// roadmap's first target is LivePerson; others are M4 adapters.
    static let livePersonOriginSuffixes = ["liveperson.net", "liveperson.com", "lpsnmedia.net"]

    private static let originSuffixes: [(BrowserVendor, [String])] = [
        (.livePerson, livePersonOriginSuffixes),
        (.zendesk, ["zendesk.com", "zdassets.com", "zopim.com"]),
        (.amazonConnect, ["connect.aws", "my.connect.aws", "awsapps.com"]),
        (.intercom, ["intercom.io", "intercomcdn.com"]),
        (.salesforce, ["salesforce.com", "salesforceliveagent.com", "force.com"]),
        (.genesys, ["genesys.com", "mypurecloud.com", "genesyscloud.com"]),
    ]

    /// Deterministic vendor for a frame `securityOrigin` (`scheme://host[:port]`)
    /// or a bare host. Returns `nil` for unknown / unparseable input.
    public init?(origin: String?) {
        guard let host = BrowserVendor.host(from: origin), !host.isEmpty else {
            return nil
        }
        for (vendor, suffixes) in BrowserVendor.originSuffixes
        where suffixes.contains(where: { BrowserVendor.host(host, matchesSuffix: $0) }) {
            self = vendor
            return
        }
        return nil
    }

    /// Extracts the lowercased host from an origin string. Accepts full origins
    /// (`https://x.liveperson.net:443`), scheme-relative, and bare hosts.
    static func host(from origin: String?) -> String? {
        guard var value = origin?.lowercased(), !value.isEmpty else {
            return nil
        }
        if let schemeRange = value.range(of: "://") {
            value = String(value[schemeRange.upperBound...])
        }
        // Strip path / query / port.
        if let slash = value.firstIndex(of: "/") {
            value = String(value[..<slash])
        }
        if let colon = value.firstIndex(of: ":") {
            value = String(value[..<colon])
        }
        return value.isEmpty ? nil : value
    }

    /// Label-boundary suffix match: `host == suffix` or `host` ends with
    /// `"." + suffix`. Prevents `notliveperson.net` from matching `liveperson.net`.
    static func host(_ host: String, matchesSuffix suffix: String) -> Bool {
        host == suffix || host.hasSuffix("." + suffix)
    }
}
