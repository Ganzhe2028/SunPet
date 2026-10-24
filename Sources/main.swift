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
    /// 从轮播里剔除的句子 id。勾掉的不参与随机，也不拿去当捧哏。
    var excludedIDs: Set<Int> = []
    var motion = MotionClient()
    var motionEnabled = false
    var motionStatus = "机身摇晃：未开启"
    var captionWork: DispatchWorkItem?
    var volume: Float = 0.65
    var size: CGFloat = 180
    // 捧哏联动：好事桌宠说完一句，这边接一句短的。
    let bridge = PetBridge(me: .sunpet, peers: [.fengge, .shaolan])
    var bridgeEnabled = true
    var bridgeStatus = "捧哏：等待峰哥和薄肌"
    var companionPool: [Clip] = []
    var companionBag: [Clip] = []
    var companionWork: DispatchWorkItem?
    /// 捧哏句预先解码好的播放器，接话时直接用，不用临时读文件。
    var companionPlayers: [Int: AVAudioPlayer] = [:]
    /// 每句开头有多少静音。剪辑切出来的段落长短不一，最多差到 0.32 秒，
    /// 不按它补的话同样提前 0.3 秒，实际出声时刻能飘出小半秒。
    var companionLead: [Int: TimeInterval] = [:]
    /// 捧哏只挑最短的几句，逗哏一说完就得接上，长句会把节奏拖垮。
    let companionIDs: Set<Int> = [1, 2, 4, 11, 13, 14]
    /// 接话提前多少开始。像 Apple Music 的交叉淡入：峰哥那句还剩这点时间，捧哏就进来。
    /// 相声里捧哏本来就是叠着逗哏的尾音接的，等他说完再开口中间会有一截空档。
    let companionOverlap: TimeInterval = 0.3
    var resources: URL { Bundle.main.resourceURL! }
    let selfTest = CommandLine.arguments.contains("--self-test")
    /// --trace 时把联动每一跳的时间、跳数、重叠打到 stdout，用来核对四步链的节奏。
    let trace = CommandLine.arguments.contains("--trace")
    func traceLog(_ text: String) {
        guard trace else { return }
        print("[SUNPET] \(String(format: "%.3f", Date().timeIntervalSince1970)) \(text)")
        fflush(stdout)
    }
    var dumpMode = CommandLine.arguments.contains("--dump-mode")
    var testOK = true
    func applicationDidFinishLaunching(_ notification: Notification) {
        if !selfTest && !dumpMode, let ownID = Bundle.main.bundleIdentifier {
            // 原来这里写死了 local.isaac.SunPet，跟 Info.plist 里的
            // com.ganzhe2028.sunpet 对不上，单实例检测实际上从来没生效过。
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: ownID).filter { $0.processIdentifier != getpid() }
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
        // 注意：defaults.array 拿回来是 [Any] 装 NSNumber，直接 as? [Int] 会失败，
        // 必须逐项取 intValue。踩过：写进去了但读不出来。
        if let raw = defaults.array(forKey: "excludedIDs") {
            excludedIDs = Set(raw.compactMap { entry -> Int? in
                if let number = entry as? NSNumber { return number.intValue }
                if let text = entry as? String { return Int(text) }
                return nil
            })
        }
        if !randomMode && !pinValid() { randomMode = true }
        if dumpMode {
            let pin = pinnedID.map { String($0) } ?? "nil"
            print("mode=\(randomMode ? "random" : "fixed") pinned=\(pin) valid=\(pinValid()) excluded=\(excludedIDs.sorted()) clips=\(clips.count) pool=\(clips.count - excludedIDs.count)")
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
        if defaults.object(forKey: "bridgeEnabled") != nil { bridgeEnabled = defaults.bool(forKey: "bridgeEnabled") }
        companionPool = clips.filter { companionIDs.contains($0.id) && !excludedIDs.contains($0.id) }
        preloadCompanionClips()
        if !selfTest && !dumpMode { startBridge() }
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
        let filters = item("轮播内容",nil); let fm = NSMenu()
        let fhint = item("取消勾选＝不参与随机播",nil); fhint.isEnabled = false; fm.addItem(fhint); fm.addItem(.separator())
        // 用真正的 NSButton 控件（menuItem.view）而不是菜单项的 state：
        // 菜单项点一下就整个关闭，取消十句得重开十次菜单。点控件不会关闭。
        for c in clips {
            let box = NSButton(checkboxWithTitle: String(format: "%02d  %@",c.id,c.label),
                               target: self, action: #selector(toggleExclusionBox(_:)))
            box.tag = c.id
            box.state = excludedIDs.contains(c.id) ? .off : .on
            box.font = .systemFont(ofSize: 12)
            box.sizeToFit()
            let holder = NSMenuItem()
            holder.view = box
            fm.addItem(holder)
        }
        fm.addItem(.separator()); fm.addItem(item("全部恢复",#selector(enableAllClips)))
        filters.submenu = fm; m.addItem(filters)
        m.addItem(item("随机播一次",#selector(randomAction)))
        m.addItem(item("停止播放",#selector(stopAction)))
        m.addItem(.separator())
        let bridgeItem = item(bridgeEnabled ? "关闭捧哏联动" : "开启捧哏联动",#selector(toggleBridge)); bridgeItem.state = bridgeEnabled ? .on : .off; m.addItem(bridgeItem)
        let bridgeInfo = item(bridgeStatus,nil); bridgeInfo.isEnabled = false; m.addItem(bridgeInfo)
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
        // 轮播池：剔掉被勾掉的句子。
        // bag 里存的是下标，用户中途勾掉某句后旧下标会失效，必须先把它清理掉，
        // 否则那句还是会照播 —— 自检里的 excluded 项就是抓这个的。
        let pool = Set(clips.indices.filter { !excludedIDs.contains(clips[$0].id) })
        guard !pool.isEmpty else { return }
        bag.removeAll { !pool.contains($0) }
        if bag.isEmpty {
            bag = Array(pool).shuffled()
            if bag.count > 1, clips[bag.last!].id == lastID { bag.swapAt(0, bag.count - 1) }
        }
        play(clips[bag.removeLast()])
    }
    func play(_ clip: Clip, hop: Int = 0, root: PetRole? = nil) {
        do {
            player?.stop()
            let audio = try AVAudioPlayer(contentsOf: resources.appendingPathComponent("Clips").appendingPathComponent(clip.file))
            player = audio; audio.delegate = self; audio.volume = volume; audio.prepareToPlay()
            guard audio.play() else { throw NSError(domain:"音频播放失败",code:1) }
            lastID = clip.id; pet.animate(true); showCaption(clip.label,seconds:audio.duration+0.5)
            // 自己说完也广播，链上下一环（峰哥）要接我的话。hop 原样带出去。
            if !selfTest { bridge.announceSpeaking(clipID: clip.id, duration: audio.duration, label: clip.label, hop: hop, root: root) }
        } catch { pet.animate(false); showCaption("播放失败：\(error.localizedDescription)",seconds:5) }
    }
    // MARK: - 捧哏联动

    func startBridge() {
        bridge.onPresenceChange = { [weak self] present in
            guard let self else { return }
            self.bridgeStatus = "捧哏：\(self.bridge.peerSummary)"
            guard self.bridgeEnabled else { return }
            self.showCaption(present ? "捧哏就位 · \(self.bridge.peerSummary)说完我接" : "逗哏都走了 · 待命", seconds: 4)
        }
        // 峰哥和薄肌谁说都接，接话池是同一个（28 句「太对了」本来就不挑对象）。
        bridge.onSpoke = { [weak self] from, duration, _, _, hop, root in
            self?.traceLog("收到 \(from.title) 的话 hop=\(hop) root=\(root.title) 时长=\(String(format: "%.2f", duration))")
            self?.scheduleCompanion(after: duration, hop: hop, root: root)
        }
        bridge.start()
        bridgeStatus = "捧哏：\(bridge.peerSummary)"
        // 启动那句提示占着字幕，等它退了再报自己的状态。
        if bridgeEnabled && bridge.peerIsRunning {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                guard let self, self.bridgeEnabled, self.bridge.peerIsRunning else { return }
                if self.player?.isPlaying != true { self.showCaption("捧哏就位 · \(self.bridge.peerSummary)说完我接", seconds: 4) }
            }
        }
    }

    /// 逗哏说完之后排一次接话。
    func scheduleCompanion(after duration: TimeInterval, hop: Int, root: PetRole) {
        guard bridgeEnabled, !selfTest else { return }
        // 薄肌 → 太对了 → 峰哥 → 太对了，到这里是第四跳。再往下接就多出来了。
        guard hop < 3 else { return }
        // 被连点时只留最后一次的捧哏，不然会连播几句叠不上节奏。
        companionWork?.cancel()
        // 先把要接的那句定下来：每句开头静音长短不同，起播时刻得按它自己的静音补。
        guard let clip = takeCompanionClip() else { return }
        let lead = companionLead[clip.id] ?? 0
        // 目标是「对方那句还剩 overlap 秒的时候，捧哏的第一个字正好出来」。
        // 第二跳（太对了接完轮到峰哥）比默认压紧 0.1 秒，四步连起来才不拖。
        let overlap = hop == 1 ? max(0.05, companionOverlap - 0.1) : companionOverlap
        let delay = max(0.02, duration - overlap - lead)
        traceLog("排接话 hop=\(hop) root=\(root.title) 重叠=\(String(format: "%.2f", overlap)) 等=\(String(format: "%.2f", delay)) 句=\(clip.id)")
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.bridgeEnabled else { return }
            // 自己正说着（手点或摇机身）就不叠上去，这一捧算了。
            guard self.player?.isPlaying != true else { return }
            self.traceLog("开口 hop=\(hop + 1) 句=\(clip.id) \(clip.label)")
            self.playCompanion(clip, hop: hop + 1, root: root)
        }
        companionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func takeCompanionClip() -> Clip? {
        if companionBag.isEmpty { companionBag = companionPool.shuffled() }
        return companionBag.popLast()
    }

    func playCompanion(_ clip: Clip, hop: Int, root: PetRole) {
        // 用预解码好的 player 直接起播，绕过 play() 里「读文件再解码」那几十毫秒。
        // 捧哏靠的就是准点，起播晚一点整段节奏就散了。
        if let ready = companionPlayers[clip.id] {
            player?.stop()
            player = ready
            ready.currentTime = 0
            ready.volume = volume
            if ready.play() {
                lastID = clip.id
                pet.animate(true)
                showCaption(clip.label, seconds: ready.duration + 0.5)
                if !selfTest { bridge.announceSpeaking(clipID: clip.id, duration: ready.duration, label: clip.label, hop: hop, root: root) }
                return
            }
        }
        play(clip, hop: hop, root: root)
    }

    /// 启动时把捧哏那几句解码好放在内存里，顺便量出各自的开头静音。
    func preloadCompanionClips() {
        for clip in companionPool {
            let url = resources.appendingPathComponent("Clips").appendingPathComponent(clip.file)
            guard let audio = try? AVAudioPlayer(contentsOf: url) else { continue }
            audio.delegate = self
            audio.volume = volume
            audio.prepareToPlay()
            companionPlayers[clip.id] = audio
            companionLead[clip.id] = leadingSilence(of: url)
        }
    }

    /// 这句音频开头垫了多少静音。阈值按峰值的百分比取，免得把底噪当成人声。
    func leadingSilence(of url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        let rate = file.processingFormat.sampleRate
        // 前 0.6 秒足够，再往后就是人声了。
        let want = AVAudioFrameCount(min(file.length, AVAudioFramePosition(rate * 0.6)))
        guard want > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: want) else { return 0 }
        do { try file.read(into: buffer) } catch { return 0 }
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var peak: Float = 0
        for i in 0..<count { peak = max(peak, abs(channel[i])) }
        let threshold = max(0.004, peak * 0.06)
        for i in 0..<count where abs(channel[i]) > threshold {
            return Double(i) / rate
        }
        return 0
    }

    @objc func toggleBridge() {
        bridgeEnabled.toggle()
        UserDefaults.standard.set(bridgeEnabled, forKey: "bridgeEnabled")
        if !bridgeEnabled { companionWork?.cancel(); companionWork = nil }
        showCaption(bridgeEnabled ? "捧哏联动：开" : "捧哏联动：关", seconds: 3)
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { pet.animate(false) }
    func showCaption(_ text: String, seconds: Double = 3) {
        captionWork?.cancel(); pet.caption.stringValue = text; pet.caption.isHidden = false
        let work = DispatchWorkItem { [weak self] in self?.pet.caption.isHidden = true }; captionWork = work
        DispatchQueue.main.asyncAfter(deadline:.now()+seconds,execute:work)
    }
    @objc func randomAction() { playRandom() }
    /// 菜单里的复选框被点。菜单不会因此关闭，所以可以连着取消好几句。
    @objc func toggleExclusionBox(_ sender: NSButton) {
        let id = sender.tag
        if excludedIDs.contains(id) {
            excludedIDs.remove(id)
        } else {
            guard excludedIDs.count < clips.count - 1 else {
                sender.state = .on
                NSSound.beep()
                return
            }
            excludedIDs.insert(id)
        }
        UserDefaults.standard.set(Array(excludedIDs), forKey: "excludedIDs")
        bag.removeAll()
    }

    /// 勾掉某句：从随机轮播里剔除。至少留一句，否则随机就没东西可播。
    @objc func toggleExclusion(_ sender: NSMenuItem) {
        let id = sender.tag
        if excludedIDs.contains(id) {
            excludedIDs.remove(id)
        } else {
            guard excludedIDs.count < clips.count - 1 else {
                showCaption("至少留一句在轮播里", seconds: 3)
                return
            }
            excludedIDs.insert(id)
        }
        UserDefaults.standard.set(Array(excludedIDs), forKey: "excludedIDs")
        bag.removeAll()
        showCaption("轮播里还有 \(clips.count - excludedIDs.count) 句", seconds: 2)
    }

    @objc func enableAllClips() {
        excludedIDs.removeAll()
        UserDefaults.standard.set([Int](), forKey: "excludedIDs")
        bag.removeAll()
        showCaption("轮播已恢复全部", seconds: 2)
    }
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
    @objc func stopAction() { companionWork?.cancel(); companionWork = nil; player?.stop(); pet.animate(false); pet.caption.isHidden = true }
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
    func applicationWillTerminate(_ notification: Notification) { bridge.stop(); companionWork?.cancel(); motion.stop(); player?.stop(); savePosition() }
    /// 静音读数合理性：不能是负数，也不能长到把整句吃掉。
    func selfTestLeadSanity() -> Bool {
        for clip in companionPool {
            guard let lead = companionLead[clip.id] else { return false }
            if lead < 0 || lead > clip.duration * 0.6 { return false }
        }
        return !companionPool.isEmpty
    }

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
        // 排除：勾掉的句子绝不出现在随机里
        randomMode = true
        let savedExcluded = excludedIDs
        excludedIDs = Set(clips.prefix(2).map(\.id))
        var excludedOK = true
        for _ in 0..<40 {
            player?.stop(); playRandom()
            if let id = lastID, excludedIDs.contains(id) { excludedOK = false }
        }
        if !excludedOK { testOK = false }
        checks.append("excluded: skip=\(excludedIDs.sorted()) clean=\(excludedOK)")
        excludedIDs = savedExcluded
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
        // 捧哏：每句的开头静音都得量出来，否则接话时刻会随抽到的句子飘。
        let leadReport = companionPool.sorted { $0.id < $1.id }
            .map { String(format: "%02d:%.3f", $0.id, companionLead[$0.id] ?? -1) }.joined(separator: " ")
        let leadOK = companionPool.allSatisfy { companionLead[$0.id] != nil } && selfTestLeadSanity()
        if !leadOK { testOK = false }
        checks.append("companion lead: \(leadReport)")
        checks.append("companion preload: \(companionPlayers.count)/\(companionPool.count)")
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
