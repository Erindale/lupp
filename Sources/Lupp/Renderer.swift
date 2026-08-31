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

    /// Above this scale you are inspecting pixels, so show them as squares rather
    /// than a smooth interpolation of pixels that aren't in the file.
    static let nearestThreshold: CGFloat = 2.0

    struct Uniforms {
        var rect: SIMD4<Float>
        var exposure: Float
        var checkerSize: Float
        var showChecker: UInt32
        var _pad: UInt32 = 0
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

    func draw(in view: MTKView, viewport: Viewport, exposure: Float, backingScale: CGFloat) {
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
                             exposure: exposure,
                             checkerSize: Float(12 * backingScale),
                             showChecker: 1)
            enc.setRenderPipelineState(pipeline)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setFragmentTexture(tex, index: 0)
            enc.setFragmentSamplerState(
                viewport.scale >= Renderer.nearestThreshold ? nearest : linear, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    // MARK: - Shaders

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float4 rect;
        float  exposure;
        float  checkerSize;
        uint   showChecker;
        uint   pad;
    };

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
                                  sampler smp [[sampler(0)]],
                                  constant Uniforms &u [[buffer(0)]]) {
        float4 c = tex.sample(smp, in.uv);
        float3 rgb = c.rgb * u.exposure;

        // Straight alpha in, opaque out: composite here so the pipeline needs no
        // blending and values above 1.0 survive to the EDR drawable untouched.
        float3 bg = float3(0.055);
        if (u.showChecker != 0u && c.a < 0.999) {
            float2 g = floor(in.pos.xy / u.checkerSize);
            bg = (fmod(g.x + g.y, 2.0) < 1.0) ? float3(0.19) : float3(0.26);
        }
        return float4(mix(bg, rgb, c.a), 1.0);
    }
    """
}
