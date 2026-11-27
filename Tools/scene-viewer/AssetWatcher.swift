import Foundation
import SceneFormats

/// Polls source and referenced files, including missing resources, without replacing a valid scene on failure.
struct AssetWatcher {
    struct Stamp: Equatable {
        var modified: Date?
        var size: Int?
    }
    var stamps: [URL: Stamp] = [:]
    var elapsed: Double = 0

    mutating func synchronize(_ asset: SceneAssetFile) {
        for url in asset.dependencies { stamps[url] = stamp(url) }
    }

    mutating func changed(_ asset: SceneAssetFile, delta: Double) -> Bool {
        elapsed += delta
        guard elapsed >= 0.5 else { return false }
        elapsed = 0
        var changed = false
        for url in asset.dependencies.union(stamps.keys) {
            let next = stamp(url)
            if let previous = stamps[url], previous != next { changed = true }
            stamps[url] = next
        }
        return changed
    }

    private func stamp(_ url: URL) -> Stamp {
        var url = url
        url.removeAllCachedResourceValues()
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return Stamp(modified: values?.contentModificationDate, size: values?.fileSize)
    }
}
