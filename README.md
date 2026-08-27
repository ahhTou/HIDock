# HIDock ⌨️👆

> **把 Mac 变成手机的「蓝牙输入坞」** —— 单文件 Swift,零依赖,手机端零安装
>
> 由 **GLM-5.3** 手搓实现 · macOS 15 + 小米 HyperOS 实测跑通

![platform](https://img.shields.io/badge/platform-macOS%2015%2B-blue) ![language](https://img.shields.io/badge/Swift-单文件%20%7C%20零依赖-orange) ![phone](https://img.shields.io/badge/手机端-零安装-green) ![madeby](https://img.shields.io/badge/made%20by-GLM--5.3-purple)

还在为「Mac 给手机打字/操作」装一堆 App?HIDock 不在手机上装任何东西:**Mac 直接伪装成标准 BLE HID 外设**——现在是一把蓝牙键盘,接下来是触控板。手机配对后,在 Mac 窗口里打字,实时上屏,系统级生效,微信、备忘录、浏览器……所有 App 通用。

```
Mac 键盘/触控板 → HIDock 捕获 → BLE HID 报文 → 📱 手机系统级输入
```

---

## ✨ 功能

### 当前(v1)
- **系统级键盘**:配对一次,全局可用,和真蓝牙键盘完全同等待遇
- **全键位支持**:字母、数字、半角标点、回车、退格、Tab、Esc、方向键、Home/End/PageUp/PageDown、F1–F12、修饰键组合
- **中文输入法友好**:Mac 侧全角标点自动归一化为按键(，→ , 。→ . ／→ /)
- **中文上屏**:手机输入法支持物理键盘拼音即可(讯飞输入法实测可用)
- **自动重连**:App 重启后手机 2 秒内自动回连
- **零依赖**:一个 `main.swift`,一次 `swiftc` 编译,不碰 Xcode、不装 Cocoapods
- **~500 行源码**:协议、键码表、UI 全部可读,是学习 BLE HID / HOGP 协议的活教材

### 🧭 路线图
- **👆 触控板**(下一站):Mac 触控板手势 → BLE HID 鼠标/指针设备,手机上隔空划动、点按
- 媒体键(音量/播放)
- 菜单栏常驻模式 + 全局捕获(免窗口焦点)
- 中文直接上屏(剪贴板隧道方案)

## 🚀 快速开始

```bash
git clone https://github.com/xxx/HIDock.git   # 换成你的地址
cd HIDock
swiftc -O -o HIDock main.swift
./HIDock
```

窗口显示「广播中」后,按下方配对指南连接手机。

## 📱 配对指南(重要,顺序不能错)

部分安卓 ROM(尤其 **MIUI / HyperOS**)从系统设置直接配对会踩 macOS 的坑,被识别成手表/其他设备。**正确顺序**:

1. 手机装 [nRF Connect](https://github.com/NordicSemiconductor/Android-nRF-Connect)(Play 商店可下);
2. 扫描 → 找到 **HIDock** → 点 **CONNECT**(只连接,**不要**先去系统设置配对);
3. 展开 `Human Interface Device (0x1812)` → 读一下 `Report Map (0x2A4B)` → 点 `Report (0x2A4D)` 的订阅按钮(↓↓↓);
4. 断开 nRF Connect → 打开系统蓝牙设置 → 配对 **HIDock** → 显示为键盘/输入设备 ✅
5. 以后不再需要 nRF Connect,自动回连。

> 非 MIUI 的安卓(原生/Pixel 等)大概率可以直接在系统设置配对,不行再走上面的流程。

配对完成后:**点一下 HIDock 窗口的灰色区域**(获取焦点),打字即上屏;`Cmd+Tab` 切走即停。想开机自启,把 HIDock 加进「系统设置 → 通用 → 登录项」。

## ⚠️ 已知限制

- **Shift+数字/符号**在部分手机输入法下可能被解析成单独按键(修饰键独立报文导致),待修;
- 中文上屏依赖**手机输入法**的物理键盘拼音能力(讯飞 ✅,GBoard ❌);
- 焦点在 HIDock 窗口内时,按键只发手机,不进 Mac 其他程序;
- 仅 macOS 15 实测通过;Apple 正在收紧第三方 BLE HID 权限,未来系统版本存在失效风险(见文末)。

## 🛠 工作原理

```
┌─────────────────────────── Mac ───────────────────────────┐
│  CaptureView (NSView keyDown/keyUp/flagsChanged 捕获按键)  │
│      ↓                                                    │
│  HidKeyboard (ASCII → HID Usage 映射,8 字节标准键盘报文,   │
│              6 键无冲,全角标点归一化)                      │
│      ↓                                                    │
│  BlePeripheral (CBPeripheralManager 实现 HOGP 外设)        │
│    └─ HID Service 0x1812:                                 │
│         ├─ HID Information   (0x2A4A)                     │
│         ├─ Report Map        (0x2A4B)  ← 标准 USB HID 描述符│
│         ├─ HID Control Point (0x2A4C)                     │
│         ├─ Protocol Mode     (0x2A4E)                     │
│         └─ Report            (0x2A4D, notify) ← 报文下发   │
└──────────────────────── 空中 BLE ─────────────────────────┘
      ↓
  📱 手机系统输入(Android / iOS / 任何接受 BLE HID 的设备)
```

对手机而言,你的 Mac 就是一个再普通不过的蓝牙外设——因为底层报文和真键盘一字不差。触控板支持 = 在 Report Map 里增加鼠标集合(X/Y 相对位移 + 左右键 + 滚轮),再从 Mac 触控板事件流喂给它,架构不变。

## 🔍 调试战记:macOS 15 手搓 BLE HID 的六个坑

这个项目最大的价值,可能是把这六个坑踩明白并全部给出解法(源码内有对应注释):

1. **SIG 16-bit UUID 全被拒** —— `CBUUID(string: "1812")` 直接报 *"The specified UUID is not allowed"*。
   **解法**:UUID 写成完整 128-bit 形式 `00001812-0000-1000-8000-00805F9B34FB`,空中接口完全等价。
2. **静态值 characteristic 必须只读** —— 「静态 value + notify/write」抛 `NSInternalInconsistencyException`。
   **解法**:需要 notify/write 的特征一律 `value: nil`,读回调里动态返回。
3. **认证门槛别设在 Report Map 上** —— 安卓 GATT 发现阶段吃到 `insufficientAuthentication` 会直接放弃 HID 服务,把设备归类成穿戴设备(这就是"识别成手表"的原因之一)。
   **解法**:发现阶段全明文。
4. **macOS「先 bond 后枚举」bug** —— 安卓系统设置配对 = 先 bond,之后枚举不出 macOS 外设的服务([bluer #162](https://github.com/bluez/bluer/discussions/162))。
   **解法**:先用 nRF Connect 无配对连接暖缓存,再走系统配对(即上方配对指南)。
5. **MIUI 苹果设备误识别** —— macOS 系统 GATT 自带 Apple Continuity/Nearby 服务(删不掉),MIUI 据此把设备认成手表、显示 U-XXXX 匿名设备名。
   **影响**:纯化妆问题,不影响键盘功能。
6. **键码映射细节** —— Mac 退格键事件字符是 `0x7F` 而非功能键 `0xF728`;中文输入法会把标点变成全角需归一化。

## 📖 这个项目是怎么来的

起因是作者问了一句:*"Mac 键盘控制安卓设备,有什么方案?"* 在得知现成工具(scrcpy 等)之后,作者追问:*"Type2Phone 这种,你能手搓出来吗?"*

于是 **GLM-5.3**(智谱 Z.ai 的大模型)当场开工:从写下第一行 Swift 到在小米手机上打字上屏,历时约 **1.5 小时、7 轮迭代**——中间穿过了 Apple 对第三方 BLE HID 的层层封锁、MIUI 的误识别、两个自己埋的 bug,全部靠"改一版 → 真机测一轮 → 日志对一层"的实测驱动调试闭环解决,没有一行代码是抄现成项目的(协议实现参考了 [HOGP 规范](https://www.bluetooth.com/specifications/specs/hid-service-1-0-2/) 与 [ESP32-BLE-Keyboard](https://github.com/T-vK/ESP32-BLE-Keyboard) 的公开行为)。

项目本身也是一份 AI 结对编程的样本:**模型不只是生成代码,还能自己写探针程序做隔离实验、读系统日志定位、指挥真机测试收敛问题。**

## 🗺 未来如果 macOS 封死了这条路

¥15 的 ESP32-C3 刷 BLE-Keyboard 固件当无线电,Mac 侧只需把发送层换成写 USB 串口,其余代码原样复用。

## 📄 License

MIT(可随意使用与修改,保留署名即可)
