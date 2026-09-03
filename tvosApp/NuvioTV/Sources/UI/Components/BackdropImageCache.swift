import SwiftUI
import Foundation
import UIKit
import ImageIO
import OSLog

/// Small in-memory cache + loader for backdrop images so revisiting a poster is
/// instant (no decode flicker) and repeated focus changes don't refetch.
actor BackdropImageCache {
    static let shared = BackdropImageCache()

    private let cache = NSCache<NSString, UIImage>()

    init() {
        // Backdrops are shown at screen size. Retaining a bounded decoded-byte
        // budget avoids keeping dozens of full-resolution source images alive
        // after rapid focus changes.
        cache.totalCostLimit = 96 * 1024 * 1024
    }

    func image(for url: URL) async -> UIImage? {
        let key = url.absoluteString as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let decoded = downsampleBackdropImage(data: data) else { return nil }
        cache.setObject(decoded, forKey: key, cost: decoded.backdropDecodedByteCost)
        return decoded
    }
}

private func downsampleBackdropImage(data: Data) -> UIImage? {
    let maxPixelSize = max(UIScreen.main.bounds.width, UIScreen.main.bounds.height)
        * UIScreen.main.scale
    let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
    guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
        return nil
    }
    let thumbnailOptions: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: Int(ceil(maxPixelSize))
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(
        source,
        0,
        thumbnailOptions as CFDictionary
    ) else {
        return nil
    }
    return UIImage(cgImage: image)
}

private extension UIImage {
    var backdropDecodedByteCost: Int {
        guard let cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }
}
