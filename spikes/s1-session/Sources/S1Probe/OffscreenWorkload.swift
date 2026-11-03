import Foundation
import Metal

/// Offscreen render workload (GUI-05): a fixed amount of fragment work per frame through the
/// render pipeline, timed on the GPU and verified pixel by pixel against a CPU reference.
///
/// The verification shows the GPU really executed the pipeline; the timing, compared with the
/// same probe run in the host console session, shows whether the session renders accelerated.
public struct OffscreenResult: Codable, Equatable, Sendable {
    public var device: String
    public var width: Int
    public var height: Int
    public var iterationsPerPixel: Int
    public var frames: Int
    public var gpuMillisecondsMedian: Double
    public var gpuMillisecondsP95: Double
    public var wallSeconds: Double
    /// Hash iterations per second of GPU time at the median frame.
    public var gigaIterationsPerSecond: Double
    public var verifiedPixels: Int
    public var mismatchedPixels: Int
}

public enum OffscreenWorkload {
    /// Fixed so that runs on different sessions and machines stay comparable.
    public static let width = 2048
    public static let height = 2048
    public static let iterationsPerPixel: UInt32 = 512
    public static let frames = 60
    static let verifiedPixels = 4096

    static let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexOut { float4 position [[position]]; };
        struct HashOut { uint value [[color(0)]]; };

        vertex VertexOut fullscreenTriangle(uint vid [[vertex_id]]) {
            float2 p = float2((vid << 1) & 2, vid & 2);
            VertexOut out;
            out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
            return out;
        }

        // params.x = frame, params.y = iterations; must match OffscreenWorkload.expectedPixel.
        fragment HashOut hashPixel(VertexOut in [[stage_in]], constant uint2 &params [[buffer(0)]]) {
            uint x = uint(in.position.x);
            uint y = uint(in.position.y);
            uint h = (x * 73856093u) ^ (y * 19349663u) ^ (params.x * 83492791u);
            for (uint i = 0; i < params.y; ++i) {
                h = h * 1664525u + 1013904223u;
                h ^= h >> 16;
            }
            HashOut out;
            out.value = h;
            return out;
        }
        """

    /// CPU reference of `hashPixel`.
    static func expectedPixel(x: UInt32, y: UInt32, frame: UInt32, iterations: UInt32) -> UInt32 {
        var h = (x &* 73856093) ^ (y &* 19349663) ^ (frame &* 83492791)
        for _ in 0..<iterations {
            h = h &* 1664525 &+ 1013904223
            h ^= h >> 16
        }
        return h
    }

    public static func run() throws -> OffscreenResult {
        guard let device = MTLCreateSystemDefaultDevice() else { throw WorkloadError("no default Metal device") }
        guard let queue = device.makeCommandQueue() else { throw WorkloadError("cannot create command queue") }
        let library = try device.makeLibrary(source: shaderSource, options: nil)
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "fullscreenTriangle")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "hashPixel")
        pipelineDescriptor.colorAttachments[0].pixelFormat = .r32Uint
        let pipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Uint, width: width, height: height, mipmapped: false
        )
        textureDescriptor.usage = .renderTarget
        textureDescriptor.storageMode = .private
        guard let target = device.makeTexture(descriptor: textureDescriptor),
              let readback = device.makeBuffer(length: width * height * 4, options: .storageModeShared)
        else { throw WorkloadError("cannot allocate render target") }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store

        var gpuMilliseconds: [Double] = []
        let start = Date()
        for frame in 0..<frames {
            guard let commands = queue.makeCommandBuffer(),
                  let encoder = commands.makeRenderCommandEncoder(descriptor: pass)
            else { throw WorkloadError("cannot encode frame \(frame)") }
            var params = SIMD2<UInt32>(UInt32(frame), iterationsPerPixel)
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&params, length: MemoryLayout<SIMD2<UInt32>>.size, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            if frame == frames - 1, let blit = commands.makeBlitCommandEncoder() {
                blit.copy(
                    from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(width: width, height: height, depth: 1), to: readback,
                    destinationOffset: 0, destinationBytesPerRow: width * 4, destinationBytesPerImage: width * height * 4
                )
                blit.endEncoding()
            }
            commands.commit()
            commands.waitUntilCompleted()
            if let error = commands.error { throw WorkloadError("frame \(frame) failed: \(error)") }
            gpuMilliseconds.append((commands.gpuEndTime - commands.gpuStartTime) * 1000)
        }
        let wallSeconds = Date().timeIntervalSince(start)

        // Deterministic sample spread over the whole target.
        let pixels = readback.contents().bindMemory(to: UInt32.self, capacity: width * height)
        var mismatched = 0
        for sample in 0..<verifiedPixels {
            let index = (sample &* 2_654_435_761) % (width * height)
            let expected = expectedPixel(
                x: UInt32(index % width), y: UInt32(index / width), frame: UInt32(frames - 1), iterations: iterationsPerPixel
            )
            if pixels[index] != expected { mismatched += 1 }
        }

        let median = percentile(gpuMilliseconds, 0.5)
        return OffscreenResult(
            device: device.name, width: width, height: height, iterationsPerPixel: Int(iterationsPerPixel),
            frames: frames, gpuMillisecondsMedian: median, gpuMillisecondsP95: percentile(gpuMilliseconds, 0.95),
            wallSeconds: wallSeconds,
            gigaIterationsPerSecond: Double(width * height) * Double(iterationsPerPixel) / (median / 1000) / 1e9,
            verifiedPixels: verifiedPixels, mismatchedPixels: mismatched
        )
    }
}

struct WorkloadError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

/// Nearest-rank percentile of a non-empty sample.
func percentile(_ values: [Double], _ fraction: Double) -> Double {
    let sorted = values.sorted()
    let rank = Int((fraction * Double(sorted.count)).rounded(.up)) - 1
    return sorted[min(max(rank, 0), sorted.count - 1)]
}
