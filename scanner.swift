// 同机冒烟测试:验证 MacBLEKey 是否真的在广播 BLE HID 键盘服务 (0x1812)
// 编译: swiftc -O -o scanner scanner.swift

import Foundation
import CoreBluetooth

final class Scanner: NSObject, CBCentralManagerDelegate {
    var cm: CBCentralManager!
    let hidService = CBUUID(string: "1812")

    func run() {
        cm = CBCentralManager(delegate: self, queue: nil)
        RunLoop.main.run()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            print("BLUETOOTH_NOT_ON state=\(central.state.rawValue)")
            exit(1)
        }
        print("scanning for service 0x1812 (8s)...")
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            print("SCAN_DONE")
            exit(0)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? peripheral.name ?? "(no name)"
        print("FOUND name=\(name) rssi=\(RSSI) uuid=\(peripheral.identifier)")
    }
}

Scanner().run()
