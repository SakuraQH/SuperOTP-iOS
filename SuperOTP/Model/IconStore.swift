import SuperOTPKit
import UIKit

/// Icons that are not bundled: pictures the user picked (`file:<name>.png`) and fetched
/// favicons (`favicon:<host>`). Both live in Application Support and are cached in memory.
enum IconStore {
    private static let cache = NSCache<NSString, UIImage>()

    static var iconsDirectory: URL { VaultStore.directory.appendingPathComponent("icons", isDirectory: true) }
    static var faviconsDirectory: URL { VaultStore.directory.appendingPathComponent("favicons", isDirectory: true) }

    /// File for a stored path. Paths copied from Android (`file:/data/.../uid.png`) resolve by file name.
    static func fileURL(for path: String) -> URL? {
        if path.hasPrefix("file:") {
            let name = (String(path.dropFirst("file:".count)) as NSString).lastPathComponent
            guard !name.isEmpty else { return nil }
            return iconsDirectory.appendingPathComponent(name)
        }
        if path.hasPrefix("favicon:") {
            guard let host = safeHost(String(path.dropFirst("favicon:".count))) else { return nil }
            return faviconsDirectory.appendingPathComponent(host + ".png")
        }
        return nil
    }

    static func image(for path: String) -> UIImage? {
        guard let url = fileURL(for: path) else { return nil }
        let key = url.path as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    /// Saves a picked picture as a square PNG and returns its `file:` path.
    static func saveUserIcon(uid: String, data: Data) -> String? {
        guard let source = UIImage(data: data), let png = squarePNG(source, side: 256) else { return nil }
        let name = "\(uid)-\(epochMillis()).png"
        guard write(png, to: iconsDirectory.appendingPathComponent(name)) else { return nil }
        return "file:" + name
    }

    /// Stores a decoded favicon and returns its `favicon:` path.
    static func saveFavicon(host: String, image: UIImage) -> String? {
        guard let png = squarePNG(image, side: min(256, max(64, Int(max(image.size.width, image.size.height) * image.scale)))) else { return nil }
        let url = faviconsDirectory.appendingPathComponent(host + ".png")
        guard write(png, to: url) else { return nil }
        cache.removeObject(forKey: url.path as NSString)
        return "favicon:" + host
    }

    /// Deletes a picture the user picked once nothing refers to it any more.
    static func removeUserIcon(_ path: String) {
        guard path.hasPrefix("file:"), let url = fileURL(for: path) else { return }
        cache.removeObject(forKey: url.path as NSString)
        try? FileManager.default.removeItem(at: url)
    }

    private static func write(_ data: Data, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            return false
        }
    }

    /// Centre-crops to a square and scales to `side` pixels.
    private static func squarePNG(_ image: UIImage, side: Int) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let target = CGSize(width: side, height: side)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let scale = max(target.width / size.width, target.height / size.height)
        let drawn = CGSize(width: size.width * scale, height: size.height * scale)
        let origin = CGPoint(x: (target.width - drawn.width) / 2, y: (target.height - drawn.height) / 2)
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: origin, size: drawn))
        }
        return rendered.pngData()
    }
}

/// The app's only network request: HTTPS GET of `https://<host>/favicon.ico` (HTTPS redirects only).
enum FaviconFetcher {
    static func fetch(_ input: String) async -> String? {
        guard let host = safeHost(input), let url = URL(string: faviconUrl(host)) else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 12
        let session = URLSession(configuration: configuration, delegate: HTTPSRedirectGuard(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("SuperOTP/1.0", forHTTPHeaderField: "User-Agent")
        guard let result = try? await session.data(for: request) else { return nil }
        let (data, response) = result
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              !data.isEmpty, data.count <= 1_000_000,
              let image = decodeIcon([UInt8](data)) else { return nil }
        return IconStore.saveFavicon(host: host, image: image)
    }

    /// ICO (largest entry, PNG or BMP inside), or any format UIImage understands.
    static func decodeIcon(_ bytes: [UInt8]) -> UIImage? {
        let extracted = extractIconBytes(bytes)
        if let image = UIImage(data: Data(extracted)) { return image }
        if let image = UIImage(data: Data(bytes)) { return image }
        if extracted.count > 16, extracted[0] == 40 {
            return UIImage(data: Data(dibToBmp(extracted)))
        }
        return nil
    }
}

private final class HTTPSRedirectGuard: NSObject, URLSessionTaskDelegate {
    private var redirects = 0

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        redirects += 1
        if redirects <= 4, request.url?.scheme?.lowercased() == "https" {
            completionHandler(request)
        } else {
            completionHandler(nil)
        }
    }
}
