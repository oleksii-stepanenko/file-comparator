import AppKit
import Observation
import CoreImage
import DiffCore

@MainActor
@Observable
final class ImageCompareModel {
    enum Mode: String, CaseIterable, Identifiable {
        case sideBySide = "Side by Side"
        case swipe = "Swipe"
        case onion = "Onion Skin"
        case difference = "Difference"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .sideBySide: return "rectangle.split.2x1"
            case .swipe: return "slider.horizontal.below.rectangle"
            case .onion: return "square.2.layers.3d"
            case .difference: return "plus.forwardslash.minus"
            }
        }
    }

    let urls: [URL]
    let images: [NSImage?]
    var mode: Mode = .sideBySide
    var swipe: Double = 0.5
    var opacity: Double = 0.5
    var pairIndex = 0 // for 3 images: which pair is overlaid (0: 1↔2, 1: 2↔3)
    private(set) var differencePercent: Double?
    private(set) var differenceImage: NSImage?
    private(set) var identicalBytes: Bool?

    init(urls: [URL]) {
        self.urls = urls
        self.images = urls.map { NSImage(contentsOf: $0) }
        compute()
    }

    func pixelSize(_ i: Int) -> CGSize? {
        guard let rep = images[i]?.representations.first else { return nil }
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }

    func fileSize(_ i: Int) -> Int64 {
        (try? urls[i].resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0 ?? 0) } ?? 0
    }

    var overlayPair: (Int, Int) { urls.count == 3 ? (pairIndex == 0 ? (0, 1) : (1, 2)) : (0, 1) }

    func compute() {
        let (a, b) = overlayPair
        let ua = urls[a], ub = urls[b]
        let ia = images[a], ib = images[b]
        differencePercent = nil
        differenceImage = nil
        Task.detached(priority: .userInitiated) {
            let same = FolderComparator.bytesEqual(ua, ub)
            var percent: Double?
            var diffImage: NSImage?
            if let ia, let ib, let ca = ia.cgImage(forProposedRect: nil, context: nil, hints: nil),
               let cb = ib.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let w = max(ca.width, cb.width), h = max(ca.height, cb.height)
                let scale = min(1, 2048.0 / Double(max(w, h)))
                let sw = max(1, Int(Double(w) * scale)), sh = max(1, Int(Double(h) * scale))
                if let pa = Self.rgba(ca, sw, sh), let pb = Self.rgba(cb, sw, sh) {
                    var differing = 0
                    var out = [UInt8](repeating: 0, count: sw * sh * 4)
                    for i in 0..<(sw * sh) {
                        let o = i * 4
                        let dr = abs(Int(pa[o]) - Int(pb[o]))
                        let dg = abs(Int(pa[o + 1]) - Int(pb[o + 1]))
                        let db = abs(Int(pa[o + 2]) - Int(pb[o + 2]))
                        let da = abs(Int(pa[o + 3]) - Int(pb[o + 3]))
                        let d = max(dr, dg, db, da)
                        let gray = UInt8((Int(pa[o]) + Int(pa[o + 1]) + Int(pa[o + 2])) / 12 + 20)
                        if d > 8 {
                            differing += 1
                            out[o] = 255; out[o + 1] = UInt8(max(0, 70 - d / 4)); out[o + 2] = UInt8(min(255, 90 + d / 3)); out[o + 3] = 255
                        } else {
                            out[o] = gray; out[o + 1] = gray; out[o + 2] = gray; out[o + 3] = 255
                        }
                    }
                    percent = Double(differing) / Double(sw * sh) * 100
                    if let provider = CGDataProvider(data: Data(out) as CFData),
                       let cg = CGImage(width: sw, height: sh, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: sw * 4,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
                        diffImage = NSImage(cgImage: cg, size: NSSize(width: sw, height: sh))
                    }
                }
            }
            let p = percent, img = diffImage
            await MainActor.run { [weak self] in
                self?.identicalBytes = same
                self?.differencePercent = p
                self?.differenceImage = img
            }
        }
    }

    nonisolated private static func rgba(_ image: CGImage, _ w: Int, _ h: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buf.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? buf : nil
    }
}

@MainActor
@Observable
final class BinaryCompareModel {
    struct Info {
        var size: Int64
        var modified: Date?
        var head: [UInt8]
    }

    let urls: [URL]
    private(set) var infos: [Info]
    private(set) var identical: Bool
    private(set) var firstDifference: Int64?
    /// Offset where the hex view starts.
    private(set) var windowStart: Int64 = 0
    private(set) var windows: [[UInt8]] = []

    nonisolated static let windowSize = 4096

    private init(urls: [URL], infos: [Info], identical: Bool, firstDifference: Int64?, windowStart: Int64, windows: [[UInt8]]) {
        self.urls = urls
        self.infos = infos
        self.identical = identical
        self.firstDifference = firstDifference
        self.windowStart = windowStart
        self.windows = windows
    }

    static func load(urls: [URL]) async -> BinaryCompareModel {
        let (infos, identical, firstDiff, start, windows) = await Task.detached(priority: .userInitiated) { () -> ([Info], Bool, Int64?, Int64, [[UInt8]]) in
            let infos: [Info] = urls.map { u in
                let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                return Info(size: Int64(v?.fileSize ?? 0), modified: v?.contentModificationDate, head: [])
            }
            let firstDiff = Self.firstDifference(urls)
            let identical = firstDiff == nil && Set(infos.map(\.size)).count == 1
            let start = max(0, ((firstDiff ?? 0) / 16) * 16 - 256)
            let windows: [[UInt8]] = urls.map { u in
                guard let h = try? FileHandle(forReadingFrom: u) else { return [] }
                defer { try? h.close() }
                try? h.seek(toOffset: UInt64(start))
                return [UInt8]((try? h.read(upToCount: windowSize)) ?? Data())
            }
            return (infos, identical, firstDiff, start, windows)
        }.value
        return BinaryCompareModel(urls: urls, infos: infos, identical: identical, firstDifference: firstDiff,
                                  windowStart: start, windows: windows)
    }

    /// Offset of the first differing byte across all files (nil if all identical).
    nonisolated static func firstDifference(_ urls: [URL]) -> Int64? {
        let handles = urls.compactMap { try? FileHandle(forReadingFrom: $0) }
        defer { handles.forEach { try? $0.close() } }
        guard handles.count == urls.count else { return 0 }
        var offset: Int64 = 0
        let chunk = 1 << 18
        while true {
            let datas = handles.map { (try? $0.read(upToCount: chunk)) ?? Data() }
            let minCount = datas.map(\.count).min() ?? 0
            for i in 0..<minCount {
                let b = datas[0][datas[0].startIndex + i]
                for d in datas.dropFirst() where d[d.startIndex + i] != b {
                    return offset + Int64(i)
                }
            }
            if datas.contains(where: { $0.count != datas[0].count }) { return offset + Int64(minCount) }
            if datas[0].isEmpty { return nil }
            offset += Int64(datas[0].count)
        }
    }
}
