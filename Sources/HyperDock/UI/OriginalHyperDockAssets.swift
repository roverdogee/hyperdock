import AppKit
import SwiftUI

/// Loads the original loose image resources from the application bundle.
/// Xcode merges `name.png` and `name@2x.png` into a multi-representation TIFF during
/// the resource-copy phase, so SwiftUI's asset-catalog-only `Image(name)` is not enough.
enum OriginalHyperDockAssets {
    static func image(_ name: String) -> Image? {
        nsImage(name).map { Image(nsImage: $0) }
    }

    static func nsImage(_ name: String) -> NSImage? {
        for ext in ["tiff", "png", "icns"] {
            if let url = Bundle.main.url(forResource: name, withExtension: ext),
               let image = NSImage(contentsOf: url) {
                image.isTemplate = false
                return image
            }
        }
        return nil
    }
}
