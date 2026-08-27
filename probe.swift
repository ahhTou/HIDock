// 探针:逐个加服务,定位哪个 UUID/特征组合被 macOS CoreBluetooth 拒绝
// 用法: ./probe <hid|hid_nodesc|hid_min|battery|devinfo>
import Foundation
import CoreBluetooth

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "hid"
let hidUUID = CBUUID(string: "1812")

final class Probe: NSObject, CBPeripheralManagerDelegate {
    var pm: CBPeripheralManager!
    func run() {
        pm = CBPeripheralManager(delegate: self, queue: nil)
        RunLoop.main.run()
    }
    func peripheralManagerDidUpdateState(_ p: CBPeripheralManager) {
        guard p.state == .poweredOn else { NSLog("state=%d", p.state.rawValue); exit(1) }
        NSLog("poweredOn, mode=%@", mode)
        var chars: [CBMutableCharacteristic] = []
        let reportRef = CBMutableDescriptor(type: CBUUID(string: "2908"), value: Data([0x01, 0x01]))
        switch mode {
        case "hid", "hid_nodesc":
            let hidInfo = CBMutableCharacteristic(type: CBUUID(string: "2A4A"), properties: .read,
                value: Data([0x11, 0x01, 0x02]), permissions: [.readable])
            let reportMap = CBMutableCharacteristic(type: CBUUID(string: "2A4B"), properties: .read,
                value: nil, permissions: [.readable])
            let cp = CBMutableCharacteristic(type: CBUUID(string: "2A4C"), properties: [.writeWithoutResponse],
                value: nil, permissions: [.writeable])
            let pmc = CBMutableCharacteristic(type: CBUUID(string: "2A4E"), properties: [.read, .writeWithoutResponse],
                value: nil, permissions: [.readable, .writeable])
            let report = CBMutableCharacteristic(type: CBUUID(string: "2A4D"), properties: [.read, .notify],
                value: nil, permissions: [.readable])
            if mode != "hid_nodesc" { report.descriptors = [reportRef] }
            chars = [hidInfo, reportMap, cp, pmc, report]
        case "hid_min":
            let report = CBMutableCharacteristic(type: CBUUID(string: "2A4D"), properties: [.read, .notify],
                value: nil, permissions: [.readable])
            report.descriptors = [reportRef]
            let reportMap = CBMutableCharacteristic(type: CBUUID(string: "2A4B"), properties: .read,
                value: nil, permissions: [.readable])
            chars = [reportMap, report]
        case "battery":
            let level = CBMutableCharacteristic(type: CBUUID(string: "2A19"), properties: [.read, .notify],
                value: nil, permissions: [.readable])
            chars = [level]
        case "hid_full_uuid":
            let report = CBMutableCharacteristic(type: CBUUID(string: "2A4D"), properties: [.read, .notify],
                value: nil, permissions: [.readable])
            chars = [report]
        case "ffe0":
            let c = CBMutableCharacteristic(type: CBUUID(string: "FFE1"), properties: [.read, .notify],
                value: nil, permissions: [.readable])
            chars = [c]
        case "custom":
            let c = CBMutableCharacteristic(type: CBUUID(string: "E4C50A61-3E9B-4B91-9E61-0B0D5B3A5E1F"), properties: [.read, .notify],
                value: nil, permissions: [.readable])
            chars = [c]
        case "devinfo":
            let mfr = CBMutableCharacteristic(type: CBUUID(string: "2A29"), properties: .read,
                value: Data("ZCode".utf8), permissions: [.readable])
            chars = [mfr]
        default:
            NSLog("unknown mode"); exit(1)
        }
        let uuid = (mode == "battery") ? CBUUID(string: "180F") : (mode == "devinfo" ? CBUUID(string: "180A") : (mode == "custom" ? CBUUID(string: "E4C50A60-3E9B-4B91-9E61-0B0D5B3A5E1F") : (mode == "hid_full_uuid" ? CBUUID(string: "00001812-0000-1000-8000-00805F9B34FB") : (mode == "ffe0" ? CBUUID(string: "FFE0") : hidUUID))))
        let svc = CBMutableService(type: uuid, primary: true)
        svc.characteristics = chars
        pm.add(svc)  // 若非法配置,这里会同步抛异常
    }
    func peripheralManager(_ p: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let e = error { NSLog("RESULT mode=%@ FAIL: %@", mode, e.localizedDescription) }
        else { NSLog("RESULT mode=%@ OK service=%@", mode, service.uuid.uuidString) }
        exit(0)
    }
}
Probe().run()
