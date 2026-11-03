import AppKit
import Foundation
import Metal
import QuartzCore
import Synchronization

/// On-screen presentation (GUI-01, GUI-02, GUI-05): renders into a window of the session the
/// probe runs in and counts the frames its window server actually presented.
///
/// Offscreen work proves the GPU executes; only presented frames prove the session composites
/// and shows them. A disconnected or asleep virtual display shows up here as presented frames
/// dropping to zero or `drawableTimeouts` rising.
public struct PresentationResult: Codable, Equatable, Sendable {
    public var seconds: Double
    public var drawableWidth: Int
    public var drawableHeight: Int
    public var backingScale: Double
    public var screenMaximumFramesPerSecond: Int?
    /// Window occlusion state halfway through the run.
    public var windowVisible: Bool
    public var framesSubmitted: Int
    public var framesPresented: Int
    /// `nextDrawable` gave up after its one-second timeout.
    public var drawableTimeouts: Int
    public var presentedFramesPerSecond: Double
    public var presentIntervalMedianMs: Double?
    public var presentIntervalP95Ms: Double?
}

@MainActor
public enum Presentation {
    static let windowSize = CGSize(width: 960, height: 600)

    nonisolated static let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexOut { float4 position [[position]]; };

        vertex VertexOut fullscreenTriangle(uint vid [[vertex_id]]) {
            float2 p = float2((vid << 1) & 2, vid & 2);
            VertexOut out;
            out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
            return out;
        }

        // Moving pattern: a frame that was not rendered cannot look like one that was.
        fragment float4 pattern(VertexOut in [[stage_in]], constant float &time [[buffer(0)]]) {
            float2 p = in.position.xy / 200.0;
            float v = sin(p.x + time * 3.0) + sin(p.y * 1.3 - time * 2.0) + sin((p.x + p.y) * 0.7 + time);
            return float4(0.5 + 0.5 * sin(v), 0.5 + 0.5 * sin(v + 2.1), 0.5 + 0.5 * sin(v + 4.2), 1.0);
        }
        """

    public static func run(seconds: Double) throws -> PresentationResult {
        guard let device = MTLCreateSystemDefaultDevice() else { throw WorkloadError("no default Metal device") }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.finishLaunching()

        let window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: 120, y: 120), size: windowSize), styleMask: [.titled],
            backing: .buffered, defer: false
        )
        window.title = "Sanďbox S1 probe"
        // Visible on whichever Space is active, above other windows: an occluded window is
        // not composited, and the run would measure occlusion instead of the session.
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        let view = NSView(frame: NSRect(origin: .zero, size: windowSize))
        view.wantsLayer = true
        view.layer = layer
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        app.activate()
        let scale = window.backingScaleFactor
        layer.contentsScale = scale
        layer.drawableSize = CGSize(width: windowSize.width * scale, height: windowSize.height * scale)

        let renderer = try PresentationRenderer(device: device, layer: layer)
        let start = Date()
        renderer.start(until: start.addingTimeInterval(seconds))
        var windowVisible = false
        var sampledVisibility = false
        // Pump events on the main thread while frames render on the renderer's thread;
        // the extra half second lets presented handlers of the last frames arrive.
        while Date().timeIntervalSince(start) < seconds + 0.5 {
            if !sampledVisibility && Date().timeIntervalSince(start) >= seconds / 2 {
                windowVisible = window.occlusionState.contains(.visible)
                sampledVisibility = true
            }
            if let event = app.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.02), inMode: .default, dequeue: true) {
                app.sendEvent(event)
            }
        }
        let stats = renderer.finish()
        window.close()

        let intervals = zip(stats.presentedTimes.dropFirst(), stats.presentedTimes).map { ($0 - $1) * 1000 }
        return PresentationResult(
            seconds: seconds, drawableWidth: Int(layer.drawableSize.width), drawableHeight: Int(layer.drawableSize.height),
            backingScale: scale, screenMaximumFramesPerSecond: window.screen?.maximumFramesPerSecond,
            windowVisible: windowVisible, framesSubmitted: stats.submitted, framesPresented: stats.presentedTimes.count,
            drawableTimeouts: stats.timeouts, presentedFramesPerSecond: Double(stats.presentedTimes.count) / seconds,
            presentIntervalMedianMs: intervals.isEmpty ? nil : percentile(intervals, 0.5),
            presentIntervalP95Ms: intervals.isEmpty ? nil : percentile(intervals, 0.95)
        )
    }
}

/// Renders frames on its own thread; `nextDrawable` blocks while the window server holds all
/// drawables, so the loop runs at the rate the session actually presents.
private final class PresentationRenderer: @unchecked Sendable {
    struct Stats {
        var submitted = 0
        var timeouts = 0
        /// Host times of frames the window server reported as presented (non-zero time).
        var presentedTimes: [CFTimeInterval] = []
    }

    // Owned by the render thread between `start` and `finish`.
    private let layer: CAMetalLayer
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let stats = Mutex(Stats())
    private let done = DispatchSemaphore(value: 0)

    init(device: MTLDevice, layer: CAMetalLayer) throws {
        guard let queue = device.makeCommandQueue() else { throw WorkloadError("cannot create command queue") }
        let library = try device.makeLibrary(source: Presentation.shaderSource, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "fullscreenTriangle")
        descriptor.fragmentFunction = library.makeFunction(name: "pattern")
        descriptor.colorAttachments[0].pixelFormat = layer.pixelFormat
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        self.queue = queue
        self.layer = layer
    }

    func start(until deadline: Date) {
        Thread {
            let origin = Date()
            while Date() < deadline {
                autoreleasepool { self.renderFrame(time: Float(Date().timeIntervalSince(origin))) }
            }
            self.queue.makeCommandBuffer().map { last in
                last.commit()
                last.waitUntilCompleted()
            }
            self.done.signal()
        }.start()
    }

    private func renderFrame(time: Float) {
        guard let drawable = layer.nextDrawable() else {
            stats.withLock { $0.timeouts += 1 }
            return
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let commands = queue.makeCommandBuffer(), let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        var time = time
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&time, length: MemoryLayout<Float>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        drawable.addPresentedHandler { [self] presented in
            let presentedTime = presented.presentedTime
            if presentedTime > 0 { stats.withLock { $0.presentedTimes.append(presentedTime) } }
        }
        commands.present(drawable)
        commands.commit()
        stats.withLock { $0.submitted += 1 }
    }

    /// Waits for the render thread and returns presented times in order.
    func finish() -> Stats {
        done.wait()
        return stats.withLock { stats in
            stats.presentedTimes.sort()
            return stats
        }
    }
}
