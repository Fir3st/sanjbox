import AppKit
import Metal
import QuartzCore
import Synchronization

/// A light changing pattern only. Never invokes the offscreen workload or capture APIs.
@MainActor
final class LivePresentation {
    private let window: NSWindow
    private let layer: CAMetalLayer
    private let renderer: LightRenderer
    private var visibility: [Visibility] = []
    init(measurement: Window) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw InstrumentError("no Metal device") }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular); app.finishLaunching()
        window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 960, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Sanďbox S1 instrumentation — synthetic pattern"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        layer = CAMetalLayer(); layer.device = device; layer.pixelFormat = .bgra8Unorm
        layer.allowsNextDrawableTimeout = true
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 600))
        view.wantsLayer = true; view.layer = layer; window.contentView = view
        window.makeKeyAndOrderFront(nil); app.activate()
        layer.contentsScale = window.backingScaleFactor
        layer.drawableSize = CGSize(width: 960 * window.backingScaleFactor, height: 600 * window.backingScaleFactor)
        renderer = try LightRenderer(device: device, layer: layer)
        renderer.start(measurement: measurement)
    }
    func tick() {
        let now = InstrumentClock.now()
        if renderer.hasStarted && (visibility.last.map({ now - $0.time >= 1 }) ?? true) { sampleVisibility() }
        if let event = NSApplication.shared.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.005), inMode: .default, dequeue: true) {
            NSApplication.shared.sendEvent(event)
        }
    }
    private func sampleVisibility() {
        visibility.append(Visibility(time: InstrumentClock.now(), visible: window.occlusionState.contains(.visible) && window.isVisible,
            width: Int(layer.drawableSize.width), height: Int(layer.drawableSize.height), scale: window.backingScaleFactor))
    }
    func finish(end: Double) -> PresentationTrace {
        // Bounded callback drain; raw distinguishes nil callbacks from actual presentation.
        while InstrumentClock.now() < end + 2 { tick() }
        sampleVisibility()
        let result = renderer.finish(visibility: visibility)
        window.close()
        return result
    }
}
private final class LightRenderer: @unchecked Sendable {
    private struct State {
        var trace = PresentationTrace(recorderStart: InstrumentClock.now(), recorderEnd: 0, drainEnd: 0)
        var accepting = true
        var stopped = false
        var started = false
    }
    private let state = Mutex(State())
    private let layer: CAMetalLayer
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    init(device: MTLDevice, layer: CAMetalLayer) throws {
        self.layer = layer
        guard let queue = device.makeCommandQueue() else { throw InstrumentError("cannot create Metal queue") }
        self.queue = queue
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct V { float4 p [[position]]; };
        vertex V triangle(uint id [[vertex_id]]) { V v; v.p=float4(float2((id<<1)&2,id&2)*2-1,0,1); return v; }
        fragment float4 pattern(V v [[stage_in]], constant float &t [[buffer(0)]]) {
            return float4(0.5+0.5*sin(v.p.x/100+t),0.5+0.5*sin(v.p.y/100-t),0.5+0.5*sin(t*3),1);
        }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "triangle")
        descriptor.fragmentFunction = library.makeFunction(name: "pattern")
        descriptor.colorAttachments[0].pixelFormat = layer.pixelFormat
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    }
    var hasStarted: Bool { state.withLock { $0.started } }
    func start(measurement: Window) {
        let end = measurement.end + 0.25
        Thread { [self] in
            state.withLock { $0.trace.recorderStart = InstrumentClock.now(); $0.started = true }
            while InstrumentClock.now() < end && state.withLock({ $0.accepting }) {
                state.withLock {
                    if $0.trace.measurementAcquisition == nil && InstrumentClock.now() >= measurement.start - 1 {
                        $0.trace.measurementAcquisition = Window(start: InstrumentClock.now(), end: 0)
                    }
                }
                autoreleasepool { render(end: end) }
            }
            state.withLock { $0.trace.recorderEnd = InstrumentClock.now(); $0.trace.measurementAcquisition?.end = $0.trace.recorderEnd; $0.stopped = true }
        }.start()
    }
    private func render(end: Double) {
        guard let drawable = layer.nextDrawable() else {
            state.withLock { if $0.accepting && $0.trace.timeouts.count < 3000 { $0.trace.timeouts.append(InstrumentClock.now()) } }
            return
        }
        guard InstrumentClock.now() < end else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare; pass.colorAttachments[0].storeAction = .store
        guard let commands = queue.makeCommandBuffer(), let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else {
            state.withLock { $0.accepting = false; $0.trace.errors.append("cannot encode light frame") }; return
        }
        var time = Float(InstrumentClock.now().truncatingRemainder(dividingBy: 1000))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&time, length: MemoryLayout<Float>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); encoder.endEncoding()
        let sequence: Int? = state.withLock {
            guard $0.accepting && $0.trace.frames.count < 200_000 else {
                if $0.accepting { $0.trace.errors.append("frame cap reached") }; $0.accepting = false; return nil
            }
            let id = $0.trace.frames.count
            $0.trace.frames.append(Frame(sequence: id, submitted: InstrumentClock.now()))
            return id
        }
        guard let sequence else { return }
        drawable.addPresentedHandler { [self] drawable in
            let callback = InstrumentClock.now()
            state.withLock {
                guard $0.accepting && drawable.presentedTime > 0 else { return }
                $0.trace.frames[sequence].presented = drawable.presentedTime
                $0.trace.frames[sequence].callback = callback
            }
        }
        commands.addCompletedHandler { [self] buffer in
            if buffer.status == .error {
                state.withLock { if $0.accepting && $0.trace.errors.count < 64 { $0.trace.errors.append("Metal command buffer error") } }
            }
        }
        commands.present(drawable); commands.commit()
    }
    func finish(visibility: [Visibility]) -> PresentationTrace {
        state.withLock {
            $0.accepting = false
            if !$0.stopped { $0.trace.errors.append("renderer did not stop before drain deadline"); $0.trace.recorderEnd = InstrumentClock.now() }
            $0.trace.drainEnd = InstrumentClock.now(); $0.trace.visibility = visibility
            return $0.trace
        }
    }
}
