import Foundation
import ImageIO

public enum SkinAppearance: String, Codable, CaseIterable, Sendable { case system, light, dark }

public struct SkinError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
public struct SkinDefinition: Codable, Equatable, Identifiable, Sendable {
    /// Format versions the decoder accepts. A writer emits 2 only when a version 2 feature is used
    /// (alpha colours, multi-colour or horizontal/diagonal gradients, image backgrounds); everything
    /// else stays byte-identical version 1.
    public static let supportedFormatVersions = 1...2
    public static let maximumBytes = 128 * 1024
    /// Limit for a skin that carries an image background.
    public static let maximumBytesWithImage = 2_097_152
    /// Decoded image payload limit and the per-side pixel limit.
    public static let maximumImageBytes = 1_048_576
    public static let maximumImagePixels = 4096

    public var formatVersion = 1
    public var id: String
    public var name: String
    public var author: String?
    public var variants = Variants()
    public var typography = Typography()
    public var keycap = Keycap()
    public var spacing = Spacing()
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
    /// Stable identity of the built-in default skin.
    public static let systemDefaultID = "system-default"

    /// The name to show in the interface. The stored `name` keeps the record's own value (it is
    /// written into saved files), so changing the system language never rewrites a saved record.
    public var displayName: String {
        id == Self.systemDefaultID
            ? String(localized: "skin.name.systemDefault", bundle: .module) : name
    }

    public static let systemDefault: SkinDefinition = {
        var skin = SkinDefinition(id: systemDefaultID, name: "系统默认")
        skin.typography.weight = "regular"
        skin.typography.keySize = 22
        skin.typography.secondarySize = 10
        skin.typography.candidateSize = 21
        skin.keycap.shadow = "none"
        skin.spacing.visualInsetX = 0
        skin.spacing.visualInsetY = 1
        var light = Variant()
        light.colors = [
            "panel": "#DFE2E7", "key": "#FFFFFF", "control": "#CBD0D8",
            "accent": "#44598F", "accentText": "#FFFFFF", "text": "#252930",
            "secondaryText": "#505863", "selected": "#CCDBEE", "pressed": "#BEC8D6",
        ]
        var dark = Variant()
        dark.colors = [
            "panel": "#25272C", "key": "#44474E", "control": "#363940",
            "accent": "#4C65A6", "accentText": "#F0F5FC", "text": "#F4F5F7",
            "secondaryText": "#BDC3CD", "selected": "#3B536F", "pressed": "#5A626F",
        ]
        skin.variants.light = light
        skin.variants.dark = dark
        return skin
    }()
    public struct Variants: Codable, Equatable, Sendable {
        public var light: Variant?
        public var dark: Variant?
        public init() {}
    }
    public struct Variant: Codable, Equatable, Sendable {
        public var colors: [String: String]?
        public var background: Background?
        public init() {}
    }
    public struct Background: Codable, Equatable, Sendable {
        public var type = "solid"
        public var color: String?
        public var from: String?
        public var to: String?
        public var direction: String?
        /// Version 2: two to four gradient stops (replaces `from`/`to`).
        public var colors: [String]?
        /// Version 2: `data:image/<webp|jpeg|png>;base64,...` for `type == "image"`.
        public var image: String?
        /// Version 2: `top`, `center` or `bottom`.
        public var align: String?
        public init() {}
    }
    public struct Typography: Codable, Equatable, Sendable {
        public var family = "system"
        public var weight = "medium"
        public var keySize: Double = 22
        public var secondarySize: Double = 11
        public var candidateSize: Double = 20
        public init() {}
    }
    public struct Keycap: Codable, Equatable, Sendable {
        public var cornerRadius: Double = 6
        public var borderWidth: Double = 0
        public var shadow = "subtle"
        public init() {}
    }
    public struct Spacing: Codable, Equatable, Sendable {
        public var visualInsetX: Double = 2
        public var visualInsetY: Double = 2
        public init() {}
    }
    public static let colorNames = [
        "panel", "key", "control", "accent", "text", "secondaryText", "accentText", "pressed", "selected", "border",
    ]
    public func copy() -> Self {
        var copy = self
        copy.id = UUID().uuidString.lowercased()
        copy.name = String(
            format: String(localized: "skin.name.copySuffix", bundle: .module), copy.name)
        return copy
    }
    /// `verifyImage: false` skips decoding the image payload (the keyboard extension reads snapshots
    /// the host already verified); the data-URL shape is still checked.
    public static func decode(_ data: Data, verifyImage: Bool = true) throws -> Self {
        // Above the plain limit only a file that can hold an image is parsed; the content is checked again below.
        guard data.count <= maximumBytesWithImage,
            data.count <= maximumBytes || data.range(of: Data(#""image""#.utf8)) != nil
        else {
            throw SkinError(String(localized: "skin.error.fileTooLarge", bundle: .module))
        }
        guard let source = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SkinError(String(localized: "skin.error.notAnObject", bundle: .module))
        }
        let skin = try decode(object: source, verifyImage: verifyImage)
        guard data.count <= maximumBytes || skin.usesImage else {
            throw SkinError(String(localized: "skin.error.fileTooLarge", bundle: .module))
        }
        return skin
    }

    /// Decodes an already parsed object; the caller owns the file size limit.
    public static func decode(object source: [String: Any], verifyImage: Bool = true) throws -> Self {
        // Imported skins retain the format's original omitted-field defaults.
        var defaults =
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(SkinDefinition(id: "", name: "")))
            as! [String: Any]
        defaults.removeValue(forKey: "id")
        defaults.removeValue(forKey: "name")
        func merge(_ input: [String: Any], _ base: [String: Any], _ path: String) throws -> [String: Any] {
            let allowed: Set<String>
            switch path {
            case "$":
                allowed = ["formatVersion", "id", "name", "author", "variants", "typography", "keycap", "spacing"]
            case "$.variants": allowed = ["light", "dark"]
            case "$.variants.light", "$.variants.dark": allowed = ["colors", "background"]
            case let p where p.hasSuffix(".colors"): allowed = Set(colorNames)
            case let p where p.hasSuffix(".background"):
                allowed = ["type", "color", "from", "to", "direction", "colors", "image", "align"]
            default: allowed = Set(base.keys)
            }
            var result = base
            for (key, value) in input {
                guard allowed.contains(key) else {
                    throw SkinError(
                        String(
                            format: String(localized: "skin.error.unknownField", bundle: .module),
                            key, "\(path).\(key)"))
                }
                if let object = value as? [String: Any] {
                    result[key] = try merge(object, base[key] as? [String: Any] ?? [:], "\(path).\(key)")
                } else {
                    result[key] = value
                }
            }
            return result
        }
        guard let declared = source["formatVersion"] as? Int, supportedFormatVersions.contains(declared) else {
            throw SkinError(
                String(
                    format: String(localized: "skin.error.unsupportedVersion", bundle: .module), "1、2"))
        }
        let skin = try JSONDecoder().decode(
            Self.self, from: JSONSerialization.data(withJSONObject: merge(source, defaults, "$")))
        // A version 1 file must stay within version 1 features.
        if declared == 1, let path = skin.firstVersion2FeaturePath {
            throw SkinError(
                String(format: String(localized: "skin.error.invalidValue", bundle: .module), path))
        }
        try skin.validate(verifyImage: verifyImage)
        return skin.normalized()
    }
    public func validate(verifyImage: Bool = true) throws {
        func require(_ test: Bool, _ path: String) throws {
            if !test {
                throw SkinError(
                    String(
                        format: String(localized: "skin.error.invalidValue", bundle: .module), path))
            }
        }
        try require(Self.supportedFormatVersions.contains(formatVersion), "$.formatVersion")
        try require(
            !id.isEmpty
                && id.utf8.allSatisfy {
                    (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
                }, "$.id")
        try require(!name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "$.name")
        try require(["system", "rounded", "serif", "monospaced"].contains(typography.family), "$.typography.family")
        try require(["regular", "medium", "semibold"].contains(typography.weight), "$.typography.weight")
        for (path, value, range) in [
            ("typography.keySize", typography.keySize, 16.0...28.0),
            ("typography.secondarySize", typography.secondarySize, 10...16),
            ("typography.candidateSize", typography.candidateSize, 16...30),
            ("keycap.cornerRadius", keycap.cornerRadius, 0...16), ("keycap.borderWidth", keycap.borderWidth, 0...2),
            ("spacing.visualInsetX", spacing.visualInsetX, 0...6),
            ("spacing.visualInsetY", spacing.visualInsetY, 0...6),
        ] {
            try require(value.isFinite && range.contains(value), "$.\(path)")
        }
        try require(["none", "subtle"].contains(keycap.shadow), "$.keycap.shadow")
        for (mode, variant) in [("light", variants.light), ("dark", variants.dark)] {
            for (key, value) in variant?.colors ?? [:] {
                try require(
                    Self.colorNames.contains(key) && SkinColor(hex: value) != nil, "$.variants.\(mode).colors.\(key)")
            }
            if let b = variant?.background {
                let base = "$.variants.\(mode).background"
                func valid(_ hex: String?) -> Bool { hex.flatMap(SkinColor.init(hex:)) != nil }
                switch b.type {
                case "solid":
                    try require(valid(b.color), "\(base).color")
                    try require(
                        b.from == nil && b.to == nil && b.direction == nil && b.colors == nil && b.image == nil
                            && b.align == nil, base)
                case "linearGradient":
                    try require(b.color == nil && b.image == nil && b.align == nil, base)
                    if let stops = b.colors {
                        try require(b.from == nil && b.to == nil, base)
                        try require((2...4).contains(stops.count), "\(base).colors")
                        for (index, stop) in stops.enumerated() {
                            try require(valid(stop), "\(base).colors[\(index)]")
                        }
                        try require(
                            ["vertical", "horizontal", "diagonal"].contains(b.direction ?? ""), "\(base).direction")
                    } else {
                        try require(valid(b.from) && valid(b.to), base)
                        try require(b.direction == "vertical", "\(base).direction")
                    }
                case "image":
                    try require(
                        b.color == nil && b.from == nil && b.to == nil && b.direction == nil && b.colors == nil, base)
                    try require(["top", "center", "bottom"].contains(b.align ?? ""), "\(base).align")
                    var imageOK = false
                    if let image = b.image,
                        case .success = Self.inspectImage(dataURL: image, verifyContent: verifyImage)
                    {
                        imageOK = true
                    }
                    try require(imageOK, "\(base).image")
                default:
                    try require(false, "\(base).type")
                }
            }
        }
    }

    /// Path of the first version 2 feature in use, or nil when the skin is plain version 1.
    public var firstVersion2FeaturePath: String? {
        for (mode, variant) in [("light", variants.light), ("dark", variants.dark)] {
            for name in Self.colorNames where (variant?.colors?[name]?.utf8.count ?? 0) == 9 {
                return "$.variants.\(mode).colors.\(name)"
            }
            guard let b = variant?.background else { continue }
            let base = "$.variants.\(mode).background"
            if b.type == "image" || b.image != nil { return "\(base).type" }
            if b.colors != nil { return "\(base).colors" }
            for (key, value) in [("color", b.color), ("from", b.from), ("to", b.to)] where value?.utf8.count == 9 {
                return "\(base).\(key)"
            }
        }
        return nil
    }

    public var usesVersion2Features: Bool { firstVersion2FeaturePath != nil }

    /// Whether a background carries an image (raises the file size limit).
    public var usesImage: Bool {
        [variants.light, variants.dark].contains { $0?.background?.image != nil || $0?.background?.type == "image" }
    }

    public struct ImageInfo: Equatable, Sendable {
        public let mimeType: String
        public let byteCount: Int
        public let pixelWidth: Int
        public let pixelHeight: Int
    }

    public enum ImageProblem: Error, Equatable, Sendable {
        case malformedDataURL, badBase64, tooLarge, badMagic, unreadable, tooManyPixels
    }

    /// Checks a `data:image/<webp|jpeg|png>;base64,...` URL: base64 decodes, magic bytes match the
    /// declared type, decoded size and pixel dimensions are within limits. Dimensions come from the
    /// image header (ImageIO), the pixels are never decoded. `verifyContent: false` checks only the
    /// URL shape.
    public static func inspectImage(dataURL: String, verifyContent: Bool = true) -> Result<ImageInfo, ImageProblem> {
        var mime = ""
        var payload = Substring()
        for type in ["webp", "jpeg", "png"] {
            let prefix = "data:image/\(type);base64,"
            if dataURL.hasPrefix(prefix) {
                mime = "image/\(type)"
                payload = dataURL.dropFirst(prefix.count)
                break
            }
        }
        guard !mime.isEmpty, !payload.isEmpty else { return .failure(.malformedDataURL) }
        guard verifyContent else {
            return .success(ImageInfo(mimeType: mime, byteCount: 0, pixelWidth: 0, pixelHeight: 0))
        }
        // Longer than the base64 form of the limit cannot decode to an allowed size.
        guard payload.utf8.count <= (maximumImageBytes + 2) / 3 * 4 else { return .failure(.tooLarge) }
        guard let bytes = Data(base64Encoded: String(payload)) else { return .failure(.badBase64) }
        guard bytes.count <= maximumImageBytes else { return .failure(.tooLarge) }
        let head = [UInt8](bytes.prefix(12))
        let magicMatches: Bool
        switch mime {
        case "image/png": magicMatches = head.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        case "image/jpeg": magicMatches = head.starts(with: [0xFF, 0xD8, 0xFF])
        default:
            magicMatches =
                head.count == 12 && head.starts(with: Array("RIFF".utf8))
                && Array(head[8..<12]) == Array("WEBP".utf8)
        }
        guard magicMatches else { return .failure(.badMagic) }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(bytes as CFData, options), CGImageSourceGetCount(source) >= 1,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0
        else { return .failure(.unreadable) }
        guard width <= maximumImagePixels, height <= maximumImagePixels else { return .failure(.tooManyPixels) }
        return .success(ImageInfo(mimeType: mime, byteCount: bytes.count, pixelWidth: width, pixelHeight: height))
    }
    public func normalized() -> Self {
        var result = self
        for dark in [false, true] {
            var variant = (dark ? variants.dark : variants.light) ?? Variant()
            variant.colors = resolvedColors(dark: dark).mapValues(\.hex)
            if dark { result.variants.dark = variant } else { result.variants.light = variant }
        }
        result.formatVersion = result.usesVersion2Features ? 2 : 1
        return result
    }
    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let result = normalized()
        // Slashes stay unescaped in version 2 so a data URL keeps its size; version 1 bytes are unchanged.
        if result.formatVersion >= 2 { encoder.outputFormatting.insert(.withoutEscapingSlashes) }
        let data = try encoder.encode(result)
        guard data.count <= (usesImage ? Self.maximumBytesWithImage : Self.maximumBytes) else {
            throw SkinError(String(localized: "skin.error.fileTooLarge", bundle: .module))
        }
        return data
    }
    /// Whether the skin authors a background for this mode. Without one the keyboard shows the
    /// system keyboard surface behind the keys, so the area under and around them reads as one
    /// surface with the system-drawn bottom row.
    public func hasExplicitBackground(dark: Bool) -> Bool {
        (dark ? variants.dark : variants.light)?.background != nil
    }
    /// The system keyboard surface behind the keys, measured on the simulator. Keys are composited
    /// over it, so text contrast is judged against the composite.
    public static func systemSurface(dark: Bool) -> SkinColor {
        SkinColor(hex: dark ? "#222223" : "#E0E1E8")!
    }
    /// Dark function keys sit only a few steps off the panel, so a borderless skin outlines them (and
    /// the return key) with a 1 pt hairline in its own border colour. Contrast against black below
    /// 5:1 is a relative luminance below 0.2, the line Android draws too.
    public func outlinesFunctionKeys(dark: Bool) -> Bool {
        guard keycap.borderWidth == 0 else { return false }
        let colors = resolvedColors(dark: dark)
        guard let control = colors["control"], control.alpha >= 1 else { return false }
        let panel = (colors["panel"] ?? colors["key"]!).composited(over: Self.systemSurface(dark: dark))
        return panel.contrast(on: SkinColor(hex: "#000000")!) < 5
    }
    public func resolvedColors(dark: Bool) -> [String: SkinColor] {
        let values =
            dark
            ? [
                "#202124", "#38393C", "#55565A", "#286CD8", "#FFFFFF", "#FFFFFF", "#FFFFFF", "#65666A", "#55565A",
                "#808080",
            ]
            : [
                "#D1D3D9", "#FFFFFF", "#ADB2BC", "#145ACC", "#000000", "#333333", "#FFFFFF", "#C2C5CC", "#ADB2BC",
                "#777777",
            ]
        var colors = Dictionary(uniqueKeysWithValues: zip(Self.colorNames, values).map { ($0, SkinColor(hex: $1)!) })
        for (key, value) in (dark ? variants.dark : variants.light)?.colors ?? [:] {
            if let color = SkinColor(hex: value) { colors[key] = color }
        }
        let surface = Self.systemSurface(dark: dark)
        colors["text"] = colors["text"]!.contrasting(on: colors["key"]!, over: surface)
        colors["secondaryText"] = colors["secondaryText"]!.contrasting(on: colors["key"]!, over: surface)
        colors["accentText"] = colors["accentText"]!.contrasting(on: colors["accent"]!, over: surface)
        return colors
    }
}
public struct SkinColor: Equatable, Sendable {
    public let red: Double, green: Double, blue: Double
    /// 1 for opaque colours.
    public let alpha: Double
    /// Whether the colour was written as `#RRGGBBAA`; the 8-digit form is kept on output.
    private let writtenWithAlpha: Bool

    /// `#RRGGBB` or `#RRGGBBAA`.
    public init?(hex: String) {
        guard hex.first == "#", hex.count == 7 || hex.count == 9,
            hex.dropFirst().allSatisfy(\.isASCII), hex.dropFirst().allSatisfy(\.isHexDigit),
            let value = UInt64(hex.dropFirst(), radix: 16)
        else { return nil }
        let withAlpha = hex.count == 9
        let rgb = withAlpha ? value >> 8 : value
        red = Double((rgb >> 16) & 255) / 255
        green = Double((rgb >> 8) & 255) / 255
        blue = Double(rgb & 255) / 255
        alpha = withAlpha ? Double(value & 255) / 255 : 1
        writtenWithAlpha = withAlpha
    }
    private init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        alpha = 1
        writtenWithAlpha = false
    }
    public var hex: String {
        let base = String(
            format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()),
            Int((blue * 255).rounded()))
        return writtenWithAlpha ? base + String(format: "%02X", Int((alpha * 255).rounded())) : base
    }
    /// The opaque colour this one shows as when drawn over `background`.
    public func composited(over background: Self) -> Self {
        guard alpha < 1 else { return Self(red: red, green: green, blue: blue) }
        func mix(_ a: Double, _ b: Double) -> Double { a * alpha + b * (1 - alpha) }
        return Self(
            red: mix(red, background.red), green: mix(green, background.green), blue: mix(blue, background.blue))
    }
    private var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
    /// Contrast ratio of this colour on `background`; translucent colours are measured as composited.
    public func contrast(on background: Self) -> Double {
        let backing = background.alpha < 1 ? background.composited(over: Self(hex: "#FFFFFF")!) : background
        let foreground = composited(over: backing)
        return (max(foreground.luminance, backing.luminance) + 0.05)
            / (min(foreground.luminance, backing.luminance) + 0.05)
    }
    /// This colour when it reads on `background` (4.5:1), otherwise opaque black or white. With
    /// `over`, a translucent background is first composited over that surface.
    public func contrasting(on background: Self, over surface: Self? = nil) -> Self {
        let backing = surface.map { background.composited(over: $0) } ?? background
        if contrast(on: backing) >= 4.5 { return self }
        let black = Self(hex: "#000000")!, white = Self(hex: "#FFFFFF")!
        return black.contrast(on: backing) >= white.contrast(on: backing) ? black : white
    }
}
