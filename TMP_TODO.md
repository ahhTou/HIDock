# TMP TODO:应用被公司 MDM 击杀,待 Apple 签名证书解锁

> ⚠️ 此文件是临时问题记录,**问题解决后删除**(连同本条 commit 一起在历史里留痕即可)。

## 问题

2026-09-08 起,本机所有**本地新编译的无签名二进制**在启动瞬间被 SIGKILL(exit 137),HIDock 因此无法运行。与代码无关:连 `int main(){return 7;}` 的 hello world 也被杀;9月2日还能正常运行的旧二进制现在同样被杀。

## 根因

Mac 注册了公司 MDM(阿里 alilang,`mdm-alilang.alibaba-inc.com`),近期推送了应用程序管控策略,对无签名/仅 ad-hoc 签名的可执行文件执行击杀(文件带 `com.apple.provenance` 溯源属性,击杀不留 Gatekeeper 日志,属 ESF 级处置)。

## 解决方案

用 **Apple Development 证书**给 `.app` 正式签名(EDM 类策略通常放行持有效 Apple 签名的二进制):

1. 装 Xcode(Mac App Store 或 developer.apple.com/download 的 .xip)
2. `sudo xcode-select -s /Applications/Xcode.app && sudo xcodebuild -license accept`
3. Xcode → Settings → Accounts → 登录个人 Apple ID(免费即可)
4. Manage Certificates → **+ Apple Development** → 证书进钥匙串
5. 回项目目录执行 `./build.sh`(脚本已内置证书自动降级逻辑,无需改动)
6. `open build/HIDock.app` 验证是否放行

## 验证标准(全部满足即删本文件)

- [ ] `security find-identity -v -p codesigning` 出现 "Apple Development: …"
- [ ] `./build.sh` 签名模式显示 apple-development(非 adhoc)
- [ ] `open build/HIDock.app` 后进程存活、手机可回连

## 若签名后仍被杀

说明策略要求 Developer ID 级别(需 $99/年开发者计划)或按证书 TeamID 白名单——只剩找公司 IT/安全团队加白一条路,不做绕过。
