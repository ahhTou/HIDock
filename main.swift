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
    0xC0              // End Collection
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
    var protocolModeChar: CBMutableCharacteristic!
    var subscribedCentrals: [UUID: CBCentral] = [:]
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
            hid.characteristics = [hidInfo, reportMap, controlPoint, protocolModeChar, reportChar]
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
        switch c.uuid {
        case reportMapUUID:
            // 不设认证门槛:安卓 GATT 发现阶段读到 insufficientAuthentication 会放弃 HID 服务,
            // 转而按残余服务把设备归为穿戴设备("识别成手表"的根源),明文返回即可
            serve(reportMapData)
        case hidInfoUUID:      serve(Data([0x11, 0x01, 0x02]))
        case protocolModeUUID: serve(Data([0x01]))
        case reportUUID:       serve(sharedKeyboard.lastReport)
        case batteryLevelUUID: serve(Data([100]))
        case manufacturerUUID: serve(Data("ZCode".utf8))
        case modelNumberUUID:  serve(Data("HIDock-手搓版".utf8))
        default: peripheral.respond(to: request, withResult: .readNotPermitted)
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
        guard characteristic.uuid == reportUUID else { return }
        subscribedCentrals[central.identifier] = central
        onCentralsChanged(subscribedCentrals.count)
        onStatus("已连接 ✓ 现在在窗口里打字即可上手机")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        subscribedCentrals.removeValue(forKey: central.identifier)
        onCentralsChanged(subscribedCentrals.count)
        if subscribedCentrals.isEmpty {
            onStatus("已断开,重新广播等待回连…")
            if !pm.isAdvertising { startAdv() }
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        _ = pm.updateValue(sharedKeyboard.lastReport, for: reportChar, onSubscribedCentrals: Array(subscribedCentrals.values))
    }
    func sendReport(_ data: Data) {
        guard pm.state == .poweredOn, !subscribedCentrals.isEmpty, let rc = reportChar else { return }
        let ok = pm.updateValue(data, for: rc, onSubscribedCentrals: Array(subscribedCentrals.values))
        NSLog("HIDock: [notify] %@ ok=%d", data.map { String(format: "%02X", $0) }.joined(), ok ? 1 : 0)
    }
}

// ---------- 捕获按键的视图 ----------
final class CaptureView: NSView {
    let kb = sharedKeyboard
    override var acceptsFirstResponder: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        let hint = "① 手机蓝牙设置 → 配对 \"HIDock\"\n② 点一下本区域,打字即实时发送到手机\n(英文/数字/符号/回车退格方向键均支持;中文见 README)"
        (hint as NSString).draw(at: NSPoint(x: 20, y: bounds.height - 60),
            withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                             .foregroundColor: NSColor.secondaryLabelColor])
    }

    // Mac 中文输入法会把标点变成全角(，。／等),折回半角再查表
    private func normalizeFullWidth(_ c: Character) -> Character? {
        guard let scalar = c.unicodeScalars.first, (0xFF01...0xFF5E).contains(scalar.value) else { return nil }
        guard let ascii = Unicode.Scalar(scalar.value - 0xFEE0) else { return nil }
        return Character(ascii)
    }

    private func usageFor(_ event: NSEvent) -> (UInt8, Bool)? {
        // 先查带 Shift 的实际字符(大写/符号),再查裸字符,最后查功能键
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
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func flagsChanged(with event: NSEvent) {
        kb.modifiersChanged(HidKeyboard.modifierBits(event.modifierFlags))
    }
}

// ---------- App ----------
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var statusLabel: NSTextField!
    var logLabel: NSTextField!
    var captureView: CaptureView!
    let ble = BlePeripheral()

    var kb: HidKeyboard { sharedKeyboard }
    func logKey(_ u: UInt8, down: Bool) {
        DispatchQueue.main.async {
            self.logLabel.stringValue = String(format: "%@ usage=0x%02X", down ? "↓" : "↑", u)
        }
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

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "HIDock — 手搓版 Type2Phone"

        statusLabel = NSTextField(labelWithString: "初始化蓝牙…")
        statusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel.frame = NSRect(x: 20, y: 270, width: 420, height: 20)

        logLabel = NSTextField(labelWithString: "")
        logLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logLabel.textColor = .tertiaryLabelColor
        logLabel.frame = NSRect(x: 20, y: 248, width: 420, height: 16)

        captureView = CaptureView(frame: NSRect(x: 0, y: 0, width: 460, height: 240))

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 320))
        container.addSubview(statusLabel)
        container.addSubview(logLabel)
        container.addSubview(captureView)
        window.contentView = container
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.initialFirstResponder = captureView
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

appDelegate = AppDelegate()
let app = NSApplication.shared
app.delegate = appDelegate
app.setActivationPolicy(.regular)
app.run()
