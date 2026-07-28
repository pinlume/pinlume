# Pinlume Beta：安装与权限说明

此 DMG 是面向体验的 Universal 2（Apple Silicon + Intel）Beta 构建。维护者目前没有 Apple Developer Program，因此它使用本地 Beta 签名，**未经过 Apple 公证**，也不提供自动更新。首次启动时 macOS 的安全提示属于预期行为。

请只从 [Pinlume 的 GitHub Releases](https://github.com/pinlume/pinlume/releases) 下载 Beta 包；新版本需要手动下载并替换旧 App。

## 安装与首次打开

1. 打开 DMG，将 `Pinlume.app` 拖到“应用程序（Applications）”文件夹。
2. 在“应用程序”中双击启动。如果 macOS 提示无法验证开发者，先关闭提示。
3. 打开“系统设置 → 隐私与安全性”，滚动到页面底部，在 Pinlume 的提示旁点击“仍要打开（Open Anyway）”，然后在确认框中点击“打开”。

也可以在“应用程序”中按住 Control 点按 `Pinlume.app`，选择“打开”，再在确认框中选择“打开”。只有你确认下载来源是上述 GitHub 仓库时才这样操作。

## 所需权限

- **屏幕录制 / 屏幕与系统音频录制**：首次截图或录制时按系统提示授权；若未出现或功能不可用，可前往“系统设置 → 隐私与安全性 → 屏幕录制（或屏幕与系统音频录制）”开启 Pinlume，随后完全退出并重新打开 App。
- **辅助功能**：仅在 Pinlume 设置中开启“翻译选中的文字”后需要。在“系统设置 → 隐私与安全性 → 辅助功能”开启 Pinlume。
- **麦克风、摄像头**：只有你主动使用录制声音或摄像头叠加时才会请求。

你随时可以在上述系统设置中关闭这些权限；对应功能会停止工作，其余功能不受影响。

---

# Pinlume Beta: Installation and Permissions

This DMG is a Universal 2 (Apple Silicon + Intel) beta build. The maintainer is not enrolled in the Apple Developer Program, so it uses a local beta signature, is **not notarized by Apple**, and does not include automatic updates. A macOS security prompt on first launch is expected.

Download beta builds only from [Pinlume GitHub Releases](https://github.com/pinlume/pinlume/releases). Download new versions manually and replace the old app.

## Install and open for the first time

1. Open the DMG and drag `Pinlume.app` into Applications.
2. Launch it from Applications. If macOS says the developer cannot be verified, dismiss that message first.
3. Open **System Settings → Privacy & Security**, scroll to the bottom, click **Open Anyway** beside Pinlume, then confirm with **Open**.

Alternatively, Control-click `Pinlume.app` in Applications, choose **Open**, then confirm. Only do this after confirming that the download came from the GitHub repository above.

## Permissions

- **Screen Recording / Screen & System Audio Recording**: approve the system request when capturing or recording. If necessary, enable Pinlume in **System Settings → Privacy & Security → Screen Recording** (or **Screen & System Audio Recording**), then quit and relaunch it.
- **Accessibility**: needed only after enabling “Translate selected text” in Pinlume Settings. Enable Pinlume in **System Settings → Privacy & Security → Accessibility**.
- **Microphone and Camera**: requested only when you choose recording with microphone audio or a camera overlay.

You can revoke any permission in System Settings at any time. Only the related feature stops working.
