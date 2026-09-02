// HIDock —— 手搓版 Type2Phone:让 Mac 变成 Android 的蓝牙(BLE HID)键盘
//
// 原理:CoreBluetooth 的 CBPeripheralManager 实现 HID over GATT (HOGP) 服务,
// 对手机暴露一个标准 BLE 键盘;Mac 侧窗口捕获按键,转成 HID 报文 notify 给手机。
//
// 编译: swiftc -O -o HIDock main.swift
// 运行: ./HIDock  (手机蓝牙设置里搜索 "HIDock" 配对)

import Cocoa
import CoreBluetooth

// 在文件底部 main 入口处赋值(先声明供前面类型引用)
var appDelegate: AppDelegate!

// ---------- GATT 常量 ----------
let kDeviceName = "HIDock"
let hidServiceUUID      = CBUUID(string: "00001812-0000-1000-8000-00805F9B34FB")
let hidInfoUUID         = CBUUID(string: "00002A4A-0000-1000-8000-00805F9B34FB")
let reportMapUUID       = CBUUID(string: "00002A4B-0000-1000-8000-00805F9B34FB")
let hidControlPointUUID = CBUUID(string: "00002A4C-0000-1000-8000-00805F9B34FB")
let reportUUID          = CBUUID(string: "00002A4D-0000-1000-8000-00805F9B34FB")
let protocolModeUUID    = CBUUID(string: "00002A4E-0000-1000-8000-00805F9B34FB")
let reportRefDescUUID   = CBUUID(string: "00002908-0000-1000-8000-00805F9B34FB")
let batteryServiceUUID  = CBUUID(string: "0000180F-0000-1000-8000-00805F9B34FB")
let batteryLevelUUID    = CBUUID(string: "00002A19-0000-1000-8000-00805F9B34FB")
let devInfoServiceUUID  = CBUUID(string: "0000180A-0000-1000-8000-00805F9B34FB")
let manufacturerUUID    = CBUUID(string: "00002A29-0000-1000-8000-00805F9B34FB")
let modelNumberUUID     = CBUUID(string: "00002A24-0000-1000-8000-00805F9B34FB")

// 标准键盘 report map:Report ID 1 = modifier(1B) + 保留(1B) + 键(6B)
// 追加鼠标 report map:Report ID 2 = 按键(1B) + X/Y 相对位移(各2B) + 滚轮(1B)
let reportMapData = Data([
    0x05, 0x01,       // Usage Page (Generic Desktop)
    0x09, 0x06,       // Usage (Keyboard)
    0xA1, 0x01,       // Collection (Application)
    0x85, 0x01,       //   Report ID (1)
    0x05, 0x07,       //   Usage Page (Key Codes)
    0x19, 0xE0, 0x29, 0xE7,  //   Usage Min/Max (Modifier keys)
    0x15, 0x00, 0x25, 0x01,  //   Logical Min/Max
    0x75, 0x01, 0x95, 0x08,  //   Report Size/Count (modifier byte)
    0x81, 0x02,       //   Input (Data, Var, Abs)
    0x95, 0x01, 0x75, 0x08,  //   Reserved byte
    0x81, 0x01,       //   Input (Const)
    0x95, 0x06, 0x75, 0x08,  //   6-key rollover
    0x15, 0x00, 0x25, 0x65,  //   Logical Min/Max (keycodes)
    0x05, 0x07, 0x19, 0x00, 0x29, 0x65,
    0x81, 0x00,       //   Input (Data, Array)
    0xC0,             // End Collection (Keyboard)

    0x05, 0x01,       // Usage Page (Generic Desktop)
    0x09, 0x02,       // Usage (Mouse)
    0xA1, 0x01,       // Collection (Application)
    0x85, 0x02,       //   Report ID (2)
    0x09, 0x01,       //   Usage (Pointer)
    0xA1, 0x00,       //   Collection (Physical)
    0x05, 0x09,       //     Usage Page (Buttons)
    0x19, 0x01, 0x29, 0x03,  //   Buttons 1–3
    0x15, 0x00, 0x25, 0x01,
    0x75, 0x01, 0x95, 0x03,
    0x81, 0x02,       //     Input (Data, Var, Abs)
    0x75, 0x05, 0x95, 0x01,
    0x81, 0x01,       //     Input (Const) — 5bit 填充
    0x05, 0x01,       //     Usage Page (Generic Desktop)
    0x09, 0x30, 0x09, 0x31,  //   Usage X / Y
    0x16, 0x01, 0x80, //     Logical Min (-32767)
    0x26, 0xFF, 0x7F, //     Logical Max (32767)
    0x75, 0x10, 0x95, 0x02,
    0x81, 0x06,       //     Input (Data, Var, Rel)
    0x09, 0x38,       //     Usage (Wheel)
    0x15, 0x81, 0x25, 0x7F,  //   Logical Min/Max (-127/127)
    0x75, 0x08, 0x95, 0x01,
    0x81, 0x06,       //     Input (Data, Var, Rel)
    0xC0,             //   End Collection (Physical)
    0xC0              // End Collection (Mouse)
])

// ---------- 键码映射 ----------
// 可打印字符 → (HID usage, 是否需要 Shift),美式布局
var charToUsage: [Character: (UInt8, Bool)] = [:]
func buildCharTable() {
    let lower = "abcdefghijklmnopqrstuvwxyz"
    for (i, c) in lower.enumerated() {
        charToUsage[c] = (UInt8(0x04 + i), false)
        charToUsage[Character(c.uppercased())] = (UInt8(0x04 + i), true)
    }
    for (i, c) in "1234567890".enumerated() { charToUsage[c] = (UInt8(0x1E + i), false) }
    for (i, c) in "!@#$%^&*()".enumerated() { charToUsage[c] = (UInt8(0x1E + i), true) }
    let pairs: [(Character, Character, UInt8)] = [
        ("-", "_", 0x2D), ("=", "+", 0x2E), ("[", "{", 0x2F), ("]", "}", 0x30),
        ("\\", "|", 0x31), (";", ":", 0x33), ("'", "\"", 0x34), ("`", "~", 0x35),
        (",", "<", 0x36), (".", ">", 0x37), ("/", "?", 0x38),
    ]
    for (plain, shifted, u) in pairs {
        charToUsage[plain] = (u, false)
        charToUsage[shifted] = (u, true)
    }
    charToUsage[" "] = (0x2C, false)
    charToUsage["\r"] = (0x28, false)
    charToUsage["\t"] = (0x2B, false)
}

// 功能键(NSEvent characters 里的 F7xx 系列/控制字符)→ HID usage
func functionKeyUsage(_ u: UInt16) -> UInt8? {
    switch u {
    case 0x7F:   return 0x2A  // Delete/退格(NSDeleteCharacter 的实际编码)
    case 0x03:   return 0x28  // 小键盘 Enter
    case 0x1B:   return 0x29  // Esc
    case 0xF700: return 0x52  // ↑
    case 0xF701: return 0x51  // ↓
    case 0xF702: return 0x50  // ←
    case 0xF703: return 0x4F  // →
    case 0xF728: return 0x2A  // Backspace
    case 0xF727: return 0x4C  // Forward Delete
    case 0xF729: return 0x4A  // Home
    case 0xF72B: return 0x4D  // End
    case 0xF72C: return 0x4B  // PageUp
    case 0xF72D: return 0x4E  // PageDown
    case 0xF704...0xF70F: return UInt8(0x3A + Int(u - 0xF704))  // F1–F12
    default: return nil
    }
}

// ---------- 键盘状态机 ----------
final class HidKeyboard {
    var modifier: UInt8 = 0
    var keys: [UInt8] = []
    var lastReport = Data(repeating: 0, count: 8)
    var ble: BlePeripheral?

    func report() -> Data {
        var d = Data([modifier, 0])
        for k in keys.prefix(6) { d.append(k) }
        while d.count < 8 { d.append(0) }
        lastReport = d
        return d
    }
    // 必须用 report() 现算报文(同时刷新 lastReport),不能发缓存的旧值
    func send() { ble?.sendReport(report()) }

    func keyDown(usage: UInt8, shifted: Bool) {
        if shifted { modifier |= 0x02 }
        if !keys.contains(usage) && keys.count < 6 { keys.append(usage) }
        send()
    }
    func keyUp(usage: UInt8, shifted: Bool) {
        if let i = keys.firstIndex(of: usage) { keys.remove(at: i) }
        if shifted { modifier &= ~0x02 }
        send()
    }
    func modifiersChanged(_ m: UInt8) {
        modifier = m
        send()
    }
    static func modifierBits(_ f: NSEvent.ModifierFlags) -> UInt8 {
        var b: UInt8 = 0
        if f.contains(.shift)   { b |= 0x02 }
        if f.contains(.control) { b |= 0x01 }
        if f.contains(.option)  { b |= 0x04 }
        if f.contains(.command) { b |= 0x08 }
        return b
    }
}

// 全局唯一实例:CaptureView 与 BlePeripheral 共用,避免相互持有
let sharedKeyboard = HidKeyboard()

// ---------- BLE 外设端 ----------
final class BlePeripheral: NSObject, CBPeripheralManagerDelegate {
    var pm: CBPeripheralManager!
    var reportChar: CBMutableCharacteristic!
    var mouseReportChar: CBMutableCharacteristic!
    var protocolModeChar: CBMutableCharacteristic!
    var subscribedCentrals: [UUID: CBCentral] = [:]
    var mouseSubscribedCentrals: [UUID: CBCentral] = [:]
    var lastMouseReport = Data(repeating: 0, count: 6)
    var authedCentrals = Set<UUID>()
    var onStatus: (String) -> Void = { _ in }
    var onCentralsChanged: (Int) -> Void = { _ in }
    private var setupStage = 0

    override init() {
        super.init()
        pm = CBPeripheralManager(delegate: self, queue: nil)
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            if setupStage == 0 { addNextService() }
            else if !peripheral.isAdvertising { startAdv() }
        default:
            onStatus("蓝牙未就绪(state=\(peripheral.state.rawValue)),请打开 Mac 蓝牙")
        }
    }

    // addService 一次只能加一个。只注册 HID 服务(电量/设备信息这类穿戴设备
    // 常见服务会被部分安卓 ROM 当成手表/手环的依据,全部砍掉)
    private func addNextService() {
        switch setupStage {
        case 0:
            let reportRef = CBMutableDescriptor(type: reportRefDescUUID, value: Data([0x01, 0x01])) // Report ID 1, Input
            // 真键盘行为:Report 通道要求加密(读+订阅),发现阶段的 Report Map/HID Info 保持明文,
            // 安卓流程变成「先发现服务看到键盘 → 订阅时才配对」,避开 macOS「先 bond 后枚举」的坑
            var reportPerms: CBAttributePermissions = [.readable, .readEncryptionRequired]
            reportPerms.insert(CBAttributePermissions(rawValue: 0x10))  // notifyEncryptionRequired
            reportChar = CBMutableCharacteristic(type: reportUUID, properties: [.read, .notify],
                                                 value: nil, permissions: reportPerms)
            reportChar.descriptors = [reportRef]

            // 鼠标 Report(Report ID 2):与键盘 Report 同 UUID、不同实例,各自挂 2908 描述符
            let mouseRef = CBMutableDescriptor(type: reportRefDescUUID, value: Data([0x02, 0x01])) // Report ID 2, Input
            mouseReportChar = CBMutableCharacteristic(type: reportUUID, properties: [.read, .notify],
                                                      value: nil, permissions: reportPerms)
            mouseReportChar.descriptors = [mouseRef]

            let hidInfo = CBMutableCharacteristic(type: hidInfoUUID, properties: .read,
                value: Data([0x11, 0x01, 0x02]), permissions: [.readable])  // HID 1.1, normally connectable
            let reportMap = CBMutableCharacteristic(type: reportMapUUID, properties: .read,
                value: nil, permissions: [.readable])  // 明文返回(ESP32-BLE-Keyboard 同款做法)
            let controlPoint = CBMutableCharacteristic(type: hidControlPointUUID, properties: [.writeWithoutResponse],
                value: nil, permissions: [.writeable])
            // 本 SDK 要求带缓存值的 characteristic 必须只读,Protocol Mode 需可写 → 用动态值
            protocolModeChar = CBMutableCharacteristic(type: protocolModeUUID, properties: [.read, .writeWithoutResponse],
                value: nil, permissions: [.readable, .writeable])  // 1 = Report Protocol

            let hid = CBMutableService(type: hidServiceUUID, primary: true)
            hid.characteristics = [hidInfo, reportMap, controlPoint, protocolModeChar, reportChar, mouseReportChar]
            pm.add(hid)
        default:
            startAdv()
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error = error { onStatus("添加服务失败: \(error.localizedDescription)") }
        setupStage += 1
        addNextService()
    }

    private func startAdv() {
        pm.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [hidServiceUUID],
            CBAdvertisementDataLocalNameKey: kDeviceName,
            "kCBAdvDataAppearance": 961,  // HID Keyboard 外观值,避免被按默认外观归类
        ])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error = error {
            onStatus("广播失败: \(error.localizedDescription)")
        } else {
            onStatus("广播中,请在手机蓝牙设置里配对 \"\(kDeviceName)\"")
        }
    }

    // 读:Report Map 首次读回 insufficientAuthentication 触发配对加密,配对后正常返回
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        let c = request.characteristic
        NSLog("HIDock: [read] %@ offset=%d central=%@", c.uuid.uuidString, request.offset,
              request.central.identifier.uuidString)
        func serve(_ data: Data) {
            guard request.offset <= data.count else {
                peripheral.respond(to: request, withResult: .invalidOffset); return
            }
            request.value = data.subdata(in: request.offset..<data.count)
            peripheral.respond(to: request, withResult: .success)
        }
        // 两个 Report 特征同 UUID,按实例区分
        if c === reportChar {
            serve(sharedKeyboard.lastReport)
        } else if c === mouseReportChar {
            serve(lastMouseReport)
        } else { switch c.uuid {
        case reportMapUUID:
            // 不设认证门槛:安卓 GATT 发现阶段读到 insufficientAuthentication 会放弃 HID 服务,
            // 转而按残余服务把设备归为穿戴设备("识别成手表"的根源),明文返回即可
            serve(reportMapData)
        case hidInfoUUID:      serve(Data([0x11, 0x01, 0x02]))
        case protocolModeUUID: serve(Data([0x01]))
        case batteryLevelUUID: serve(Data([100]))
        case manufacturerUUID: serve(Data("ZCode".utf8))
        case modelNumberUUID:  serve(Data("HIDock-手搓版".utf8))
        default: peripheral.respond(to: request, withResult: .readNotPermitted)
        }
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for r in requests {
            let hex = (r.value ?? Data()).map { String(format: "%02X", $0) }.joined()
            NSLog("HIDock: [write] %@ value=%@", r.characteristic.uuid.uuidString, hex)
            let ok = r.characteristic.uuid == hidControlPointUUID || r.characteristic.uuid == protocolModeUUID
            peripheral.respond(to: r, withResult: ok ? .success : .writeNotPermitted)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        if characteristic === mouseReportChar {
            mouseSubscribedCentrals[central.identifier] = central
            onStatus("鼠标通道就绪 ✓ 窗口下方触控板区域可用")
        } else if characteristic.uuid == reportUUID {
            subscribedCentrals[central.identifier] = central
            onStatus("已连接 ✓ 现在在窗口里打字即可上手机")
        }
        onCentralsChanged(subscribedCentrals.count + mouseSubscribedCentrals.count)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        subscribedCentrals.removeValue(forKey: central.identifier)
        mouseSubscribedCentrals.removeValue(forKey: central.identifier)
        onCentralsChanged(subscribedCentrals.count + mouseSubscribedCentrals.count)
        if subscribedCentrals.isEmpty && mouseSubscribedCentrals.isEmpty {
            onStatus("已断开,重新广播等待回连…")
            if !pm.isAdvertising { startAdv() }
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        if !subscribedCentrals.isEmpty {
            _ = pm.updateValue(sharedKeyboard.lastReport, for: reportChar, onSubscribedCentrals: Array(subscribedCentrals.values))
        }
        if !mouseSubscribedCentrals.isEmpty {
            _ = pm.updateValue(lastMouseReport, for: mouseReportChar, onSubscribedCentrals: Array(mouseSubscribedCentrals.values))
        }
    }
    func sendReport(_ data: Data) {
        guard pm.state == .poweredOn, !subscribedCentrals.isEmpty, let rc = reportChar else { return }
        let ok = pm.updateValue(data, for: rc, onSubscribedCentrals: Array(subscribedCentrals.values))
        NSLog("HIDock: [notify] %@ ok=%d", data.map { String(format: "%02X", $0) }.joined(), ok ? 1 : 0)
    }
    func sendMouseReport(_ data: Data) {
        guard pm.state == .poweredOn, !mouseSubscribedCentrals.isEmpty, let rc = mouseReportChar else { return }
        lastMouseReport = data
        _ = pm.updateValue(data, for: rc, onSubscribedCentrals: Array(mouseSubscribedCentrals.values))
        // 移动报文量大,只记录点击/滚动,避免日志刷屏
        if data[0] != 0 || data[5] != 0 {
            NSLog("HIDock: [mouse] %@", data.map { String(format: "%02X", $0) }.joined())
        }
    }
}

// ---------- 手机面板:打字 + 触控板合一 ----------
// 面板尺寸 = 小米 17 Ultra 机身 1:1(77.6mm × 162.9mm ≈ 220 × 462pt,1pt = 0.3528mm)
let kPhoneW: CGFloat = 220
let kPhoneH: CGFloat = 462

final class CaptureView: NSView {
    let kb = sharedKeyboard
    var onMouseReport: ((Data) -> Void)?
    var trackpadEnabled = true
    private var mButtons: UInt8 = 0
    private var pendingDx = 0, pendingDy = 0, pendingWheel = 0
    private var lastSent = Date.distantPast
    private var lastMoveLog = Date.distantPast

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .enabledDuringMouseDrag],
            owner: self, userInfo: nil))
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 28, yRadius: 28)
        NSColor(calibratedWhite: 0.13, alpha: 1).setFill()
        path.fill()
        let hint = "点按面板获得焦点后打字\n光标在面板上滑动 = 手机触控板\n单击=左键 · 右键=返回 · 双指滚动(修复中)"
        (hint as NSString).draw(at: NSPoint(x: 14, y: bounds.height - 46),
            withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                             .foregroundColor: NSColor.lightGray])
    }

    // ===== 键盘 =====
    // Mac 中文输入法会把标点变成全角(,。/等),折回半角再查表
    private func normalizeFullWidth(_ c: Character) -> Character? {
        guard let scalar = c.unicodeScalars.first, (0xFF01...0xFF5E).contains(scalar.value) else { return nil }
        guard let ascii = Unicode.Scalar(scalar.value - 0xFEE0) else { return nil }
        return Character(ascii)
    }

    private func usageFor(_ event: NSEvent) -> (UInt8, Bool)? {
        if let chars = event.characters {
            for c in chars {
                if let (u, s) = charToUsage[c] { return (u, s) }
                if let n = normalizeFullWidth(c), let (u, s) = charToUsage[n] { return (u, s) }
            }
            if let u16 = chars.utf16.first, let u = functionKeyUsage(u16) { return (u, false) }
        }
        if let c = event.charactersIgnoringModifiers?.first {
            if let (u, s) = charToUsage[c] { return (u, s) }
            if let n = normalizeFullWidth(c), let (u, s) = charToUsage[n] { return (u, s) }
        }
        return nil
    }

    override func keyDown(with event: NSEvent) {
        if let (u, s) = usageFor(event) {
            NSLog("HIDock: [key] down 0x%02X shift=%d", u, s ? 1 : 0)
            kb.keyDown(usage: u, shifted: s); appDelegate.logKey(u, down: true)
        }
    }
    override func keyUp(with event: NSEvent) {
        if let (u, s) = usageFor(event) { kb.keyUp(usage: u, shifted: s); appDelegate.logKey(u, down: false) }
    }
    override func flagsChanged(with event: NSEvent) {
        kb.modifiersChanged(HidKeyboard.modifierBits(event.modifierFlags))
    }

    // ===== 触控板 =====
    private func moveLog(_ tag: String, _ event: NSEvent) {
        guard Date().timeIntervalSince(lastMoveLog) > 0.3 else { return }
        lastMoveLog = Date()
        NSLog("HIDock: [%@] dx=%.1f dy=%.1f scroll=%.1f momentum=%d", tag,
              event.deltaX, event.deltaY, event.scrollingDeltaY, event.momentumPhase.rawValue)
    }

    // 12ms 节流合帧(~83Hz):BLE 链路常态容量撑不起 125Hz,留余量防队列饱和
    private func enqueue(dx: Int, dy: Int, wheel: Int = 0, force: Bool = false) {
        guard trackpadEnabled else { return }
        pendingDx += dx; pendingDy += dy; pendingWheel += wheel
        guard force || mButtons != 0 || Date().timeIntervalSince(lastSent) >= 0.012 else { return }
        guard force || pendingDx != 0 || pendingDy != 0 || pendingWheel != 0 else { return }
        func le16(_ x: Int) -> [UInt8] {
            let u = UInt16(bitPattern: Int16(clamping: x))
            return [UInt8(u & 0xFF), UInt8(u >> 8)]
        }
        // 单帧位移上限:三指拖移这类多指手势会吐出巨大的 delta,一帧把手机指针
        // 甩到屏幕边缘会触发安卓系统手势(下拉通知栏/边缘返回),打断手机正在
        // 进行的播报/操作;超限部分直接丢弃,兼作限速
        func cap(_ x: Int, _ m: Int) -> Int { min(max(x, -m), m) }
        var d = Data([mButtons])
        d.append(contentsOf: le16(cap(pendingDx, 1024)))
        d.append(contentsOf: le16(cap(pendingDy, 1024)))
        // 滚轮字节要的是 Int8 的补码重解释。曾写成 UInt8(Int8(...)):那是陷阱式
        // 初始化器,值为负直接 EXC_BREAKPOINT —— 滚轮路径历史崩溃的真正根源
        d.append(UInt8(bitPattern: Int8(clamping: cap(pendingWheel, 60))))
        onMouseReport?(d)
        pendingDx = 0; pendingDy = 0; pendingWheel = 0
        lastSent = Date()
    }

    // CGFloat → Int 防御:NaN/无穷/溢出在 Int() 里是运行时陷阱
    private static func clampDelta(_ f: CGFloat) -> Int {
        guard f.isFinite, abs(f) < 30000 else { return 0 }
        return Int(f)
    }

    override func mouseMoved(with event: NSEvent) {
        moveLog("move", event)
        // 实测 Y 与直觉相反:dy 直接用正 delta(再反了就改回负号)
        enqueue(dx: CaptureView.clampDelta(event.deltaX), dy: CaptureView.clampDelta(event.deltaY))
    }
    override func mouseDragged(with event: NSEvent) {
        enqueue(dx: CaptureView.clampDelta(event.deltaX), dy: CaptureView.clampDelta(event.deltaY))
    }
    override func otherMouseDragged(with event: NSEvent) {
        enqueue(dx: CaptureView.clampDelta(event.deltaX), dy: CaptureView.clampDelta(event.deltaY))
    }
    override func scrollWheel(with event: NSEvent) {
        moveLog("scroll", event)
        // 双指滚动 → 手机滚轮(仅纵向;横向要动 Report Map,会让已配对手机的缓存失效,不做)。
        // 此路径当年 EXC_BREAKPOINT 的根源:直接 Int(scrollingDeltaY) 遇到 NaN/inf 是运行时陷阱,
        // 统一走 clampDelta 防御即可。方向反了就翻符号
        let dy = CaptureView.clampDelta(event.scrollingDeltaY)
        guard dy != 0 else { return }
        enqueue(dx: 0, dy: 0, wheel: -dy)
    }

    private func setButton(_ bit: UInt8, on: Bool) {
        if on { mButtons |= bit } else { mButtons &= ~bit }
        enqueue(dx: 0, dy: 0, force: true)
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        setButton(0x01, on: true)
    }
    override func mouseUp(with event: NSEvent) { setButton(0x01, on: false) }
    override func rightMouseDown(with event: NSEvent) { setButton(0x02, on: true) }
    override func rightMouseUp(with event: NSEvent) { setButton(0x02, on: false) }
    override func otherMouseDown(with event: NSEvent) { setButton(0x04, on: true) }
    override func otherMouseUp(with event: NSEvent) { setButton(0x04, on: false) }
}

// ---------- App ----------
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var container: NSView!
    var statusLabel: NSTextField!
    var logLabel: NSTextField!
    var phonePanel: CaptureView!
    var orientButton: NSButton!
    var trackpadButton: NSButton!
    var resetButton: NSButton!
    let ble = BlePeripheral()
    var landscape = false
    static let toolbarH: CGFloat = 64

    var kb: HidKeyboard { sharedKeyboard }
    func logKey(_ u: UInt8, down: Bool) {
        DispatchQueue.main.async {
            self.logLabel.stringValue = String(format: "%@ usage=0x%02X", down ? "↓" : "↑", u)
        }
    }

    @objc func toggleOrientation(_ sender: NSButton) {
        landscape.toggle()
        layoutWindow()
    }
    @objc func toggleTrackpad(_ sender: NSButton) {
        phonePanel.trackpadEnabled.toggle()
        sender.title = phonePanel.trackpadEnabled ? "触控板:开" : "触控板:关"
    }
    @objc func resetSize(_ sender: NSButton) { layoutWindow() }

    // 按当前横竖方向重排:面板 1:1 真机尺寸,工具栏在上方
    func layoutWindow() {
        let panelW = landscape ? kPhoneH : kPhoneW
        let panelH = landscape ? kPhoneW : kPhoneH
        let totalH = panelH + Self.toolbarH
        container.frame = NSRect(x: 0, y: 0, width: panelW, height: totalH)
        phonePanel.frame = NSRect(x: 0, y: 0, width: panelW, height: panelH)
        statusLabel.frame = NSRect(x: 10, y: panelH + 44, width: panelW - 20, height: 16)
        logLabel.frame = NSRect(x: 10, y: panelH + 28, width: panelW - 20, height: 14)
        let bw: CGFloat = 64, gap: CGFloat = 8
        let x0 = (panelW - (3 * bw + 2 * gap)) / 2
        orientButton.frame = NSRect(x: x0, y: panelH + 2, width: bw, height: 22)
        trackpadButton.frame = NSRect(x: x0 + bw + gap, y: panelH + 2, width: bw, height: 22)
        resetButton.frame = NSRect(x: x0 + 2 * (bw + gap), y: panelH + 2, width: bw, height: 22)
        orientButton.title = landscape ? "切竖屏" : "切横屏"
        window.setContentSize(NSSize(width: panelW, height: totalH))
        window.center()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildCharTable()
        sharedKeyboard.ble = ble
        ble.onStatus = { text in
            NSLog("HIDock: %@", text)
            DispatchQueue.main.async { self.statusLabel.stringValue = text }
        }
        ble.onCentralsChanged = { n in
            DispatchQueue.main.async {
                self.window.title = n > 0 ? "HIDock — 已连接" : "HIDock — 等待连接"
            }
        }

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: kPhoneW, height: kPhoneH + Self.toolbarH),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "HIDock — 手机面板"

        container = NSView(frame: NSRect(x: 0, y: 0, width: kPhoneW, height: kPhoneH + Self.toolbarH))
        statusLabel = NSTextField(labelWithString: "初始化蓝牙…")
        statusLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        logLabel = NSTextField(labelWithString: "")
        logLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        logLabel.textColor = .tertiaryLabelColor

        phonePanel = CaptureView(frame: NSRect(x: 0, y: 0, width: kPhoneW, height: kPhoneH))
        phonePanel.onMouseReport = { appDelegate.ble.sendMouseReport($0) }

        orientButton = NSButton(title: "切横屏", target: self, action: #selector(toggleOrientation(_:)))
        trackpadButton = NSButton(title: "触控板:开", target: self, action: #selector(toggleTrackpad(_:)))
        resetButton = NSButton(title: "1:1 大小", target: self, action: #selector(resetSize(_:)))
        orientButton.bezelStyle = .rounded
        trackpadButton.bezelStyle = .rounded
        resetButton.bezelStyle = .rounded

        container.addSubview(statusLabel)
        container.addSubview(logLabel)
        container.addSubview(orientButton)
        container.addSubview(trackpadButton)
        container.addSubview(resetButton)
        container.addSubview(phonePanel)
        window.contentView = container
        layoutWindow()
        window.makeKeyAndOrderFront(nil)
        window.initialFirstResponder = phonePanel
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

appDelegate = AppDelegate()
let app = NSApplication.shared
app.delegate = appDelegate
app.setActivationPolicy(.regular)
app.run()
