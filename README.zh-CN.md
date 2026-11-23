<div align="center">
  <img src="docs/assets/app-icon.png" width="116" height="116" alt="DisplayVolume Icon" />
  <h1>桌面音量 · DisplayVolume</h1>
  <p>
    <strong>为 DisplayPort / HDMI 外接显示器音箱打造的原生 macOS 音量与键盘控制工具</strong><br />
    无需虚拟声卡驱动 · 告别开机突发爆音 · 原生 Liquid Glass 面板与屏幕浮窗
  </p>

  <p>
    <img src="https://img.shields.io/badge/version-v2.0.0-0ea5e9?style=flat-square" alt="v2.0.0" />
    <img src="https://img.shields.io/badge/platform-macOS%2014.4%2B-334155?style=flat-square&logo=apple&logoColor=white" alt="macOS 14.4+" />
    <img src="https://img.shields.io/badge/engine-CoreAudio%20Tap%20%2B%20C17%20DSP-06b6d4?style=flat-square" alt="CoreAudio Tap + C17 DSP" />
    <a href="./LICENSE"><img src="https://img.shields.io/badge/license-MIT-64748b?style=flat-square" alt="MIT License" /></a>
  </p>

  <p>
    <a href="./README.md">English</a> · <strong>简体中文</strong>
  </p>
</div>

---

## 为什么做这个工具？

当 Mac 通过 **DisplayPort、HDMI 或 Thunderbolt** 连接外接显示器（例如 Redmi 27 NU 等接入音箱的显示器）时，macOS 会把系统声音输出滑块锁死在 `100%`。每次在 **Magic Keyboard（妙控键盘）** 或 MacBook 上按 `F10` / `F11` / `F12` 调节音量，屏幕只会弹出一个禁止调节的 `⊘` 图标，很多显示器也不支持通过 DDC/CI 调节音量。

**桌面音量 (DisplayVolume)** 从第一性原理出发，不安装任何虚拟声卡或内核扩展，直接基于 macOS 原生 `CATapDescription` 音频流拦截与 C17 实时 DSP 解决这一问题：

- **直接支持妙控键盘 / MacBook 音量键 (`F10` / `F11` / `F12`)**：通过独立高优先级线程上的 `CGEventTap` 接管音量键与静音键，吞掉系统的 `⊘` 禁用提示，并在屏幕右上角显示纯净的原生 Liquid Glass 浮窗（OSD）。
- **多设备自动无感让位**：一旦切换到 AirPods、蓝牙耳机或 MacBook Pro 扬声器，后台立即释放音频 Tap 并原生放行键盘音量键，零延迟零干扰。
- **独立后台守护，关闭界面依然持久生效**：退出菜单栏界面不会让声音突然恢复 100% 爆音；重连显示器、熄屏唤醒或重启登录后自动无缝恢复。
- **首帧零爆音保护**：音频权限验证通过后，软件衰减会在第一帧声音送出前同步启用，消除重连/唤醒瞬间的 200ms 高音量冲击。
- **直接可见的安全上限与输出切换**：音量滑块（支持轨道任意点击直接跳转 + 零抖动拖动）、安全上限滑块与输出设备列表全部平铺直出，无需二次展开。
- **10ms 无爆音 C17 实时增益**：支持 1–8 声道交错与平面 `Float32` PCM 音频流，采用二次方听感曲线与逐采样线性平滑渐变。

---

## 界面与交互

<p align="center">
  <img src="docs/assets/popover-preview.png" width="340" alt="桌面音量 Liquid Glass 菜单栏弹层" />
</p>

- **原生 Liquid Glass 面板**：菜单栏采用独立显示器音浪图标（与系统自带喇叭清晰区分），点击即可调节音量、切换输出设备或设置安全上限。
- **滚轮悬停调音**：鼠标悬停在菜单栏图标上直接上下滚动，无需点开面板即可按 `2%` 步进微调音量。
- **快捷键一览**：
  - `F10` / `F11` / `F12`（妙控键盘 / Mac 键盘）：静音 / 降低 / 提高音量（`±5%`）
  - `⇧ + ⌥ + 音量加减`：`±1%` 精细微调
  - `⌥ + 音量键`：原生放行，直接打开系统声音设置
  - `⌃ + ⌥ + ↑ / ↓ / M`：备选全局快捷键

---

## 从源码构建与安装

需要 **macOS 14.4+** 与 Xcode 命令行工具（`swift` 与 `clang`）：

```bash
git clone https://github.com/HazelKahlil/DisplayVolume.git
cd DisplayVolume
./Scripts/build.sh --install
open ~/Applications/DisplayVolume.app
```

打包可拖拽安装的 `.dmg`：

```bash
./Scripts/package_dmg.sh
```

彻底停用后台服务并卸载：

```bash
./Scripts/uninstall.sh
```

---

## 权限说明

1. **录屏与系统录音（`桌面音量后台`）**：macOS `CATapDescription` 要求此权限以在声音送往显示器前进行本地实时缩放；音频仅在内存内实时处理，绝不录音或上传。
2. **辅助功能（`桌面音量`）**：用于接管 `F10–F12` 键盘音量键并隐藏系统的 `⊘` 禁止图标；授权一次后无需重启立即生效。

> 构建脚本默认优先使用本机 `Apple Development` 证书签名，避免每次更新后重新弹窗授权；开源贡献者无本地证书时会自动回退到 ad-hoc 签名（也可通过 `DISPLAYVOLUME_ADHOC_SIGN=1` 强制使用）。

---

## 开源协议

[MIT License](./LICENSE) © 2026 Hazel Kahlil
