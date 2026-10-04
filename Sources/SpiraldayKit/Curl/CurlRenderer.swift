import Foundation
import Metal
import CoreGraphics

/// Shared Metal objects for the page curl. The shader is compiled from source once,
/// off the main thread, as soon as the overlay is created (so the first turn never hitches).
final class CurlGPU: @unchecked Sendable {
    static let shared: CurlGPU? = {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        return CurlGPU(device: device, queue: queue)
    }()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let sampler: MTLSamplerState?
    let pixelFormat: MTLPixelFormat = .bgra8Unorm

    private let lock = NSLock()
    private var compiled = false
    private var state: MTLRenderPipelineState?
    // 펼친 책(iPad) 넘김: 따로 컴파일한다 (한 장 셰이더는 그대로 — Mac 은 이것을 만들지 않는다)
    private var spreadCompiled = false
    private var spreadState: MTLRenderPipelineState?
    private var emptyTexture: MTLTexture?

    private init(device: MTLDevice, queue: MTLCommandQueue) {
        self.device = device
        self.queue = queue
        queue.label = "Spiralday.curl"
        let s = MTLSamplerDescriptor()
        s.minFilter = .linear
        s.magFilter = .linear
        s.mipFilter = .linear
        s.maxAnisotropy = 8
        s.sAddressMode = .clampToEdge
        s.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: s)
    }

    /// Starts compiling the pipeline in the background (idempotent, cheap to call again).
    func warmUp() {
        DispatchQueue.global(qos: .userInitiated).async { _ = self.pipeline }
    }

    /// The render pipeline. Blocks only if requested before the background compile finished.
    var pipeline: MTLRenderPipelineState? {
        lock.lock()
        defer { lock.unlock() }
        if !compiled {
            compiled = true
            state = compile()
        }
        return state
    }

    /// Starts compiling the spread pipeline in the background (idempotent).
    func warmUpSpread() {
        DispatchQueue.global(qos: .userInitiated).async { _ = self.spreadPipeline }
    }

    /// The spread (open book) pipeline: premultiplied output over the live pages.
    var spreadPipeline: MTLRenderPipelineState? {
        lock.lock()
        defer { lock.unlock() }
        if !spreadCompiled {
            spreadCompiled = true
            do {
                let library = try device.makeLibrary(source: CurlSpreadShader.source, options: MTLCompileOptions())
                let desc = MTLRenderPipelineDescriptor()
                desc.label = "Spiralday.curl.spread"
                desc.vertexFunction = library.makeFunction(name: "curl_spread_vertex")
                desc.fragmentFunction = library.makeFunction(name: "curl_spread_fragment")
                desc.colorAttachments[0].pixelFormat = pixelFormat
                spreadState = try device.makeRenderPipelineState(descriptor: desc)
            } catch {
                NSLog("Spiralday: spread curl shader unavailable: \(error)")
                spreadState = nil
            }
        }
        return spreadState
    }

    /// A 1×1 transparent texture for "nothing revealed" (the desk under the last / first sheet).
    private func empty() -> MTLTexture? {
        if let emptyTexture { return emptyTexture }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let t = device.makeTexture(descriptor: desc) else { return nil }
        var zero: UInt32 = 0
        t.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &zero, bytesPerRow: 4)
        emptyTexture = t
        return t
    }

    private func compile() -> MTLRenderPipelineState? {
        do {
            let library = try device.makeLibrary(source: CurlShader.source, options: MTLCompileOptions())
            let desc = MTLRenderPipelineDescriptor()
            desc.label = "Spiralday.curl"
            desc.vertexFunction = library.makeFunction(name: "curl_vertex")
            desc.fragmentFunction = library.makeFunction(name: "curl_fragment")
            desc.colorAttachments[0].pixelFormat = pixelFormat
            return try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            NSLog("Spiralday: page curl shader unavailable: \(error)")
            return nil
        }
    }

    // MARK: Textures

    /// Uploads a page bitmap. It is redrawn into an sRGB premultiplied BGRA buffer (so
    /// the overlay is colour-identical to the live page), then copied into a private,
    /// mip-mapped texture on the GPU. Commands are encoded into `commandBuffer`.
    func makeTexture(_ image: CGImage, commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let bytesPerRow = (w * 4 + 255) & ~255
        guard let staging = device.makeBuffer(length: bytesPerRow * h, options: .storageModeShared),
              let ctx = CGContext(data: staging.contents(), width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.setBlendMode(.copy)
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: true)
        desc.usage = .shaderRead
        desc.storageMode = .private
        guard let texture = device.makeTexture(descriptor: desc),
              let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        texture.label = "Spiralday.page"
        blit.copy(from: staging, sourceOffset: 0, sourceBytesPerRow: bytesPerRow, sourceBytesPerImage: bytesPerRow * h,
                  sourceSize: MTLSize(width: w, height: h, depth: 1), to: texture,
                  destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        return texture
    }

    // MARK: Drawing

    func encode(_ enc: MTLRenderCommandEncoder, pipeline: MTLRenderPipelineState, uniforms: inout CurlUniforms,
                top: MTLTexture, under: MTLTexture) {
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(top, index: 0)
        enc.setFragmentTexture(under, index: 1)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.setFragmentBytes(&uniforms, length: MemoryLayout<CurlUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    func encodeSpread(_ enc: MTLRenderCommandEncoder, pipeline: MTLRenderPipelineState, uniforms: inout CurlSpreadUniforms,
                      front: MTLTexture, back: MTLTexture, revealed: MTLTexture?) {
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(front, index: 0)
        enc.setFragmentTexture(back, index: 1)
        enc.setFragmentTexture(revealed ?? empty(), index: 2)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.setFragmentBytes(&uniforms, length: MemoryLayout<CurlSpreadUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    /// Renders spread states into premultiplied sRGB bitmaps of the whole overlay (tests · frame captures). Synchronous.
    func renderSpreadOffscreen(overlay: CGSize, uniforms: [CurlSpreadUniforms], front: CGImage, back: CGImage,
                               revealed: CGImage?, scale: CGFloat) -> [CGImage] {
        guard let pipeline = spreadPipeline, !uniforms.isEmpty, let upload = queue.makeCommandBuffer(),
              let frontTex = makeTexture(front, commandBuffer: upload),
              let backTex = makeTexture(back, commandBuffer: upload) else { return [] }
        let revealedTex = revealed.flatMap { makeTexture($0, commandBuffer: upload) }
        upload.commit()

        let w = max(1, Int((overlay.width * scale).rounded()))
        let h = max(1, Int((overlay.height * scale).rounded()))
        let bytesPerRow = (w * 4 + 255) & ~255
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: w, height: h, mipmapped: false)
        desc.usage = .renderTarget
        desc.storageMode = .private
        guard let target = device.makeTexture(descriptor: desc),
              let readback = device.makeBuffer(length: bytesPerRow * h, options: .storageModeShared),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return [] }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)

        var images: [CGImage] = []
        for var u in uniforms {
            u.pixelScale = SIMD2(Float(Double(w) / Double(overlay.width)), Float(Double(h) / Double(overlay.height)))
            guard let cb = queue.makeCommandBuffer() else { break }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { break }
            encodeSpread(enc, pipeline: pipeline, uniforms: &u, front: frontTex, back: backTex, revealed: revealedTex)
            enc.endEncoding()
            guard let blit = cb.makeBlitCommandEncoder() else { break }
            blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: w, height: h, depth: 1), to: readback, destinationOffset: 0,
                      destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bytesPerRow * h)
            blit.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
            let data = Data(bytes: readback.contents(), count: bytesPerRow * h) as CFData
            guard let provider = CGDataProvider(data: data),
                  let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                                    space: space, bitmapInfo: info, provider: provider, decode: nil,
                                    shouldInterpolate: false, intent: .defaultIntent) else { break }
            images.append(img)
        }
        return images
    }

    /// Renders curl states into sRGB bitmaps (README / snapshot tests). Synchronous.
    func renderOffscreen(frame: CurlFrame, folds: [CurlFold], top: CGImage, under: CGImage, scale: CGFloat) -> [CGImage] {
        guard let pipeline, !folds.isEmpty, let upload = queue.makeCommandBuffer(),
              let topTex = makeTexture(top, commandBuffer: upload),
              let underTex = makeTexture(under, commandBuffer: upload) else { return [] }
        upload.commit()

        let w = max(1, Int((frame.view.width * scale).rounded()))
        let h = max(1, Int((frame.view.height * scale).rounded()))
        let bytesPerRow = (w * 4 + 255) & ~255
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: w, height: h, mipmapped: false)
        desc.usage = .renderTarget
        desc.storageMode = .private
        guard let target = device.makeTexture(descriptor: desc),
              let readback = device.makeBuffer(length: bytesPerRow * h, options: .storageModeShared),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return [] }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)

        var images: [CGImage] = []
        images.reserveCapacity(folds.count)
        for fold in folds {
            guard let cb = queue.makeCommandBuffer() else { break }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { break }
            var u = CurlUniforms(frame: frame, fold: fold, pixelSize: CGSize(width: w, height: h))
            encode(enc, pipeline: pipeline, uniforms: &u, top: topTex, under: underTex)
            enc.endEncoding()
            guard let blit = cb.makeBlitCommandEncoder() else { break }
            blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: w, height: h, depth: 1), to: readback, destinationOffset: 0,
                      destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bytesPerRow * h)
            blit.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
            let data = Data(bytes: readback.contents(), count: bytesPerRow * h) as CFData
            guard let provider = CGDataProvider(data: data),
                  let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                                    space: space, bitmapInfo: info, provider: provider, decode: nil,
                                    shouldInterpolate: false, intent: .defaultIntent) else { break }
            images.append(img)
        }
        return images
    }
}

/// Small LRU of page textures keyed by bitmap identity (the host caches its bitmaps,
/// so the page that just landed is usually reused by the next turn without an upload).
@MainActor
final class CurlTextureCache {
    private var entries: [(image: CGImage, texture: MTLTexture)] = []
    /// 4 for a single page; an open book holds three pages per turn (front · back · revealed) → 6
    var capacity = 4 {
        didSet { while entries.count > capacity { entries.removeFirst() } }
    }

    func texture(for image: CGImage, gpu: CurlGPU) -> MTLTexture? {
        if let i = entries.firstIndex(where: { $0.image === image }) {
            let e = entries.remove(at: i)
            entries.append(e)
            return e.texture
        }
        guard let cb = gpu.queue.makeCommandBuffer(), let texture = gpu.makeTexture(image, commandBuffer: cb) else { return nil }
        cb.label = "Spiralday.curl.upload"
        cb.commit()
        entries.append((image, texture))
        if entries.count > capacity { entries.removeFirst() }
        return texture
    }

    func purge() { entries.removeAll() }
}
