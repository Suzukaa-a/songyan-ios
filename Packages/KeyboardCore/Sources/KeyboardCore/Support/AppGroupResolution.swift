import Foundation

/// Finds the App Group this install was actually granted.
///
/// Sideloading tools re-sign the app under the installer's own team and rename every App Group to
/// keep it unique: AltStore and SideStore make `<group>.<TEAMID>`, and so does Sideloadly. Only
/// AltStore records the new name (Info.plist `ALTAppGroups`); SideStore since 2026-09 and Sideloadly
/// leave it only in each bundle's embedded provisioning profile. The build-time name is then not
/// granted, its container is nil, and the app and the keyboard would each fall back to private
/// storage. The app and the extension each resolve from their own bundle, and land on the same group.
public enum AppGroupResolution {
    /// The group to use: the declared one when it is granted; otherwise the first renamed form of it
    /// (`<declared>.<suffix>`) that ALTAppGroups or the provisioning profile lists and that is
    /// granted, or failing that, listed; otherwise the declared one.
    public static func resolve(
        declared: String, recorded: [String], profileGroups: [String], isGranted: (String) -> Bool
    ) -> String {
        if isGranted(declared) { return declared }
        let renamed = (recorded + profileGroups).filter { $0.hasPrefix(declared + ".") }
        return renamed.first(where: isGranted) ?? renamed.first ?? declared
    }

    /// The `com.apple.security.application-groups` of an `embedded.mobileprovision`: a CMS envelope
    /// around a plain XML property list, read without verifying the signature (the system already did).
    public static func profileGroups(_ data: Data) -> [String] {
        guard let start = data.range(of: Data("<?xml".utf8)),
            let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex)
        else { return [] }
        let plist = data.subdata(in: start.lowerBound..<end.upperBound)
        guard
            let root = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
            let entitlements = root["Entitlements"] as? [String: Any]
        else { return [] }
        return entitlements["com.apple.security.application-groups"] as? [String] ?? []
    }
}
