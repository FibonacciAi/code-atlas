import AppKit
import Metal
import QuickLookThumbnailing
import AtlasCore

/// One fixed texture array, sampled in the map's own render pass. Uploads use
/// the same command queue as drawing, so reusing a slot cannot overwrite a
/// thumbnail that an earlier frame is still sampling.
final class MapThumbnails {
    static let capacity = 128
    private static let width = 256, height = 192
    private(set) var texture: MTLTexture?
    private var residency = PreviewResidency<Int>(capacity: capacity)
    private var aspects: [Int: Float] = [:]
    private var pending: [Int: QLThumbnailGenerator.Request] = [:]
    private var uploads: [(slot: Int, pixels: Data)] = []
    private var generation = UUID()
    var onChange: (() -> Void)?
    private(set) var requestCount = 0
    var residentCount: Int { residency.count }
    var pendingCount: Int { pending.count }

    init(device: MTLDevice?) {
        guard let device else { return }
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.pixelFormat = .rgba8Unorm
        descriptor.width = Self.width; descriptor.height = Self.height
        descriptor.arrayLength = Self.capacity
        descriptor.storageMode = .private; descriptor.usage = .shaderRead
        texture = device.makeTexture(descriptor: descriptor)
        texture?.label = "Map thumbnail array (24 MiB)"
    }

    func clear() {
        generation = UUID()
        pending.values.forEach { QLThumbnailGenerator.shared.cancel($0) }
        pending.removeAll(); uploads.removeAll(); aspects.removeAll()
        residency = PreviewResidency(capacity: Self.capacity); requestCount = 0
    }

    func retainVisible(_ ids: [Int]) { residency.retainVisible(ids) }
    func image(for id: Int) -> (slot: Int, aspect: Float)? {
        guard let slot = residency.slot(for: id), let aspect = aspects[slot] else { return nil }
        return (slot, aspect)
    }

    func request(_ id: Int, index: RepositoryIndex) {
        guard texture != nil, image(for: id) == nil, pending.count < 4, pending[id] == nil,
              index.files.indices.contains(id),
              let url = try? RepoIndexer.validatedURL(root: index.root, path: index.files[id].path) else { return }
        let token = generation
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: Self.width, height: Self.height), scale: 1, representationTypes: .thumbnail)
        pending[id] = request; requestCount += 1
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.pending.removeValue(forKey: id)
                let fallback = representation == nil ? NSWorkspace.shared.icon(forFile: url.path) : nil
                guard let image = representation?.cgImage ?? fallback?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                      let pixels = Self.pixels(image), let slot = self.residency.insert(id) else { return }
                self.aspects[slot] = Float(image.width) / Float(max(1, image.height))
                self.uploads.append((slot, pixels))
                self.onChange?()
            }
        }
    }

    func encodeUploads(_ command: MTLCommandBuffer) {
        guard !uploads.isEmpty, let texture, let encoder = command.makeBlitCommandEncoder() else { return }
        encoder.label = "Thumbnail uploads before map draw"
        for upload in uploads {
            let buffer = upload.pixels.withUnsafeBytes { bytes in
                command.device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
            }
            guard let buffer else { continue }
            encoder.copy(from: buffer, sourceOffset: 0, sourceBytesPerRow: Self.width * 4,
                         sourceBytesPerImage: Self.width * Self.height * 4,
                         sourceSize: MTLSize(width: Self.width, height: Self.height, depth: 1),
                         to: texture, destinationSlice: upload.slot, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        }
        encoder.endEncoding(); uploads.removeAll()
    }

    private static func pixels(_ image: CGImage) -> Data? {
        var pixels = Data(count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return rendered ? pixels : nil
    }

    deinit { pending.values.forEach { QLThumbnailGenerator.shared.cancel($0) } }
}
