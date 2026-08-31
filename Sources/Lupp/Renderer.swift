import Accelerate
import CoreGraphics
import Foundation
import Metal
import MetalKit
import simd

/// Metal renderer for a single image quad.
///
/// Shaders are compiled from source at runtime. That is not a workaround for its
/// own sake: the offline `metal` compiler ships with Xcode, not the Command Line
/// Tools, and Lupp is meant to build from a clean clone with CLT alone. Cost is a
/// few milliseconds, once, at first window.
final class Renderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let nearest: MTLSamplerState
    private let linear: MTLSamplerState

    private var texture: MTLTexture?
    private var imageSize = CGSize.zero

    private var lutTexture: MTLTexture?
    private var lutSize = 2
    private var lutDomainMin = SIMD4<Float>(0, 0, 0, 0)
    private var lutDomainMax = SIMD4<Float>(1, 1, 1, 1)
    /// Bound whenever no LUT is loaded. Metal wants a texture at the slot even
    /// though the branch that samples it is switched off.
    private var identityLUT: MTLTexture?
    private var lutSampler: MTLSamplerState?

    /// Above this scale you are inspecting pixels, so show them as squares rather
    /// than a smooth interpolation of pixels that aren't in the file.
    static let nearestThreshold: CGFloat = 2.0

    struct Uniforms {
        var rect: SIMD4<Float>
        var lutDomainMin: SIMD4<Float>
        var lutDomainMax: SIMD4<Float>
        var whiteBalance: SIMD4<Float>
        /// Which part of the source texture the quad samples: u0, v0, u1, v1.
        /// The screen always draws the whole image; export narrows this to the
        /// crop, so a cropped export goes through the same shader as everything
        /// else rather than being assembled separately afterwards.
        var uvRect: SIMD4<Float>
        var exposure: Float
        var checkerSize: Float
        var lutAmount: Float
        var contrast: Float
        var contrastPivot: Float
        var tetraAmount: Float
        var blackPoint: Float
        var whitePoint: Float
        var showChecker: UInt32
        var viewTransform: UInt32
        var channel: UInt32
        var showClipping: UInt32
        var falseColour: UInt32
        var lutEnabled: UInt32
        var tetraEnabled: UInt32
        var lutInput: UInt32
        /// Maps a 0…1 index onto the cube's texel centres. A cube's first and
        /// last entries are its endpoints, but a texture's first and last texel
        /// centres sit half a texel inside the edge — addressing 0…1 directly
        /// therefore squeezes the whole LUT toward its middle.
        var lutScale: Float
        var lutOffset: Float
        /// Export applies the display encode in-shader; the on-screen drawable is
        /// extended-linear and lets CoreAnimation do it instead.
        var encodeOutput: UInt32
    }

    /// The six movable hue corners of the RGB cube. Black, white and the grey
    /// axis are fixed by construction, which is what keeps neutrals neutral.
    struct TetraCorners: Equatable {
        var red = SIMD4<Float>(1, 0, 0, 0)
        var yellow = SIMD4<Float>(1, 1, 0, 0)
        var green = SIMD4<Float>(0, 1, 0, 0)
        var cyan = SIMD4<Float>(0, 1, 1, 0)
        var blue = SIMD4<Float>(0, 0, 1, 0)
        var magenta = SIMD4<Float>(1, 0, 1, 0)

        static let identity = TetraCorners()

        var isIdentity: Bool {
            self == TetraCorners.identity
        }
    }

    struct DisplayState {
        var exposureEV: Float = 0
        /// Per-channel linear gain. Neutral at 1,1,1.
        var whiteBalance = SIMD3<Float>(1, 1, 1)
        /// Power around `contrastPivot`; 1.0 is a no-op.
        var contrast: Float = 1
        var contrastPivot: Float = 0.18
        /// Levels remap applied before everything else. 0 and 1 are a no-op.
        var blackPoint: Float = 0
        var whitePoint: Float = 1

        // A/B bypasses. Nothing is discarded when a section is switched off —
        // its values stay put and simply stop being applied, so comparing costs
        // nothing and toggling back returns exactly where you were.
        var gradeEnabled = true
        var lightOn = true
        var whiteBalanceOn = true
        var tetraOn = true
        var lutOn = true
        /// Set by the panel when the corners are away from identity; there is
        /// nothing to apply when they are not.
        var tetraActive = false

        /// Crop in normalised image coordinates, origin top-left. Kept normalised
        /// so it survives zooming and means the same thing at any window size.
        var cropEnabled = false
        var crop = SIMD4<Float>(0, 0, 1, 1)   // x, y, w, h

        /// Applied: the crop becomes the working image. The source pixels are
        /// still there — nothing is discarded and reverting is free — but zoom,
        /// the readout, the scopes and the export all now describe the crop,
        /// rather than the crop being an overlay you have to keep reading past.
        var cropApplied = false

        /// The window into the source that the canvas should draw.
        var uvWindow: SIMD4<Float> {
            guard cropEnabled, cropApplied else { return SIMD4(0, 0, 1, 1) }
            return SIMD4(crop.x, crop.y, crop.x + crop.z, crop.y + crop.w)
        }

        /// The crop in pixels, for the export and the readout.
        func cropPixels(imageWidth w: Int, imageHeight h: Int) -> (x: Int, y: Int, w: Int, h: Int) {
            guard cropEnabled else { return (0, 0, w, h) }
            let x = Int((crop.x * Float(w)).rounded())
            let y = Int((crop.y * Float(h)).rounded())
            let cw = max(1, Int((crop.z * Float(w)).rounded()))
            let ch = max(1, Int((crop.w * Float(h)).rounded()))
            return (min(x, w - 1), min(y, h - 1), min(cw, w - x), min(ch, h - y))
        }
        var viewTransform: ViewTransform = .standard
        var channel: ChannelView = .rgb
        var showClipping = false
        var falseColour = false
        var lutAmount: Float = 1
        var lutName: String?
        var lutInput: LUTInput = .display
        var tetra = TetraCorners()
        var tetraAmount: Float = 1
    }

    init?(pixelFormat: MTLPixelFormat) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue

        do {
            let lib = try device.makeLibrary(source: Renderer.shaderSource, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = lib.makeFunction(name: "lupp_vertex")
            desc.fragmentFunction = lib.makeFunction(name: "lupp_fragment")
            desc.colorAttachments[0].pixelFormat = pixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            NSLog("Lupp: shader compilation failed — %@", String(describing: error))
            return nil
        }

        let mk: (MTLSamplerMinMagFilter) -> MTLSamplerState? = { filter in
            let s = MTLSamplerDescriptor()
            s.minFilter = filter
            s.magFilter = filter
            s.sAddressMode = .clampToEdge
            s.tAddressMode = .clampToEdge
            return device.makeSamplerState(descriptor: s)
        }
        guard let n = mk(.nearest), let l = mk(.linear) else { return nil }
        nearest = n
        linear = l

        let ls = MTLSamplerDescriptor()
        ls.minFilter = .linear
        ls.magFilter = .linear
        ls.sAddressMode = .clampToEdge
        ls.tAddressMode = .clampToEdge
        ls.rAddressMode = .clampToEdge
        lutSampler = device.makeSamplerState(descriptor: ls)
        identityLUT = Renderer.makeIdentityLUT(device: device)
    }

    // MARK: - LUT

    /// Trilinear sampling of a 3D texture is exactly what a cube LUT means, so
    /// the GPU does the interpolation the format was designed around.
    func loadLUT(_ lut: CubeLUT) -> Bool {
        let n = lut.size
        let desc = MTLTextureDescriptor()
        desc.textureType = .type3D
        desc.pixelFormat = .rgba16Float      // universally filterable; 32-bit float is not
        desc.width = n; desc.height = n; desc.depth = n
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return false }

        var half = [UInt16](repeating: 0, count: lut.rgba.count)
        for i in 0..<lut.rgba.count { half[i] = Float16(lut.rgba[i]).bitPattern }
        half.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake3D(0, 0, 0, n, n, n), mipmapLevel: 0, slice: 0,
                        withBytes: raw.baseAddress!,
                        bytesPerRow: n * 8, bytesPerImage: n * n * 8)
        }
        lutTexture = tex
        lutSize = n
        lutDomainMin = SIMD4(lut.domainMin, 0)
        lutDomainMax = SIMD4(lut.domainMax, 1)
        return true
    }

    func clearLUT() { lutTexture = nil }

    var hasLUT: Bool { lutTexture != nil }

    private static func makeIdentityLUT(device: MTLDevice) -> MTLTexture? {
        let n = 2
        let desc = MTLTextureDescriptor()
        desc.textureType = .type3D
        desc.pixelFormat = .rgba16Float
        desc.width = n; desc.height = n; desc.depth = n
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        var data = [UInt16](repeating: 0, count: n * n * n * 4)
        var i = 0
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            data[i] = Float16(Float(r)).bitPattern
            data[i + 1] = Float16(Float(g)).bitPattern
            data[i + 2] = Float16(Float(b)).bitPattern
            data[i + 3] = Float16(1).bitPattern
            i += 4
        }}}
        data.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake3D(0, 0, 0, n, n, n), mipmapLevel: 0, slice: 0,
                        withBytes: raw.baseAddress!,
                        bytesPerRow: n * 8, bytesPerImage: n * n * 8)
        }
        return tex
    }

    // MARK: - Upload

    /// Display gets fp16; the readout keeps reading the float32 CPU buffer.
    /// fp16 carries far more precision than any display can show, and halves the
    /// texture footprint on images where that actually matters.
    func upload(_ image: FloatImage) {
        imageSize = CGSize(width: image.width, height: image.height)
        let w = image.width, h = image.height

        let halfCount = w * h * 4
        let half = UnsafeMutablePointer<UInt16>.allocate(capacity: halfCount)
        defer { half.deallocate() }

        var srcBuf = vImage_Buffer(data: image.pixels, height: vImagePixelCount(h),
                                   width: vImagePixelCount(w * 4), rowBytes: w * 16)
        var dstBuf = vImage_Buffer(data: half, height: vImagePixelCount(h),
                                   width: vImagePixelCount(w * 4), rowBytes: w * 8)
        if vImageConvert_PlanarFtoPlanar16F(&srcBuf, &dstBuf, vImage_Flags(kvImageNoFlags)) != kvImageNoError {
            for i in 0..<halfCount { half[i] = Float16(image.pixels[i]).bitPattern }
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { texture = nil; return }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                    withBytes: half, bytesPerRow: w * 8)
        texture = tex
    }

    func discard() {
        texture = nil
        imageSize = .zero
    }

    // MARK: - Draw

    func draw(in view: MTKView, viewport: Viewport, display: DisplayState,
              dragHighlight: Bool = false, backingScale: CGFloat) {
        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor else { return }
        // A visible lift while a file is over the window, so a drop reads as
        // landing somewhere rather than being swallowed. Semi-transparent, since
        // the surround itself is now the window's background showing through.
        if dragHighlight {
            pass.colorAttachments[0].clearColor =
                MTLClearColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.22)
        }
        guard
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }

        if let tex = texture, imageSize.width > 0, imageSize.height > 0 {
            let vw = view.bounds.width, vh = view.bounds.height

            // An applied crop is the working image, so the quad takes the crop's
            // size — not the file's. Without this the UV window narrows to the
            // crop while the quad stays full-frame, and the crop is stretched
            // across the wrong aspect.
            let cp = display.cropPixels(imageWidth: Int(imageSize.width),
                                        imageHeight: Int(imageSize.height))
            let drawn = (display.cropEnabled && display.cropApplied)
                ? CGSize(width: CGFloat(cp.w), height: CGFloat(cp.h))
                : imageSize

            // Image rect in flipped view points, then into clip space (y up).
            let x0 = viewport.origin.x
            let y0 = viewport.origin.y
            let x1 = x0 + drawn.width * viewport.scale
            let y1 = y0 + drawn.height * viewport.scale

            let rect = SIMD4<Float>(
                Float(x0 / vw * 2 - 1),
                Float(1 - y1 / vh * 2),   // bottom edge in clip space
                Float(x1 / vw * 2 - 1),
                Float(1 - y0 / vh * 2))   // top edge

            var u = uniforms(for: display, rect: rect,
                             checkerSize: Float(12 * backingScale),
                             showChecker: 1, encodeOutput: 0,
                             uvRect: display.uvWindow)
            enc.setRenderPipelineState(pipeline)
            var tetra = display.tetra
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setFragmentBytes(&tetra, length: MemoryLayout<TetraCorners>.stride, index: 1)
            enc.setFragmentTexture(tex, index: 0)
            enc.setFragmentTexture(lutTexture ?? identityLUT, index: 1)
            if let lutSampler { enc.setFragmentSamplerState(lutSampler, index: 1) }
            enc.setFragmentSamplerState(
                viewport.scale >= Renderer.nearestThreshold ? nearest : linear, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    // MARK: - Offscreen

    /// Render `display` into an offscreen texture and hand back the raw fp16.
    ///
    /// Export, the scopes and the crop loupe all want the same thing at different
    /// sizes and through different windows, and each had its own copy of the
    /// descriptor / pass / encode / synchronise / read-back dance. Three copies of
    /// that is three chances for one of them to drift out of step with the
    /// screen — which has already happened once, with the uniforms.
    private func offscreen(width w: Int, height h: Int, uv: SIMD4<Float>,
                           display: DisplayState, filter: MTLSamplerState) -> [UInt16]? {
        guard let source = texture, w > 0, h > 0 else { return nil }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        // Shared storage can be read back directly; discrete GPUs need managed
        // memory plus an explicit synchronise before the CPU may look at it.
        let unified = device.hasUnifiedMemory
        desc.storageMode = unified ? .shared : .managed
        guard let target = device.makeTexture(descriptor: desc) else { return nil }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return nil }

        var u = uniforms(for: display, rect: SIMD4<Float>(-1, -1, 1, 1),
                         checkerSize: 1, showChecker: 0, encodeOutput: 1, uvRect: uv)
        var tetra = display.tetra
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setFragmentBytes(&tetra, length: MemoryLayout<TetraCorners>.stride, index: 1)
        enc.setFragmentTexture(source, index: 0)
        enc.setFragmentTexture(lutTexture ?? identityLUT, index: 1)
        enc.setFragmentSamplerState(filter, index: 0)
        if let lutSampler { enc.setFragmentSamplerState(lutSampler, index: 1) }
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()

        if !unified, let blit = cmd.makeBlitCommandEncoder() {
            blit.synchronize(resource: target)
            blit.endEncoding()
        }
        cmd.commit()
        cmd.waitUntilCompleted()

        var half = [UInt16](repeating: 0, count: w * h * 4)
        half.withUnsafeMutableBytes { raw in
            target.getBytes(raw.baseAddress!, bytesPerRow: w * 8,
                            from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        return half
    }

    // MARK: - Export

    /// Render the current image at full resolution through the same shader the
    /// screen uses, so an export is exactly what was on screen rather than a
    /// second implementation that can drift from it.
    ///
    /// Returns display-encoded sRGB with straight alpha — no checkerboard, since
    /// transparency should survive into the file rather than be painted over.
    func exportImage(size: CGSize, display: DisplayState, bitDepth: Int) -> CGImage? {
        let full = (w: Int(size.width), h: Int(size.height))
        guard full.w > 0, full.h > 0 else { return nil }

        // Export the crop at its own pixel size — a crop should produce a smaller
        // file, not the same file with the surroundings painted out.
        let c = display.cropPixels(imageWidth: full.w, imageHeight: full.h)
        let uv = SIMD4<Float>(Float(c.x) / Float(full.w),
                              Float(c.y) / Float(full.h),
                              Float(c.x + c.w) / Float(full.w),
                              Float(c.y + c.h) / Float(full.h))

        // Nearest: this is 1:1, so there is nothing to filter.
        guard let half = offscreen(width: c.w, height: c.h, uv: uv,
                                   display: display, filter: nearest) else { return nil }
        return Renderer.cgImage(fromHalf: half, width: c.w, height: c.h, bitDepth: bitDepth)
    }

    /// Render the graded image small, for the scopes to measure.
    ///
    /// Scopes have to describe what is on screen, not the file — a histogram that
    /// ignores the grade is worse than no histogram. Rendering through the same
    /// shader is the only way to guarantee they agree; measuring the source on the
    /// CPU would be a second implementation of the whole chain, free to drift.
    ///
    /// Downsampled because a few hundred thousand samples are statistically
    /// indistinguishable from millions here, and this runs on every slider tick.
    /// Returns display-encoded RGBA — what the scopes want — which the CIE plot
    /// linearises again for itself.
    func renderSampled(display: DisplayState, maxDimension: Int) -> (data: [Float], width: Int, height: Int)? {
        guard let source = texture else { return nil }
        let sw = source.width, sh = source.height
        guard sw > 0, sh > 0 else { return nil }
        let k = min(1.0, Double(maxDimension) / Double(max(sw, sh)))
        let w = max(1, Int((Double(sw) * k).rounded())), h = max(1, Int((Double(sh) * k).rounded()))

        guard let half = offscreen(width: w, height: h, uv: display.uvWindow,
                                   display: display, filter: linear) else { return nil }
        var out = [Float](repeating: 0, count: w * h * 4)
        for i in 0..<out.count { out[i] = Float(Float16(bitPattern: half[i])) }
        return (out, w, h)
    }

    /// A graded render of an arbitrary window into the source, used by the crop
    /// loupe. Goes through the same shader, so the magnifier shows the picture as
    /// it actually is rather than the ungraded file underneath it.
    func renderWindow(uv: SIMD4<Float>, width: Int, height: Int,
                      display: DisplayState) -> CGImage? {
        // Nearest: a magnifier should show pixels, not a blur of them.
        guard let half = offscreen(width: width, height: height, uv: uv,
                                   display: display, filter: nearest) else { return nil }
        return Renderer.cgImage(fromHalf: half, width: width, height: height, bitDepth: 8)
    }

    private func uniforms(for display: DisplayState, rect: SIMD4<Float>,
                          checkerSize: Float, showChecker: UInt32,
                          encodeOutput: UInt32,
                          uvRect: SIMD4<Float> = SIMD4(0, 0, 1, 1)) -> Uniforms {
        // Bypasses are resolved here rather than in the shader: a switched-off
        // section is simply fed its identity values, so there is one code path
        // through the fragment function and no branch that can drift.
        let master = display.gradeEnabled
        let light = master && display.lightOn
        let balance = master && display.whiteBalanceOn
        let tetra = master && display.tetraOn && display.tetraActive
        let lut = master && display.lutOn && lutTexture != nil

        return Uniforms(rect: rect,
                 lutDomainMin: lutDomainMin,
                 lutDomainMax: lutDomainMax,
                 whiteBalance: balance ? SIMD4(display.whiteBalance, 0) : SIMD4(1, 1, 1, 0),
                 uvRect: uvRect,
                 exposure: light ? pow(2, display.exposureEV) : 1,
                 checkerSize: checkerSize,
                 lutAmount: display.lutAmount,
                 contrast: light ? display.contrast : 1,
                 contrastPivot: display.contrastPivot,
                 tetraAmount: display.tetraAmount,
                 blackPoint: light ? display.blackPoint : 0,
                 whitePoint: light ? display.whitePoint : 1,
                 showChecker: showChecker,
                 viewTransform: UInt32(display.viewTransform.rawValue),
                 channel: UInt32(display.channel.rawValue),
                 showClipping: display.showClipping ? 1 : 0,
                 falseColour: display.falseColour ? 1 : 0,
                 lutEnabled: lut ? 1 : 0,
                 tetraEnabled: tetra ? 1 : 0,
                 lutInput: UInt32(display.lutInput.rawValue),
                 lutScale: Float(lutSize - 1) / Float(lutSize),
                 lutOffset: 0.5 / Float(lutSize),
                 encodeOutput: encodeOutput)
    }

    private static func cgImage(fromHalf half: [UInt16], width w: Int, height h: Int,
                                bitDepth: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let n = w * h * 4

        func finish(_ data: Data, bpc: Int) -> CGImage? {
            guard let provider = CGDataProvider(data: data as CFData) else { return nil }
            return CGImage(width: w, height: h, bitsPerComponent: bpc, bitsPerPixel: bpc * 4,
                           bytesPerRow: w * 4 * (bpc / 8), space: space,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                           provider: provider, decode: nil,
                           shouldInterpolate: false, intent: .defaultIntent)
        }

        if bitDepth >= 16 {
            var out = [UInt16](repeating: 0, count: n)
            for i in 0..<n {
                let v = Float(Float16(bitPattern: half[i]))
                out[i] = UInt16(min(max(v, 0), 1) * 65535 + 0.5)
            }
            return out.withUnsafeBufferPointer { finish(Data(buffer: $0), bpc: 16) }
        }
        var out = [UInt8](repeating: 0, count: n)
        for i in 0..<n {
            let v = Float(Float16(bitPattern: half[i]))
            out[i] = UInt8(min(max(v, 0), 1) * 255 + 0.5)
        }
        return out.withUnsafeBufferPointer { finish(Data(buffer: $0), bpc: 8) }
    }

    // MARK: - Shaders

    /// The canvas background is injected rather than duplicated, so the shader
    /// and the chrome stay the single colour defined in Theme.
    private static var shaderSource: String {
        "#define BG_LINEAR \(Theme.backgroundLinear)\n" + shaderBody
    }

    private static let shaderBody = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float4 rect;
        float4 lutDomainMin;
        float4 lutDomainMax;
        float4 whiteBalance;
        float4 uvRect;
        float  exposure;
        float  checkerSize;
        float  lutAmount;
        float  contrast;
        float  contrastPivot;
        float  tetraAmount;
        float  blackPoint;
        float  whitePoint;
        uint   showChecker;
        uint   viewTransform;
        uint   channel;
        uint   showClipping;
        uint   falseColour;
        uint   lutEnabled;
        uint   tetraEnabled;
        uint   lutInput;
        float  lutScale;
        float  lutOffset;
        uint   encodeOutput;
    };

    /// Normalised value to a cube lookup coordinate, landing on texel centres.
    float3 lutCoord(float3 v, constant Uniforms &u) {
        float3 span = max(u.lutDomainMax.xyz - u.lutDomainMin.xyz, 1e-6);
        float3 t = clamp((v - u.lutDomainMin.xyz) / span, 0.0, 1.0);
        return t * u.lutScale + u.lutOffset;
    }

    // Scene-linear to a camera log encoding, using each vendor's published
    // formula. These are transfer curves only — see the note in the README about
    // gamut, which a .cube also assumes and which a file rarely tells us.
    float3 linearToLog(float3 x, uint kind) {
        if (kind == 1u) {                       // Sony S-Log3
            return select((x * (171.2102946929 - 95.0) / 0.01125000 + 95.0) / 1023.0,
                          (420.0 + log10((x + 0.01) / 0.19) * 261.5) / 1023.0,
                          x >= 0.01125000);
        }
        if (kind == 2u) {                       // ARRI LogC3, EI 800
            const float cut = 0.010591, a = 5.555556, b = 0.052272;
            const float c = 0.247190, d = 0.385537, e = 5.367655, f = 0.092809;
            return select(e * x + f, c * log10(a * x + b) + d, x > cut);
        }
        if (kind == 4u) {                       // Panasonic V-Log
            const float cut = 0.01, b = 0.00873, c = 0.241514, d = 0.598206;
            return select(5.6 * x + 0.125, c * log10(x + b) + d, x >= cut);
        }
        if (kind == 3u) {                       // ACEScct
            const float brk = 0.0078125, A = 10.5402377416545, B = 0.0729055341958355;
            return select(A * x + B, (log2(max(x, 1e-10)) + 9.72) / 17.52, x > brk);
        }
        return x;
    }

    // Contrast as a power around a pivot, in linear.
    //
    // Pivoted at 0.18 — scene mid grey — so raising contrast pushes highlights up
    // and shadows down around the same point a grader thinks of as middle, rather
    // than around whatever 0.5 happens to mean in the current encoding.
    float3 applyContrast(float3 c, float amount, float pivot) {
        if (amount == 1.0) return c;
        return pivot * pow(max(c, 1e-6) / max(pivot, 1e-6), amount);
    }

    struct TetraCorners {
        float4 red, yellow, green, cyan, blue, magenta;
    };

    // Tetrahedral interpolation of the RGB cube, after hotgluebanjo's TetraInterp.
    //
    // The cube splits into six tetrahedra by the ordering of r, g and b. Each has
    // black and white as two of its vertices, so those — and the whole grey axis
    // between them — are fixed no matter where the six hue corners are moved.
    // That is the property that makes it a colour warp rather than a tint: it
    // cannot push a neutral off neutral.
    //
    // With the corners left at (1,0,0), (1,1,0) … it is exactly the identity.
    float3 tetraInterp(float3 c, constant TetraCorners &t) {
        float r = c.r, g = c.g, b = c.b;
        const float3 W = float3(1.0);
        // The (1 - max) * black term is omitted throughout: black is the origin.
        if (r > g) {
            if (g > b)      return (r - g) * t.red.rgb   + (g - b) * t.yellow.rgb  + b * W;
            else if (r > b) return (r - b) * t.red.rgb   + (b - g) * t.magenta.rgb + g * W;
            else            return (b - r) * t.blue.rgb  + (r - g) * t.magenta.rgb + g * W;
        } else {
            if (b > g)      return (b - g) * t.blue.rgb  + (g - r) * t.cyan.rgb    + r * W;
            else if (b > r) return (g - b) * t.green.rgb + (b - r) * t.cyan.rgb    + r * W;
            else            return (g - r) * t.green.rgb + (r - b) * t.yellow.rgb  + b * W;
        }
    }

    // The drawable is extended-LINEAR sRGB: CoreAnimation applies the display
    // encode itself. So every branch below must hand back linear values, and a
    // transform whose output is display-referred has to be linearised again
    // before it is written — otherwise it gets encoded twice.
    float3 srgbToLinear(float3 c) {
        return select(c / 12.92, pow((c + 0.055) / 1.055, 2.4), c > 0.04045);
    }
    float3 linearToSrgb(float3 c) {
        c = clamp(c, 0.0, 1.0);
        return select(c * 12.92, 1.055 * pow(c, 1.0 / 2.4) - 0.055, c > 0.0031308);
    }

    // AgX, following the widely used analytic approximation of Blender's default
    // view transform. Close to AgX Base, but an approximation, not the LUTs.
    float3 agxContrast(float3 x) {
        float3 x2 = x * x;
        float3 x4 = x2 * x2;
        return  15.5 * x4 * x2 - 40.14 * x4 * x + 31.96 * x4
              - 6.868 * x2 * x + 0.4298 * x2 + 0.1191 * x - 0.00232;
    }

    float3 agx(float3 c) {
        const float3x3 inset = float3x3(
            float3(0.8566271, 0.0951212, 0.0482516),
            float3(0.1373402, 0.7612197, 0.1014390),
            float3(0.1118982, 0.0767994, 0.8113024));
        const float3x3 outset = float3x3(
            float3( 1.1271006, -0.1106066, -0.0164939),
            float3(-0.1413298,  1.1578237, -0.0164939),
            float3(-0.1413298, -0.1106066,  1.2519364));
        const float minEv = -12.47393, maxEv = 4.026069;

        c = inset * max(c, 0.0);
        c = clamp(log2(max(c, 1e-10)), minEv, maxEv);
        c = (c - minEv) / (maxEv - minEv);
        c = agxContrast(c);
        c = outset * c;
        return pow(max(c, 0.0), 2.2);          // back to linear
    }

    // ACES filmic: the Hill/Narkowicz RRT+ODT fit, in AP1. Returns linear.
    float3 aces(float3 c) {
        const float3x3 inMat = float3x3(
            float3(0.59719, 0.07600, 0.02840),
            float3(0.35458, 0.90834, 0.13383),
            float3(0.04823, 0.01566, 0.83777));
        const float3x3 outMat = float3x3(
            float3( 1.60475, -0.10208, -0.00327),
            float3(-0.53108,  1.10813, -0.07276),
            float3(-0.07367, -0.00605,  1.07602));
        c = inMat * max(c, 0.0);
        float3 a = c * (c + 0.0245786) - 0.000090537;
        float3 b = c * (0.983729 * c + 0.4329510) + 0.238081;
        c = outMat * (a / b);
        return clamp(c, 0.0, 1.0);
    }

    float3 applyView(float3 c, uint mode) {
        if (mode == 1u) return agx(c);
        if (mode == 2u) return aces(c);
        // Blender's Raw: the value goes to the display unencoded, so pre-linearise
        // to cancel the encode CoreAnimation is about to apply.
        if (mode == 3u) return srgbToLinear(clamp(c, 0.0, 1.0));
        // Standard: straight through. Above 1.0 survives to an EDR display rather
        // than being clipped away, which is half the point of the float pipeline.
        return max(c, 0.0);
    }

    float srgbEncode1(float c) {
        c = clamp(c, 0.0, 1.0);
        return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1.0 / 2.4) - 0.055;
    }

    // False colour reads the *source* luminance, not the tone-mapped result.
    // Judging it after a view transform is meaningless: AgX rolls everything into
    // range, so a blown render would report as perfectly exposed.
    //
    // Bands sit at sRGB-encoded positions of meaningful linear values — 0.18 mid
    // grey encodes to 0.462, skin about a stop above that. Everything between the
    // bands stays a monochrome ramp so the picture is still legible underneath.
    float3 falseColourOf(float linearLuma) {
        if (linearLuma >= 1.0)  return float3(0.95, 0.12, 0.12);   // clipped
        if (linearLuma <= 0.0)  return float3(0.30, 0.09, 0.52);   // at or below black

        float e = srgbEncode1(linearLuma);
        if (e < 0.020) return float3(0.44, 0.14, 0.64);            // crushed
        if (e < 0.100) return float3(0.16, 0.38, 0.88);            // deep shadow
        if (e >= 0.440 && e < 0.484) return float3(0.16, 0.82, 0.24);  // 18% grey
        if (e >= 0.605 && e < 0.650) return float3(0.97, 0.60, 0.72);  // skin
        if (e >= 0.940) return float3(0.97, 0.86, 0.18);           // near clip
        return float3(e);
    }

    struct VOut {
        float4 pos [[position]];
        float2 uv;
    };

    vertex VOut lupp_vertex(uint vid [[vertex_id]], constant Uniforms &u [[buffer(0)]]) {
        float2 c = float2(float(vid & 1u), float((vid >> 1) & 1u));
        VOut o;
        o.pos = float4(mix(u.rect.xy, u.rect.zw, c), 0.0, 1.0);
        // Window into the source, so a cropped export samples only what it keeps.
        o.uv  = mix(u.uvRect.xy, u.uvRect.zw, float2(c.x, 1.0 - c.y));
        return o;
    }

    fragment float4 lupp_fragment(VOut in [[stage_in]],
                                  texture2d<float> tex [[texture(0)]],
                                  texture3d<float> lut [[texture(1)]],
                                  sampler smp [[sampler(0)]],
                                  sampler lutSmp [[sampler(1)]],
                                  constant Uniforms &u [[buffer(0)]],
                                  constant TetraCorners &tetra [[buffer(1)]]) {
        float4 c = tex.sample(smp, in.uv);

        // The linear grade, in the order a colourist expects: set the range, then
        // exposure, then white balance, then contrast — all before any tone map,
        // so they behave like light rather than like adjustments to an
        // already-rendered picture.
        //
        // Black and white point come first because they say what counts as black
        // and white in the source; everything after is working in those terms.
        float3 rgb = (c.rgb - u.blackPoint) / max(u.whitePoint - u.blackPoint, 1e-4);
        rgb = rgb * u.exposure * u.whiteBalance.rgb;
        rgb = applyContrast(rgb, u.contrast, u.contrastPivot);

        // Clipping is a fact about the graded data, so it is judged here — before
        // any tone map, which would otherwise roll off exactly what this overlay
        // exists to reveal.
        bool over  = any(rgb > 1.0);
        bool under = any(rgb < 0.0);
        float3 graded = rgb;

        switch (u.channel) {
            case 1u: rgb = float3(rgb.r); break;
            case 2u: rgb = float3(rgb.g); break;
            case 3u: rgb = float3(rgb.b); break;
            case 4u: rgb = float3(c.a);   break;
            case 5u: rgb = float3(dot(rgb, float3(0.2126, 0.7152, 0.0722))); break;
            default: break;
        }

        float alpha = (u.channel == 4u) ? 1.0 : c.a;
        // Luma of the graded linear value, kept before the view transform so
        // false colour describes the data rather than the look applied to it.
        float srcLuma = dot(max(graded, 0.0), float3(0.2126, 0.7152, 0.0722));
        if (over) { srcLuma = max(srcLuma, 1.0); }

        // Everything from here is in the display domain, where the cube corners
        // and a creative .cube are both defined.
        float3 enc;
        bool logLUT = u.lutEnabled != 0u && u.lutInput != 0u && u.lutAmount > 0.0;

        if (logLUT) {
            // A log LUT *is* the display rendering: feed it the log-encoded scene
            // values and take its output as already display-referred. Running the
            // view transform as well would tone-map twice.
            float3 lv = linearToLog(max(rgb, 0.0), u.lutInput);
            float3 looked = lut.sample(lutSmp, lutCoord(lv, u)).rgb;
            // Blended against the ordinary look, so the amount slider still means
            // something rather than fading toward black.
            enc = mix(clamp(linearToSrgb(applyView(rgb, u.viewTransform)), 0.0, 1.0),
                      looked, u.lutAmount);
        } else {
            enc = clamp(linearToSrgb(applyView(rgb, u.viewTransform)), 0.0, 1.0);
            if (u.lutEnabled != 0u && u.lutAmount > 0.0) {
                enc = mix(enc, lut.sample(lutSmp, lutCoord(enc, u)).rgb, u.lutAmount);
            }
        }

        if (u.tetraEnabled != 0u && u.tetraAmount > 0.0) {
            enc = clamp(mix(enc, tetraInterp(enc, tetra), u.tetraAmount), 0.0, 1.0);
        }
        rgb = srgbToLinear(enc);

        if (u.falseColour != 0u) {
            rgb = srgbToLinear(falseColourOf(srcLuma));
            alpha = 1.0;
        } else if (u.showClipping != 0u && (over || under)) {
            float3 mark = over ? float3(0.95, 0.10, 0.10) : float3(0.10, 0.45, 0.95);
            rgb = mix(rgb, srgbToLinear(mark), 0.8);
        }

        // Straight alpha in, opaque out: composite here so the pipeline needs no
        // blending and values above 1.0 survive to the EDR drawable untouched.
        // Export keeps alpha and encodes here; the screen composites over the
        // checker and leaves the encode to CoreAnimation.
        if (u.encodeOutput != 0u) {
            return float4(linearToSrgb(rgb), alpha);
        }

        float3 bg = float3(BG_LINEAR);
        if (u.showChecker != 0u && alpha < 0.999) {
            float2 g = floor(in.pos.xy / u.checkerSize);
            bg = (fmod(g.x + g.y, 2.0) < 1.0) ? float3(0.19) : float3(0.26);
        }
        return float4(mix(bg, rgb, alpha), 1.0);
    }
    """
}
