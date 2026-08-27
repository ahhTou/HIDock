# HIDock

> 一个小玩具:把 Mac 变成手机的蓝牙键盘。单文件 Swift,手机端零安装。

这是某天下午和 **GLM-5.3** 结对编程搓出来的实验项目:用 CoreBluetooth 实现了一个最小 BLE HID 键盘(HOGP),手机配对后,在 Mac 窗口里打字就能上屏。

**只在一台 macOS 15 的 Mac + 一台小米手机(HyperOS)上验证过。** 能跑的玩具,不是成熟工具,自用顺手就分享出来。能不能在你设备上跑,不好说,先看下面的已知问题。

## 使用

```bash
git clone https://github.com/ahhTou/HIDock.git
cd HIDock
swiftc -O -o HIDock main.swift
./HIDock
```

点一下窗口灰色区域获得焦点,打字即发到手机;`Cmd+Tab` 切走即停。想开机自启可以把它加进登录项。

## 配对(小米 / MIUI 用户看这里)

部分安卓 ROM 直接在系统设置里配对,会被识别成手表/其他设备(原因见踩坑 4、5),需要先用 BLE 调试工具"暖"一下缓存:

1. 装 [nRF Connect](https://github.com/NordicSemiconductor/Android-nRF-Connect),扫描 → CONNECT "HIDock"(只连接,**不要**先去系统设置配对);
2. 读一下 `Report Map (0x2A4B)`,订阅 `Report (0x2A4D)`;
3. 断开 nRF Connect,再去系统蓝牙设置配对,即可识别为键盘;
4. 之后不再需要 nRF Connect,会自动回连。

其他安卓 / iOS 未测试,欢迎反馈。

## 已知问题(诚实清单)

- Shift+数字/符号在部分输入法下表现异常(修饰键独立报文导致,还没修);
- 中文上屏依赖手机输入法的物理键盘拼音能力(讯飞可以,GBoard 不行);
- 焦点必须在 HIDock 窗口里,打字期间不进 Mac 其他程序;
- 没有打包、签名、自动更新,就是个裸二进制;
- 样本量 = 一台手机,你的设备上能不能跑全凭运气;
- macOS 若继续收紧第三方 BLE HID 权限,随时可能失效。

## 计划(挖坑不填)

- 触控板(BLE HID 鼠标集合,Report Map 加个鼠标 collection 就行,架构不变);
- 修 Shift 组合键;
- 菜单栏常驻 + 全局捕获。

## 踩坑记录(macOS 15 上手搓 BLE HID)

给想自己玩的人留个路标,细节在源码注释里:

1. SIG 16-bit UUID 会被拒("UUID is not allowed"),写成完整 128-bit 形式 `00001812-0000-1000-8000-00805F9B34FB` 即可,空中等价;
2. 静态值 characteristic 必须只读,需要 notify/write 的一律 `value: nil` 动态返回,否则直接抛异常;
3. 别在 Report Map 上设认证门槛,安卓发现阶段吃到 insufficientAuthentication 会放弃 HID 服务、把设备归类成穿戴设备;
4. macOS 外设有「先 bond 后枚举不出服务」的问题([bluer #162](https://github.com/bluez/bluer/discussions/162)),所以要先用 nRF Connect 暖缓存再走系统配对;
5. macOS 系统 GATT 自带 Apple Continuity/Nearby 服务(删不掉),MIUI 会据此把设备误识别成手表、显示 U-XXXX 匿名设备名,不影响功能;
6. Mac 退格键的事件字符是 `0x7F` 不是 `0xF728`;中文输入法会把标点变成全角,需要归一化。

## 关于

全程结对调试约一个半小时,没有抄现成项目(协议参考了 HOGP 规范与 ESP32-BLE-Keyboard 的公开行为)。代码约 500 行,当玩具看就好。

## License

MIT
