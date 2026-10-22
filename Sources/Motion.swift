import Foundation
import IOKit
import IOKit.hid
import Network

// SPU report layout documented by olvvier/apple-silicon-accelerometer.
struct ShakeDetector {
    var gravity: SIMD3<Double>?
    var first = 0.0
    var last = -10.0
    var peaks: [Double] = []
    var previousSampleTime: Double?
    mutating func ingest(_ v: SIMD3<Double>, time: Double) -> Bool {
        if let previousSampleTime, time - previousSampleTime > 1 { gravity = nil; peaks.removeAll() }
        previousSampleTime = time
        guard let g = gravity else { gravity = v; first = time; return false }
        // Discard impossible reports and relearn gravity after a sleep/wake gap.
        guard v.x.isFinite && v.y.isFinite && v.z.isFinite else { return false }
        gravity = g * 0.94 + v * 0.06
        let d = v - g
        let magnitude = sqrt(d.x*d.x + d.y*d.y + d.z*d.z)
        guard time - first > 1.0, time - last > 2.0 else { return false }
        peaks = peaks.filter { time - $0 < 0.30 }
        if magnitude > 0.18 { peaks.append(time) }
        if peaks.count >= 5, let start = peaks.first, time - start > 0.055 {
            last = time; peaks.removeAll(); return true
        }
        return false
    }
}

func accelerometerService() -> io_service_t? {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDevice"), &iterator) == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(iterator) }
    while true {
        let s = IOIteratorNext(iterator)
        if s == 0 { break }
        let page = IORegistryEntryCreateCFProperty(s, "PrimaryUsagePage" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
        let usage = IORegistryEntryCreateCFProperty(s, "PrimaryUsage" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
        if page == 0xff00 && usage == 3 { return s }
        IOObjectRelease(s)
    }
    return nil
}

final class SensorHelper {
    var detector = ShakeDetector()
    var connection: NWConnection!
    var count = 0
    var lastAck = ProcessInfo.processInfo.systemUptime
    var lastSample = 0.0
    var token = ""
    var lastProcessed = 0.0
    func send(_ value: String) {
        connection.send(content: Data("\(token)|\(value)".utf8), completion: .contentProcessed { _ in })
    }
    func receiveAck() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, String(data: data, encoding: .utf8) == "\(self.token)|ack" {
                DispatchQueue.main.async { self.lastAck = ProcessInfo.processInfo.systemUptime }
            }
            if error == nil { self.receiveAck() }
        }
    }
    func report(_ bytes: UnsafeMutablePointer<UInt8>, length: Int) {
        guard length == 22 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastProcessed >= 0.008 else { return }; lastProcessed = now
        func value(_ n: Int) -> Double {
            let raw = UInt32(bytes[n]) | UInt32(bytes[n+1]) << 8 | UInt32(bytes[n+2]) << 16 | UInt32(bytes[n+3]) << 24
            return Double(Int32(bitPattern: raw)) / 65536.0
        }
        count += 1; lastSample = now
        if count == 1 { send("ready") }
        if detector.ingest(SIMD3(value(6), value(10), value(14)), time: now) { send("shake") }
    }
    func run(port: UInt16, token: String, parent: Int32) -> Never {
        self.token = token
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .udp)
        connection.start(queue: .global(qos: .utility)); receiveAck()
        guard let service = accelerometerService() else { send("error:找不到运动传感器"); RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3)); exit(2) }
        guard let device = IOHIDDeviceCreate(kCFAllocatorDefault, service) else { exit(3) }
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            send("error:传感器访问被拒绝（\(result)）")
            fputs("Sensor open failed: \(result)\n", stderr)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3)); exit(4)
        }
        // Wake only the accelerometer driver; do not change unrelated sensors.
        var driver: io_registry_entry_t = 0
        if IORegistryEntryGetChildEntry(service, kIOServicePlane, &driver) == KERN_SUCCESS {
            var leaf: io_registry_entry_t = 0
            if IORegistryEntryGetChildEntry(driver, kIOServicePlane, &leaf) == KERN_SUCCESS {
                for (key,value) in [("SensorPropertyReportingState",1),("SensorPropertyPowerState",1),("ReportInterval",10000)] {
                    IORegistryEntrySetCFProperty(leaf, key as CFString, value as CFNumber)
                }
                IOObjectRelease(leaf)
            }
            IOObjectRelease(driver)
        }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 4096, { context, result, _, _, _, report, length in
            guard result == kIOReturnSuccess, let context else { return }
            Unmanaged<SensorHelper>.fromOpaque(context).takeUnretainedValue().report(report, length: length)
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        let started = ProcessInfo.processInfo.systemUptime
        while kill(parent, 0) == 0 {
            CFRunLoopRunInMode(.defaultMode, 0.20, false)
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastAck > 6 || now - started > 12*3600 { break }
            if now - started > 5 && (lastSample == 0 || now - lastSample > 5) { send("error:没有收到传感器数据"); break }
            send("heartbeat:\(count)")
        }
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, 0); IOObjectRelease(service); buffer.deallocate(); connection.cancel()
        exit(0)
    }
}

final class MotionClient {
    var listener: NWListener?
    var connections: [NWConnection] = []
    var token = ""
    var onEvent: ((String) -> Void)?
    var process: Process?
    var lastMessage = Date.distantPast
    var watchdog: Timer?
    var generation = UUID()
    func stop() {
        generation = UUID(); listener?.cancel(); listener = nil
        connections.forEach { $0.cancel() }; connections.removeAll()
        watchdog?.invalidate(); watchdog = nil
        process?.terminate(); process = nil
        // The helper also exits after six seconds without acknowledgements.
    }
    func start(executable: String) throws {
        stop(); token = UUID().uuidString
        let currentGeneration = generation
        let params = NWParameters.udp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params); self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in
            DispatchQueue.main.async {
                guard let self, self.generation == currentGeneration else { conn.cancel(); return }
                self.connections.append(conn); conn.start(queue: .main); self.read(conn, generation: currentGeneration)
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, self.generation == currentGeneration else { return }
            switch state {
            case .ready:
                guard let port = listener.port else { return }
                self.authorize(executable: executable, port: port.rawValue, generation: currentGeneration)
            case .failed(let error): self.onEvent?("error:\(error.localizedDescription)"); self.stop()
            default: break
            }
        }
        listener.start(queue: .main)
    }
    func read(_ conn: NWConnection, generation: UUID) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self, self.generation == generation else { return }
            if let data, let text = String(data: data, encoding: .utf8), text.hasPrefix(self.token + "|") {
                self.lastMessage = Date()
                conn.send(content: Data("\(self.token)|ack".utf8), completion: .contentProcessed { _ in })
                self.onEvent?(String(text.dropFirst(self.token.count + 1)))
            }
            if error == nil { self.read(conn, generation: generation) }
        }
    }
    func authorize(executable: String, port: UInt16, generation: UUID) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = ["--motion-helper", String(port), token, String(getpid())]
        p.standardError = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; process = p
        p.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.onEvent?("error:运动传感器已断开，请重新开启"); self.stop()
            }
        }
        do {
            try p.run(); lastMessage = Date()
            watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                guard let self else { return }
                if Date().timeIntervalSince(self.lastMessage) > 8 {
                    self.onEvent?("error:未收到运动数据，请重新开启"); self.stop()
                }
            }
        } catch { onEvent?("error:\(error.localizedDescription)"); stop() }
    }
}
