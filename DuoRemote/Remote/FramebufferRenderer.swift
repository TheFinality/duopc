import Metal
import QuartzCore
import IOSurface

/// Draws the remote framebuffer: one textured quad, transformed by the viewport. The texture
/// wraps the library's IOSurface directly (zero copy), so redrawing picks up whatever the
/// decoder has written since.
final class FramebufferRenderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let linear: MTLSamplerState
    private let nearest: MTLSamplerState
    private var texture: MTLTexture?
    /// Drawables handed out but not yet on screen. Kept ≤ 2 so `nextDrawable()` never has to
    /// wait (it blocks the main thread for up to a second when none are free — e.g. while a fold
    /// moves the window between the Duo's displays).
    private var pending = 0
    private var textureSurface: IOSurface?

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.shaderSource, options: nil) else { return nil }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "framebufferVertex")
        desc.fragmentFunction = library.makeFunction(name: "framebufferFragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
        func sampler(_ filter: MTLSamplerMinMagFilter) -> MTLSamplerState? {
            let s = MTLSamplerDescriptor()
            s.minFilter = .linear
            s.magFilter = filter
            s.sAddressMode = .clampToEdge
            s.tAddressMode = .clampToEdge
            return device.makeSamplerState(descriptor: s)
        }
        guard let linear = sampler(.linear), let nearest = sampler(.nearest) else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.linear = linear
        self.nearest = nearest
    }

    /// Compiled at runtime (tiny), so the build needs no Metal toolchain.
    /// One full-window pass: the fragment shader maps each view point into the framebuffer, which
    /// lets effects (ripples, the loupe, the connect "materialise", frost) bend space anywhere.
    private static let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct QuadVertex { float2 position; float2 p; };
struct VOut { float4 position [[position]]; float2 p; };

struct FX {
    float4 content;      // content rect in view points: x, y, w, h
    float2 viewSize;
    float time;
    float materialise;   // 0 = just started, 1 = done
    float frost;         // 0…1
    float rippleCount;
    float loupeOn;
    float loupeRadius;
    float2 loupeCenter;  // where the loupe is drawn
    float2 loupeSource;  // what it magnifies
    float loupeZoom;
    float motion;        // 0 when Reduce Motion / effects off for distortion
    float pad0;
    float pad1;
    float4 ripples[4];   // x, y, age (s), strength
};

vertex VOut framebufferVertex(uint vid [[vertex_id]], constant QuadVertex *v [[buffer(0)]]) {
    VOut o;
    o.position = float4(v[vid].position, 0, 1);
    o.p = v[vid].p;
    return o;
}

static float3 tap(texture2d<float> tex, sampler s, float2 p, constant FX &fx, thread bool &inside) {
    float2 uv = (p - fx.content.xy) / fx.content.zw;
    inside = all(uv >= 0.0) && all(uv <= 1.0);
    return tex.sample(s, clamp(uv, 0.0, 1.0)).rgb;
}

fragment float4 framebufferFragment(VOut in [[stage_in]],
                                    texture2d<float> tex [[texture(0)]],
                                    sampler s [[sampler(0)]],
                                    constant FX &fx [[buffer(0)]]) {
    const float3 bg = float3(0.08, 0.08, 0.09);
    float2 p = in.p;
    float glow = 0.0;

    // Click ripples: a ring that pushes the image outward as it travels.
    for (int i = 0; i < int(fx.rippleCount); i++) {
        float4 r = fx.ripples[i];
        float2 d = p - r.xy;
        float dist = length(d);
        float radius = r.z * 170.0;
        float band = exp(-pow((dist - radius) / 7.0, 2.0));
        float fade = exp(-r.z * 5.0) * r.w;
        if (dist > 0.001) p -= (d / dist) * band * fade * 7.0 * fx.motion;   // mostly a lens-like distortion
        glow += band * fade * 0.02;
    }

    // Connect "materialise": a liquid wobble that settles as the screen resolves.
    float a = 1.0 - fx.materialise;
    a = a * a * fx.motion;
    p.x += sin(p.y * 0.045 + fx.time * 9.0) * 14.0 * a;
    p.y += cos(p.x * 0.040 + fx.time * 7.0) * 10.0 * a;

    // Frost shimmer (heat haze) while reconnecting.
    p += float2(sin(p.y * 0.08 + fx.time * 3.0), cos(p.x * 0.07 + fx.time * 2.5)) * 1.5 * fx.frost * fx.motion;

    // Precision loupe: a lens drawn at loupeCenter showing loupeSource magnified.
    float loupeRim = 0.0, loupeShadow = 0.0;
    if (fx.loupeOn > 0.5) {
        float2 d = in.p - fx.loupeCenter;
        float dist = length(d);
        float k = dist / fx.loupeRadius;
        if (k < 1.0) {
            float zoom = fx.loupeZoom * (1.0 - 0.18 * k * k * k * k);   // barrel at the rim
            p = fx.loupeSource + d / zoom;
            loupeRim = smoothstep(0.88, 1.0, k);
        } else if (k < 1.12) {
            loupeShadow = 1.0 - smoothstep(1.0, 1.12, k);
        }
    }

    // Sample — split into RGB (chromatic fringing) while materialising.
    float ca = 5.0 * a;
    bool inR, inG, inB;
    float cr = tap(tex, s, p + float2(ca, 0), fx, inR).r;
    float cg = tap(tex, s, p, fx, inG).g;
    float cb = tap(tex, s, p - float2(ca, 0), fx, inB).b;
    float3 c = inG ? float3(cr, cg, cb) : bg;

    // Frost: soft, desaturated and cool, with a faint sparkle.
    if (fx.frost > 0.001 && inG) {
        bool i1;
        float3 blur = (tap(tex, s, p + float2(3, 0), fx, i1) + tap(tex, s, p - float2(3, 0), fx, i1)
                     + tap(tex, s, p + float2(0, 3), fx, i1) + tap(tex, s, p - float2(0, 3), fx, i1)) * 0.25;
        float lum = dot(blur, float3(0.299, 0.587, 0.114));
        float3 frosted = mix(float3(lum), float3(0.78, 0.85, 0.97) * lum + 0.07, 0.55);
        float n = fract(sin(dot(floor(in.p * 0.5), float2(12.9898, 78.233))) * 43758.5453);
        frosted += step(0.997, n) * 0.35 * (0.5 + 0.5 * sin(fx.time * 4.0 + n * 40.0));
        c = mix(c, frosted, fx.frost * 0.85);
    }

    c = mix(bg, c, smoothstep(0.0, 0.45, fx.materialise));   // fade up from dark
    c += glow;
    c = mix(c, float3(1.0), loupeRim * 0.30);
    c *= 1.0 - loupeShadow * 0.35;
    return float4(c, 1.0);
}
"""

    /// Per-frame effect state, laid out to match `FX` in the shader.
    struct FX {
        var content = SIMD4<Float>(0, 0, 1, 1)
        var viewSize = SIMD2<Float>(1, 1)
        var time: Float = 0
        var materialise: Float = 1
        var frost: Float = 0
        var rippleCount: Float = 0
        var loupeOn: Float = 0
        var loupeRadius: Float = 70
        var loupeCenter = SIMD2<Float>(0, 0)
        var loupeSource = SIMD2<Float>(0, 0)
        var loupeZoom: Float = 2.2
        var motion: Float = 1
        var pad0: Float = 0
        var pad1: Float = 0
        var ripples: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero, .zero)
    }

    func setSurface(_ box: SurfaceBox?) {
        guard let box else { texture = nil; textureSurface = nil; return }
        guard box.surface !== textureSurface else { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                         width: box.surface.width,
                                                         height: box.surface.height,
                                                         mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        texture = device.makeTexture(descriptor: d, iosurface: box.surface, plane: 0)
        textureSurface = box.surface
    }

    /// `frame`: the content rect in view points. `bounds`: the view size in points.
    func draw(in layer: CAMetalLayer, frame: CGRect, bounds: CGSize, crisp: Bool, fx inFX: FX = FX()) {
        guard bounds.width > 0, bounds.height > 0, pending < 2 else { return }
        guard let drawable = layer.nextDrawable(), let buffer = queue.makeCommandBuffer() else { return }
        pending += 1
        buffer.addCompletedHandler { [weak self] _ in
            DispatchQueue.main.async { self?.pending -= 1 }
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1)
        guard let enc = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        if let texture {
            let w = Float(bounds.width), h = Float(bounds.height)
            // Full-window strip: NDC position + view-point coordinate.
            var quad: [Float] = [-1, 1, 0, 0,   1, 1, w, 0,   -1, -1, 0, h,   1, -1, w, h]
            var fx = inFX
            fx.content = SIMD4(Float(frame.minX), Float(frame.minY), Float(frame.width), Float(frame.height))
            fx.viewSize = SIMD2(w, h)
            enc.setRenderPipelineState(pipeline)
            enc.setVertexBytes(&quad, length: quad.count * MemoryLayout<Float>.size, index: 0)
            enc.setFragmentTexture(texture, index: 0)
            enc.setFragmentSamplerState(crisp ? nearest : linear, index: 0)
            enc.setFragmentBytes(&fx, length: MemoryLayout<FX>.stride, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        enc.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}
