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
        var exposure: Float
        var checkerSize: Float
        var lutAmount: Float
        var showChecker: UInt32
        var viewTransform: UInt32
        var channel: UInt32
        var showClipping: UInt32
        var falseColour: UInt32
        var lutEnabled: UInt32
        var _pad0: UInt32 = 0
        var _pad1: UInt32 = 0
        var _pad2: UInt32 = 0
    }

    struct DisplayState {
        var exposureEV: Float = 0
        var viewTransform: ViewTransform = .standard
        var channel: ChannelView = .rgb
        var showClipping = false
        var falseColour = false
        var lutAmount: Float = 1
        var lutName: String?
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

    func draw(in view: MTKView, viewport: Viewport, display: DisplayState, backingScale: CGFloat) {
        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }

        if let tex = texture, imageSize.width > 0, imageSize.height > 0 {
            let vw = view.bounds.width, vh = view.bounds.height
            // Image rect in flipped view points, then into clip space (y up).
            let x0 = viewport.origin.x
            let y0 = viewport.origin.y
            let x1 = x0 + imageSize.width * viewport.scale
            let y1 = y0 + imageSize.height * viewport.scale

            let rect = SIMD4<Float>(
                Float(x0 / vw * 2 - 1),
                Float(1 - y1 / vh * 2),   // bottom edge in clip space
                Float(x1 / vw * 2 - 1),
                Float(1 - y0 / vh * 2))   // top edge

            var u = Uniforms(rect: rect,
                             lutDomainMin: lutDomainMin,
                             lutDomainMax: lutDomainMax,
                             exposure: pow(2, display.exposureEV),
                             checkerSize: Float(12 * backingScale),
                             lutAmount: display.lutAmount,
                             showChecker: 1,
                             viewTransform: UInt32(display.viewTransform.rawValue),
                             channel: UInt32(display.channel.rawValue),
                             showClipping: display.showClipping ? 1 : 0,
                             falseColour: display.falseColour ? 1 : 0,
                             lutEnabled: lutTexture != nil ? 1 : 0)
            enc.setRenderPipelineState(pipeline)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
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
        float  exposure;
        float  checkerSize;
        float  lutAmount;
        uint   showChecker;
        uint   viewTransform;
        uint   channel;
        uint   showClipping;
        uint   falseColour;
        uint   lutEnabled;
        uint   pad0;
        uint   pad1;
        uint   pad2;
    };

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
        o.uv  = float2(c.x, 1.0 - c.y);
        return o;
    }

    fragment float4 lupp_fragment(VOut in [[stage_in]],
                                  texture2d<float> tex [[texture(0)]],
                                  texture3d<float> lut [[texture(1)]],
                                  sampler smp [[sampler(0)]],
                                  sampler lutSmp [[sampler(1)]],
                                  constant Uniforms &u [[buffer(0)]]) {
        float4 c = tex.sample(smp, in.uv);
        float3 rgb = c.rgb * u.exposure;

        // Clipping is a fact about the data, so it is judged on the exposed linear
        // values before any tone map — a transform that rolls off highlights would
        // otherwise hide exactly what this overlay exists to reveal.
        bool over  = any(rgb > 1.0);
        bool under = any(rgb < 0.0);

        switch (u.channel) {
            case 1u: rgb = float3(rgb.r); break;
            case 2u: rgb = float3(rgb.g); break;
            case 3u: rgb = float3(rgb.b); break;
            case 4u: rgb = float3(c.a);   break;
            case 5u: rgb = float3(dot(rgb, float3(0.2126, 0.7152, 0.0722))); break;
            default: break;
        }

        float alpha = (u.channel == 4u) ? 1.0 : c.a;
        // Luma of the exposed source, kept before the view transform so false
        // colour describes the data rather than the look applied to it.
        float srcLuma = dot(max(c.rgb * u.exposure, 0.0), float3(0.2126, 0.7152, 0.0722));
        if (any(c.rgb * u.exposure > 1.0)) { srcLuma = max(srcLuma, 1.0); }

        rgb = applyView(rgb, u.viewTransform);

        // A creative .cube LUT expects display-encoded input, so it goes on after
        // the view transform, in that domain, and comes back to linear for the
        // drawable. A LUT authored for log input will not be right here — that
        // needs an input transform Lupp doesn't have yet.
        if (u.lutEnabled != 0u && u.lutAmount > 0.0) {
            float3 enc = linearToSrgb(rgb);
            float3 span = max(u.lutDomainMax.xyz - u.lutDomainMin.xyz, 1e-6);
            float3 idx = clamp((enc - u.lutDomainMin.xyz) / span, 0.0, 1.0);
            float3 looked = lut.sample(lutSmp, idx).rgb;
            rgb = srgbToLinear(mix(enc, looked, u.lutAmount));
        }

        if (u.falseColour != 0u) {
            rgb = srgbToLinear(falseColourOf(srcLuma));
            alpha = 1.0;
        } else if (u.showClipping != 0u && (over || under)) {
            float3 mark = over ? float3(0.95, 0.10, 0.10) : float3(0.10, 0.45, 0.95);
            rgb = mix(rgb, srgbToLinear(mark), 0.8);
        }

        // Straight alpha in, opaque out: composite here so the pipeline needs no
        // blending and values above 1.0 survive to the EDR drawable untouched.
        float3 bg = float3(BG_LINEAR);
        if (u.showChecker != 0u && alpha < 0.999) {
            float2 g = floor(in.pos.xy / u.checkerSize);
            bg = (fmod(g.x + g.y, 2.0) < 1.0) ? float3(0.19) : float3(0.26);
        }
        return float4(mix(bg, rgb, alpha), 1.0);
    }
    """
}
