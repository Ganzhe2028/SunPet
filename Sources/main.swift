import AppKit
import AVFoundation

struct Clip: Codable {
    let id: Int
    let label: String
    let timestamp: String
    let file: String
    let duration: Double
}

final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class FaceImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
final class CaptionField: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class PetView: NSView {
    weak var owner: AppDelegate?
    let face = FaceImageView()
    let caption = CaptionField(labelWithString: "")
    var initialMouse = NSPoint.zero
    var initialWindow = NSPoint.zero
    var dragged = false
    var timer: Timer?
    var phase = 0.0
    var speaking = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        face.imageScaling = .scaleProportionallyUpOrDown
        face.wantsLayer = true
        addSubview(face)
        caption.alignment = .center; caption.textColor = .white
        caption.font = .systemFont(ofSize: 12, weight: .medium)
        caption.maximumNumberOfLines = 2; caption.lineBreakMode = .byTruncatingTail
        caption.wantsLayer = true; caption.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        caption.layer?.cornerRadius = 10; caption.isHidden = true
        addSubview(caption)
        setAccessibilityElement(true); setAccessibilityRole(.button)
        setAccessibilityLabel("孙宇晨桌宠，点击播放，拖动移动，右键设置")
        toolTip = "点击随机播放一句 · 拖动移动 · 右键设置"
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        face.frame = NSRect(x: 12, y: 12, width: bounds.width-24, height: bounds.height-52)
        caption.frame = NSRect(x: 4, y: bounds.height-38, width: bounds.width-8, height: 34)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        initialMouse = window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation; initialWindow = window?.frame.origin ?? .zero; dragged = false
    }
    override func mouseDragged(with event: NSEvent) {
        let current = window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        let dx = current.x-initialMouse.x, dy = current.y-initialMouse.y
        if hypot(dx,dy) > 4 { dragged = true }
        if dragged { window?.setFrameOrigin(NSPoint(x: initialWindow.x+dx,y: initialWindow.y+dy)) }
    }
    override func mouseUp(with event: NSEvent) {
        if dragged { owner?.savePosition() } else { owner?.playNext() }
    }
    override func rightMouseDown(with event: NSEvent) {
        guard let menu = owner?.makeMenu() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    override func accessibilityPerformPress() -> Bool { owner?.playNext(); return true }
    func animate(_ enabled: Bool) {
        speaking = enabled; timer?.invalidate(); timer = nil; phase = 0
        face.layer?.transform = CATransform3DIdentity
        if enabled {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.phase += 0.38
                let angle = sin(self.phase) * 0.055
                let cx = self.face.bounds.midX, cy = self.face.bounds.midY
                var t = CATransform3DMakeTranslation(cx, cy, 0)
                t = CATransform3DRotate(t, angle, 0, 0, 1)
                t = CATransform3DTranslate(t, -cx, -cy + abs(sin(self.phase))*3, 0)
                self.face.layer?.transform = t
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, AVAudioPlayerDelegate {
    var panel: PetPanel!
    var pet: PetView!
    var status: NSStatusItem!
    var player: AVAudioPlayer?
    var clips: [Clip] = []
    var bag: [Int] = []
    var lastID: Int?
    var randomMode = true
    var pinnedID: Int?
    var motion = MotionClient()
    var motionEnabled = false
    var motionStatus = "机身摇晃：未开启"
    var captionWork: DispatchWorkItem?
    var volume: Float = 0.65
    var size: CGFloat = 180
    var resources: URL { Bundle.main.resourceURL! }
    var selfTest = CommandLine.arguments.contains("--self-test")
    var dumpMode = CommandLine.arguments.contains("--dump-mode")
    var testOK = true
    func applicationDidFinishLaunching(_ notification: Notification) {
        if !selfTest && !dumpMode {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: "local.isaac.SunPet").filter { $0.processIdentifier != getpid() }
            if !others.isEmpty { NSApp.terminate(nil); return }
        }
        do {
            clips = try JSONDecoder().decode([Clip].self, from: Data(contentsOf: resources.appendingPathComponent("clips.json")))
            guard !clips.isEmpty, NSImage(contentsOf: resources.appendingPathComponent("face.png")) != nil else { throw NSError(domain: "资源缺失", code: 1) }
        } catch {
            let alert = NSAlert(); alert.messageText = "桌宠资源无法读取"; alert.informativeText = error.localizedDescription; alert.runModal(); NSApp.terminate(nil); return
        }
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "volume") != nil { volume = defaults.float(forKey: "volume") }
        if defaults.object(forKey: "size") != nil { size = CGFloat(defaults.double(forKey: "size")) }
        if defaults.object(forKey: "randomMode") != nil { randomMode = defaults.bool(forKey: "randomMode") }
        if defaults.object(forKey: "pinnedID") != nil { pinnedID = defaults.integer(forKey: "pinnedID") }
        if !randomMode && !pinValid() { randomMode = true }
        if dumpMode {
            let pin = pinnedID.map { String($0) } ?? "nil"
            print("mode=\(randomMode ? "random" : "fixed") pinned=\(pin) valid=\(pinValid())")
            fflush(stdout); exit(0)
        }
        size = min(max(size,120),260)
        panel = PetPanel(contentRect: NSRect(x: 0,y: 0,width: size,height: size+48), styleMask: [.borderless,.nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.stationary,.ignoresCycle]
        pet = PetView(frame: NSRect(x: 0,y: 0,width: size,height: size+48)); pet.owner = self
        pet.face.image = NSImage(contentsOf: resources.appendingPathComponent("face.png"))
        panel.contentView = pet
        resetPosition()
        if defaults.object(forKey: "petX") != nil {
            let origin = NSPoint(x: defaults.double(forKey: "petX"),y: defaults.double(forKey: "petY"))
            let rect = NSRect(origin: origin,size: panel.frame.size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersection(rect).width >= 80 && $0.visibleFrame.intersection(rect).height >= 80 }) { panel.setFrameOrigin(origin) }
        }
        panel.orderFrontRegardless()
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "太对了"; status.button?.target = self; status.button?.action = #selector(openStatusMenu)
        motion.onEvent = { [weak self] event in
            guard let self else { return }
            if event == "ready" { self.motionStatus = "机身摇晃：已连接"; self.showCaption("摇一摇，太对了") }
            else if event == "shake" { if self.player?.isPlaying != true { self.playNext() } }
            else if event.hasPrefix("error:") {
                self.motionEnabled = false; self.motion.stop(); self.motionStatus = String(event.dropFirst(6)); self.showCaption(self.motionStatus, seconds: 6)
            }
        }
        if selfTest { runSelfTest() } else { showCaption("点我一下 · 右键设置", seconds: 5); toggleMotion() }
        updateToolTip()
    }
    @objc func openStatusMenu() { status.menu = makeMenu(); status.button?.performClick(nil); status.menu = nil }
    func item(_ title: String, _ action: Selector?, tag: Int = 0) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: ""); i.target = self; i.tag = tag; return i
    }
    func pinValid() -> Bool {
        guard let id = pinnedID else { return false }
        return clips.contains { $0.id == id }
    }
    func modeTitle() -> String {
        guard !randomMode, let id = pinnedID, let c = clips.first(where: { $0.id == id }) else { return "固定播一句" }
        return String(format: "固定播一句（%02d %@）", c.id, c.label)
    }
    func makeMenu() -> NSMenu {
        let m = NSMenu()
        let title = item("孙宇晨 · 太对了（\(clips.count)句）",nil); title.isEnabled = false; m.addItem(title)
        let mode = item("播放方式",nil); let mm = NSMenu()
        let rand = item("随机一句（一轮不重复）",#selector(modeRandom)); rand.state = randomMode ? .on : .off; mm.addItem(rand)
        let fix = item(modeTitle(),#selector(modeFixed)); fix.state = randomMode ? .off : .on; mm.addItem(fix)
        mode.submenu = mm; m.addItem(mode)
        let choose = item("挑一句",nil); let sub = NSMenu()
        if !randomMode {
            let hint = item("点任意一句＝固定播这句",nil); hint.isEnabled = false; sub.addItem(hint); sub.addItem(.separator())
        }
        for c in clips {
            let i = item(String(format: "%02d  %@",c.id,c.label),#selector(chooseAction(_:)),tag: c.id)
            if !randomMode && pinnedID == c.id { i.state = .on }
            sub.addItem(i)
        }
        choose.submenu = sub; m.addItem(choose)
        m.addItem(item("随机播一次",#selector(randomAction)))
        m.addItem(item("停止播放",#selector(stopAction)))
        m.addItem(.separator())
        let motionItem = item(motionEnabled ? "关闭机身摇晃" : "开启机身摇晃",#selector(toggleMotion)); motionItem.state = motionEnabled ? .on : .off; m.addItem(motionItem)
        let info = item(motionStatus,nil); info.isEnabled = false; m.addItem(info)
        let vol = item("音量",nil); let vm = NSMenu()
        for n in [0,25,50,65,80,100] { let v = item(n == 0 ? "静音" : "\(n)%",#selector(volumeAction(_:)),tag: n); v.state = abs(volume-Float(n)/100) < 0.01 ? .on : .off; vm.addItem(v) }; vol.submenu = vm; m.addItem(vol)
        let sz = item("头像大小",nil); let sm = NSMenu()
        for (name,n) in [("小",130),("中",180),("大",240)] { let i = item(name,#selector(sizeAction(_:)),tag:n); i.state = Int(size)==n ? .on : .off; sm.addItem(i) }; sz.submenu = sm; m.addItem(sz)
        m.addItem(item("移回屏幕右下角",#selector(resetPosition)))
        m.addItem(.separator()); m.addItem(item("退出桌宠",#selector(quit)))
        return m
    }
    func playNext() {
        if !randomMode, let id = pinnedID, let c = clips.first(where: { $0.id == id }) { play(c); return }
        playRandom()
    }
    func playRandom() {
        if bag.isEmpty { bag = Array(clips.indices).shuffled(); if bag.count > 1, clips[bag.last!].id == lastID { bag.swapAt(0,bag.count-1) } }
        play(clips[bag.removeLast()])
    }
    func play(_ clip: Clip) {
        do {
            player?.stop()
            let audio = try AVAudioPlayer(contentsOf: resources.appendingPathComponent("Clips").appendingPathComponent(clip.file))
            player = audio; audio.delegate = self; audio.volume = volume; audio.prepareToPlay()
            guard audio.play() else { throw NSError(domain:"音频播放失败",code:1) }
            lastID = clip.id; pet.animate(true); showCaption(clip.label,seconds:audio.duration+0.5)
        } catch { pet.animate(false); showCaption("播放失败：\(error.localizedDescription)",seconds:5) }
    }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { pet.animate(false) }
    func showCaption(_ text: String, seconds: Double = 3) {
        captionWork?.cancel(); pet.caption.stringValue = text; pet.caption.isHidden = false
        let work = DispatchWorkItem { [weak self] in self?.pet.caption.isHidden = true }; captionWork = work
        DispatchQueue.main.asyncAfter(deadline:.now()+seconds,execute:work)
    }
    @objc func randomAction() { playRandom() }
    @objc func modeRandom() { setMode(random: true) }
    @objc func modeFixed() { setMode(random: false) }
    func setMode(random: Bool) {
        randomMode = random
        if !random && !pinValid() { pinnedID = (clips.first(where: { $0.id == lastID }) ?? clips.first)?.id }
        UserDefaults.standard.set(random, forKey: "randomMode")
        if let pin = pinnedID { UserDefaults.standard.set(pin, forKey: "pinnedID") }
        updateToolTip()
        if random {
            showCaption("播放方式：随机一句", seconds: 4)
        } else if let c = clips.first(where: { $0.id == pinnedID }) {
            showCaption(String(format: "已固定：%02d %@", c.id, c.label), seconds: 4)
        }
    }
    func updateToolTip() {
        pet?.toolTip = randomMode ? "点击随机播放一句 · 拖动移动 · 右键设置" : "点击播放固定那句 · 拖动移动 · 右键设置"
    }
    @objc func chooseAction(_ sender: NSMenuItem) {
        guard let c = clips.first(where: { $0.id == sender.tag }) else { return }
        if !randomMode { pinnedID = c.id; UserDefaults.standard.set(c.id, forKey: "pinnedID") }
        play(c)
    }
    @objc func stopAction() { player?.stop(); pet.animate(false); pet.caption.isHidden = true }
    @objc func volumeAction(_ sender: NSMenuItem) { volume = Float(sender.tag)/100; player?.volume = volume; UserDefaults.standard.set(volume,forKey:"volume") }
    @objc func sizeAction(_ sender: NSMenuItem) { size = CGFloat(sender.tag); panel.setContentSize(NSSize(width:size,height:size+48)); UserDefaults.standard.set(Double(size),forKey:"size"); savePosition() }
    @objc func resetPosition() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        panel?.setFrameOrigin(NSPoint(x:screen.visibleFrame.maxX-size-32,y:screen.visibleFrame.minY+24)); savePosition()
    }
    func savePosition() { guard !selfTest, let panel else { return }; UserDefaults.standard.set(panel.frame.origin.x,forKey:"petX"); UserDefaults.standard.set(panel.frame.origin.y,forKey:"petY") }
    @objc func toggleMotion() {
        if motionEnabled { motion.stop(); motionEnabled = false; motionStatus = "机身摇晃：未开启"; return }
        guard let service = accelerometerService() else { showCaption("这台 Mac 没有可用的运动传感器",seconds:5); return }; IOObjectRelease(service)
        guard let executable = Bundle.main.executableURL?.path else { return }
        motionEnabled = true; motionStatus = "机身摇晃：正在连接"
        do { try motion.start(executable:executable) } catch { motionEnabled = false; motionStatus = error.localizedDescription; showCaption(motionStatus) }
    }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { motion.stop(); player?.stop(); savePosition() }
    func runSelfTest() {
        var checks: [String] = []
        for c in clips {
            do {
                let a = try AVAudioPlayer(contentsOf: resources.appendingPathComponent("Clips").appendingPathComponent(c.file))
                guard a.duration > 0.25 && a.duration < 7 else { throw NSError(domain:"时长异常",code:c.id) }
                checks.append("clip \(c.id): \(String(format:"%.3f",a.duration)) s")
            } catch { testOK = false; checks.append("FAIL \(c.id): \(error)") }
        }
        var detector = ShakeDetector(); var idleTriggers = 0; var shakeTriggers = 0
        for i in 0..<400 { if detector.ingest(SIMD3(0,0,1),time:Double(i)*0.01) { idleTriggers += 1 } }
        for i in 400..<450 { if detector.ingest(SIMD3(sin(Double(i))*0.7,0,1),time:Double(i)*0.01) { shakeTriggers += 1 } }
        if idleTriggers != 0 || shakeTriggers != 1 { testOK = false }
        checks.append("detector: idle=\(idleTriggers), shake=\(shakeTriggers)")
        checks.append("panel: transparent=\(!panel.isOpaque), floating=\(panel.level == .floating), clips=\(clips.count)")
        // Use the same mouse handlers as a real click; self-test playback is silent.
        volume = 0
        let down = NSEvent.mouseEvent(with:.leftMouseDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:panel.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
        pet.mouseDown(with:down); pet.mouseUp(with:down)
        if player?.isPlaying != true { testOK = false }
        checks.append("click playback=\(player?.isPlaying == true), animation=\(pet.speaking)")
        // Fixed mode: every trigger must replay the pinned clip and never drift to another one.
        randomMode = false; pinnedID = clips.count > 2 ? clips[2].id : clips.first?.id
        var pinnedOK = true
        for _ in 0..<6 {
            player?.stop(); playNext()
            if lastID != pinnedID { pinnedOK = false }
        }
        if !pinnedOK || pinnedID == nil { testOK = false }
        checks.append("fixed mode: pinned=\(pinnedID ?? -1), stable=\(pinnedOK)")
        // Menu wiring: mode submenu present, every clip listed exactly once, pinned clip checkmarked.
        randomMode = true; pinnedID = nil
        let m1 = makeMenu()
        let mode1 = m1.items.first(where: { $0.title == "播放方式" })?.submenu
        let choose1 = m1.items.first(where: { $0.title == "挑一句" })?.submenu
        if mode1?.items.count != 2 || choose1?.items.count != clips.count { testOK = false }
        if mode1?.items.dropFirst().first?.state != .off { testOK = false }
        randomMode = false; pinnedID = clips[2].id
        let m2 = makeMenu()
        let mode2 = m2.items.first(where: { $0.title == "播放方式" })?.submenu
        let choose2 = m2.items.first(where: { $0.title == "挑一句" })?.submenu
        let fixedItem = mode2?.items.dropFirst().first
        let marks = choose2?.items.filter({ $0.state == .on }) ?? []
        if fixedItem?.state != .on || fixedItem?.title.contains(clips[2].label) != true { testOK = false }
        if mode2?.items.first?.state != .off { testOK = false }
        if marks.count != 1 || marks.first?.tag != clips[2].id { testOK = false }
        checks.append("menu: mode=\(mode1?.items.count ?? -1)/\(mode2?.items.count ?? -1), choose=\(choose1?.items.count ?? -1)/\(choose2?.items.count ?? -1), marked=\(marks.count)")
        randomMode = true; pinnedID = nil
        checks.append(testOK ? "PASS" : "FAIL")
        print(checks.joined(separator:"\n")); fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline:.now()+1.0) { self.motion.stop(); self.player?.stop(); exit(self.testOK ? 0 : 1) }
    }
}

import IOKit
if CommandLine.arguments.count == 5, CommandLine.arguments[1] == "--motion-helper", let port = UInt16(CommandLine.arguments[2]), port > 1024, let parent = Int32(CommandLine.arguments[4]), parent > 1 {
    SensorHelper().run(port:port,token:CommandLine.arguments[3],parent:parent)
}
if CommandLine.arguments.contains("--probe-sensor") {
    if let s = accelerometerService(), let d = IOHIDDeviceCreate(kCFAllocatorDefault,s) {
        let r = IOHIDDeviceOpen(d,0); print("sensor available; open result=\(r); uid=\(getuid())")
        if r == kIOReturnSuccess { IOHIDDeviceClose(d,0) }; IOObjectRelease(s)
    } else { print("sensor unavailable") }
    exit(0)
}
let app = NSApplication.shared
let delegate = AppDelegate(); app.delegate = delegate; app.setActivationPolicy(.accessory); app.run()
