import Foundation

/// Lowercases and drops `_`, `-` and whitespace so "Microsoft Azure" matches `microsoft_azure.png`.
public func cleanBrand(_ brand: String) -> String {
    String(brand.lowercased().filter { !($0 == "_" || $0 == "-" || $0.isWhitespace) })
}

/// Brand files ranked by how well they match `issuer`: exact match first, then containment
/// (longer overlap first), then a shared substring of at least five characters.
public func rankBrandFiles(_ issuer: String, files: [String], brands: [String]) -> [String] {
    let key = cleanBrand(issuer)
    if key.isEmpty || files.isEmpty { return [] }
    var scored: [(file: String, score: Int, order: Int)] = []
    for (index, file) in files.enumerated() {
        let brand = brands[index]
        if brand.isEmpty { continue }
        let score: Int
        if key == brand {
            score = 10000
        } else if key.contains(brand) || brand.contains(key) {
            score = min(key.count, brand.count)
        } else if key.count >= 5 && brand.count >= 5 {
            let shared = longestCommonSubstring(key, brand)
            score = shared >= 5 ? shared : -1
        } else {
            score = -1
        }
        if score >= 0 { scored.append((file, score, index)) }
    }
    scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
    return scored.map(\.file)
}

public func longestCommonSubstring(_ a: String, _ b: String) -> Int {
    let left = Array(a)
    let right = Array(b)
    if left.isEmpty || right.isEmpty { return 0 }
    var best = 0
    var previous = [Int](repeating: 0, count: right.count + 1)
    for i in 1...left.count {
        var current = [Int](repeating: 0, count: right.count + 1)
        for j in 1...right.count where left[i - 1] == right[j - 1] {
            current[j] = previous[j - 1] + 1
            best = max(best, current[j])
        }
        previous = current
    }
    return best
}

/// The bundled-icon file name an `image_path` refers to, or nil for letters, user files and favicons.
public func iconAssetName(_ path: String) -> String? {
    var value = path.trimmingCharacters(in: .whitespaces)
    if value.isEmpty || value == "letter" || value.hasPrefix("letter:") { return nil }
    if value.hasPrefix("file:") || value.hasPrefix("favicon:") || value.hasPrefix("/") { return nil }
    if value.hasPrefix("builtin:") { value.removeFirst("builtin:".count) }
    if let slash = value.lastIndex(where: { $0 == "/" || $0 == "\\" }) {
        value = String(value[value.index(after: slash)...])
    }
    guard value.lowercased().hasSuffix(".png") else { return nil }
    return value
}

/// Matching against the bundled brand icons.
public enum BrandIcons {
    private static let brands: [String] = BrandCatalog.lightFiles.map { cleanBrand(String($0.dropLast(4))) }
    private static let known: Set<String> = Set(BrandCatalog.lightFiles).union(BrandCatalog.darkVariants)
    private static let lock = NSLock()
    private static var cache: [String: String?] = [:]

    /// Best bundled icon for an issuer (light file name such as `github.png`).
    public static func matchFile(_ issuer: String) -> String? {
        let key = cleanBrand(issuer)
        if key.isEmpty { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[key] { return hit }
        let found = rankBrandFiles(key, files: BrandCatalog.lightFiles, brands: brands).first
        if cache.count > 256 { cache.removeAll() }
        cache[key] = found
        return found
    }

    public static func search(_ query: String, limit: Int = 48) -> [String] {
        let key = cleanBrand(query)
        if key.isEmpty { return Array(BrandCatalog.lightFiles.prefix(limit)) }
        return Array(rankBrandFiles(key, files: BrandCatalog.lightFiles, brands: brands).prefix(limit))
    }

    /// Light file name for a stored path when it names a bundled icon (`_dark` is folded away).
    public static func lightFile(for path: String) -> String? {
        guard let name = iconAssetName(path) else { return nil }
        let light = name.hasSuffix("_dark.png") ? String(name.dropLast("_dark.png".count)) + ".png" : name
        return known.contains(light) ? light : nil
    }

    /// Asset-catalog name (`Brand/github`) for a bundled light file name.
    public static func assetName(forFile file: String) -> String {
        "Brand/" + (file.hasSuffix(".png") ? String(file.dropLast(4)) : file)
    }
}

/// Stable avatar colour per name (same palette and hash as the Android app).
public func letterColor(_ text: String) -> UInt32 {
    let palette: [UInt32] = [
        0x3355FF, 0x7C4DFF, 0x0BA5C4, 0x12A374,
        0xF08C00, 0xE5484D, 0xD6409F, 0x4F5D75,
    ]
    let index = Int(javaHashCode(text.lowercased()) & Int32.max) % palette.count
    return palette[index]
}

/// `java.lang.String.hashCode()` over UTF-16 code units.
func javaHashCode(_ text: String) -> Int32 {
    var hash: Int32 = 0
    for unit in text.utf16 { hash = hash &* 31 &+ Int32(unit) }
    return hash
}

/// Host to fetch a favicon from, or nil for anything that is not a plain public domain name.
public func safeHost(_ input: String) -> String? {
    var value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    for scheme in ["https://", "http://"] where value.hasPrefix(scheme) {
        value.removeFirst(scheme.count)
    }
    if let cut = value.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { value = String(value[..<cut]) }
    if let at = value.firstIndex(of: "@") { value = String(value[value.index(after: at)...]) }
    if let colon = value.firstIndex(of: ":") { value = String(value[..<colon]) }
    if value.contains("..") { return nil }
    let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.-")
    guard !value.isEmpty, value.allSatisfy({ allowed.contains($0) }) else { return nil }
    guard let dot = value.lastIndex(of: ".") else { return nil }
    let tld = value[value.index(after: dot)...]
    guard tld.count >= 2, tld.allSatisfy({ $0.isLetter }), dot != value.startIndex else { return nil }
    if value == "localhost" || value.hasSuffix(".local") || value.hasSuffix(".localhost") { return nil }
    return value
}

public func faviconUrl(_ host: String) -> String {
    "https://\(host)/favicon.ico"
}

/// For ICO files, the largest embedded image (PNG or DIB); other data is returned unchanged.
public func extractIconBytes(_ data: [UInt8]) -> [UInt8] {
    guard data.count >= 8, data[0] == 0, data[1] == 0, data[2] == 1, data[3] == 0 else { return data }
    let count = Int(data[4]) | Int(data[5]) << 8
    var best: [UInt8]?
    var bestArea = -1
    for i in 0..<count {
        let entry = 6 + i * 16
        if entry + 16 > data.count { break }
        let width = Int(data[entry])
        let height = Int(data[entry + 1])
        let size = readLeInt(data, entry + 8)
        let offset = readLeInt(data, entry + 12)
        if size <= 0 || offset < 0 || offset + size > data.count { continue }
        let area = (width == 0 ? 256 : width) * (height == 0 ? 256 : height)
        if area >= bestArea {
            bestArea = area
            best = Array(data[offset..<(offset + size)])
        }
    }
    return best ?? data
}

/// Wraps a bare DIB (as found inside ICO files) in a BMP file header so image decoders accept it.
public func dibToBmp(_ dib: [UInt8]) -> [UInt8] {
    guard dib.count >= 4 else { return dib }
    let headerSize = 14
    let fileSize = headerSize + dib.count
    let pixelOffset = headerSize + readLeInt(dib, 0)
    var out = [UInt8](repeating: 0, count: headerSize)
    out[0] = UInt8(ascii: "B")
    out[1] = UInt8(ascii: "M")
    writeLe(&out, 2, fileSize)
    writeLe(&out, 10, pixelOffset)
    return out + dib
}

private func readLeInt(_ data: [UInt8], _ offset: Int) -> Int {
    guard offset >= 0, offset + 4 <= data.count else { return -1 }
    let value = UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    return Int(Int32(bitPattern: value))
}

private func writeLe(_ data: inout [UInt8], _ offset: Int, _ value: Int) {
    for i in 0..<4 { data[offset + i] = UInt8((value >> (8 * i)) & 0xFF) }
}
