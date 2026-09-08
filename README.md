# HIDock

> 一个小玩具:把 Mac 变成手机的蓝牙键盘 + 触控板。单文件 Swift,手机端零安装。

这是某天下午和 **GLM-5.3** 结对编程搓出来的实验项目:用 CoreBluetooth 实现了一个最小 BLE HID 键盘 + 鼠标(HOGP),手机配对后,Mac 窗口就是手机的输入设备。

**只在一台 macOS 15 的 Mac + 一台小米手机(HyperOS)上验证过。** 能跑的玩具,不是成熟工具,自用顺手就分享出来。能不能在你设备上跑,不好说,先看下面的已知问题。

## 功能

- **蓝牙键盘**:窗口获得焦点后打字即上屏(字母数字、回车、退格、方向键、F1–F12、修饰键)
- **触控板**:点击面板捕获指针——系统光标冻结隐藏,位移全部转发手机,滑多远都出不了面板
  - 滑动 = 手机指针;单击 = 左键;右键 = 返回键;双指滚动 = 手机滚轮
  - 面板有状态:空闲时显示引导文案,捕获后变蓝色取景框,一眼可辨
- **⌘Q 两段式**:捕获中按 ⌘Q 只释放捕获(光标回到工具栏);未捕获时再按退出应用。该组合键不会透传给手机
- **防锁死**:Cmd+Tab 切走、系统手势(Mission Control)抢焦点时自动释放捕获,5 秒内切回自动恢复
- **状态一目了然**:顶部状态点 + 文字(绿=已连接 / 琥珀=广播中 / 红=蓝牙异常),独立成行
- **小件**:手机横竖屏状态标记(纯记录,不影响映射)、触控板开关、右下角 GitHub 入口

## 使用

```bash
git clone https://github.com/ahhTou/HIDock.git
cd HIDock
./build.sh                 # 编译 + 打包成 build/HIDock.app(自动签名)
open build/HIDock.app
```

打包成 .app 后蓝牙权限只弹一次、归属稳定(`NSBluetoothAlwaysUsageDescription` 见 `Info.plist`);想跑裸二进制仍然可以 `swiftc -O -o HIDock main.swift`。

点一下窗口获得焦点即可打字;点击触控板面板开始控制。想开机自启可以把它加进登录项。

## 配对(小米 / MIUI 用户看这里)

部分安卓 ROM 直接在系统设置里配对,会被识别成手表/其他设备(原因见踩坑 4、5),需要先用 BLE 调试工具"暖"一下缓存:

1. 装 [nRF Connect](https://github.com/NordicSemiconductor/Android-nRF-Connect),扫描 → CONNECT "HIDock"(只连接,**不要**先去系统设置配对);
2. 读一下 `Report Map (0x2A4B)`,订阅 `Report (0x2A4D)`;
3. 断开 nRF Connect,再去系统蓝牙设置配对,即可识别为键盘;
4. 之后不再需要 nRF Connect,会自动回连。

其他安卓 / iOS 未测试,欢迎反馈。

## 已知问题(诚实清单)

- 中文上屏依赖手机输入法的物理键盘拼音能力(讯飞可以,GBoard 不行);
- 打字期间焦点必须在 HIDock 窗口里;触控板无捕获状态时,悬停移动也会带动手机指针;
- 多指手势里只有双指滚动能透传(协议限制:HID 鼠标无多点触控,三指手势会被当成大位移,已做限幅防误触系统手势);
- 打包/签名:`build.sh` 产出 ad-hoc 签名的 .app,本机即开即用;**未公证**——直接发给别人,对方首次打开需在「系统设置 → 随私与安全性」点「仍要打开」放行一次(有 Apple Developer 账号可 `./build.sh --notarize` 消除这一步);无自动更新;
- 样本量 = 一台手机,你的设备上能不能跑全凭运气;
- macOS 若继续收紧第三方 BLE HID 权限,随时可能失效。

## 计划(挖坑不填)

- 菜单栏常驻 + 全局捕获。

## 踩坑记录(macOS 15 上手搓 BLE HID)

给想自己玩的人留个路标,细节在源码注释里:

1. SIG 16-bit UUID 会被拒("UUID is not allowed"),写成完整 128-bit 形式 `00001812-0000-1000-8000-00805F9B34FB` 即可,空中等价;
2. 静态值 characteristic 必须只读,需要 notify/write 的一律 `value: nil` 动态返回,否则直接抛异常;
3. 别在 Report Map 上设认证门槛,安卓发现阶段吃到 insufficientAuthentication 会放弃 HID 服务、把设备归类成穿戴设备;
4. macOS 外设有「先 bond 后枚举不出服务」的问题([bluer #162](https://github.com/bluez/bluer/discussions/162)),所以要先用 nRF Connect 暖缓存再走系统配对;
5. macOS 系统 GATT 自带 Apple Continuity/Nearby 服务(删不掉),MIUI 会据此把设备误识别成手表、显示 U-XXXX 匿名设备名,不影响功能;
6. Mac 退格键的事件字符是 `0x7F` 不是 `0xF728`;中文输入法会把标点变成全角,需要归一化;
7. `UInt8(Int8(...))` 是陷阱式初始化器:负值直接 EXC_BREAKPOINT,滚轮字节必须用 `UInt8(bitPattern:)` 补码重解释(血泪教训,崩溃过三次才定位到);
8. 无边框/透明标题栏窗口:AppKit 会在窗口成为 key 后异步重摆红绿灯,别去抢位置,让自己的按钮贴红绿灯的实际中线才稳;
9. 鼠标"按钮松开"的报文是全零(按钮0+位移0+滚轮0):待发队列用"内容非零才发"判空会把松开吞掉,手机永远收不到抬起 → 单击变长按。判空要用独立的 dirty 标志,不能看内容;
10. 修饰键字节别搞两个真相来源:flagsChanged 写一遍、keyDown/keyUp 又按"字符要不要 Shift"翻转一次,时序一错就打架(Shift 先松、字母后松时手机 key repeat 漏小写)。报文现算:修饰键 = 物理修饰键 ∪ 按住中的需 Shift 字符键,keyUp 不碰修饰键。同理,Ctrl+字母的 `characters` 是 0x01–0x1A 控制符,查功能键表前要排除,否则 Ctrl+C 撞 0x03 变 Ctrl+Enter。

## 这个项目是怎么来的

起因是作者随口问了一句:*"Mac 键盘控制安卓设备,有什么方案?"* 在听到 scrcpy 之类的现成答案之后,又追问了一句:*"Type2Phone 这种,你能手搓出来吗?"*

于是 **GLM-5.3**(智谱 Z.ai 的模型)当场开工:从写下第一行 Swift 到在小米手机上打字上屏,断断续续几个对话、约一个半小时、前后 7 轮迭代。中间穿过了 Apple 对第三方 BLE HID 的层层限制、MIUI 的误识别、两个自己埋的 bug,靠"改一版 → 真机测一轮 → 日志对一层"一点点磨出来的。没有抄现成项目(协议参考了 HOGP 规范与 [ESP32-BLE-Keyboard](https://github.com/T-vK/ESP32-BLE-Keyboard) 的公开行为),代码约 500 行。

当个玩具看就好,玩得开心。

## License

MIT
