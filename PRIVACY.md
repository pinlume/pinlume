# Privacy Policy

**Last updated:** July 28, 2026

## Overview

Pinlume is a native macOS tool for screenshots, screen recording, annotation, OCR, translation, and pinning. Pinlume does not operate telemetry, analytics, advertising, or user-content storage services. Screenshots, recordings, preferences, history, pins, and diagnostic logs remain on your Mac unless you explicitly choose to upload, share, translate through a network provider, or install an update.

## What Pinlume does not do

- **No telemetry or analytics:** Pinlume does not track how you use the app or send usage data to the maintainer.
- **No maintainer-operated content storage:** Pinlume does not upload your screenshots, recordings, OCR results, clipboard contents, or translation text to a server operated by the maintainer.
- **No sale or sharing of personal data:** The maintainer does not collect, sell, or share your personal information.

## Data stored on your Mac

Pinlume stores the following data locally in its app data container or in locations you choose:

- **Screenshots and recordings:** Saved only when you choose to save them, to your selected folder.
- **Screenshot history and pins:** Recent captures, editable capture data, and pinned-item state. You can configure history in Settings, including disabling it.
- **Preferences:** App settings stored locally through macOS preferences storage.
- **Google Drive sign-in data:** If you connect Google Drive, the OAuth token required to keep that connection is stored locally. Signing out from Pinlume removes it.
- **S3-compatible storage settings:** The endpoint, bucket, and credentials you enter are stored locally and are used only to upload to the destination you configure.
- **Optional diagnostic logs:** Disabled by default. When enabled, diagnostic logs contain only operational metadata such as dimensions, counts, timings, states, version metadata, and error codes—not screenshot pixels, OCR or translation text, clipboard contents, credentials, or other user text.

## Optional third-party services

All third-party network features are opt-in. Their handling of data is governed by their own policies.

### Google Drive

- **Purpose:** Upload screenshots and recordings to your own Google Drive account.
- **Scope:** `drive.file`—Pinlume can access files it creates in your Drive, not arbitrary files in your account.
- **Data sent:** The file you choose to upload and the metadata needed to create it, such as its filename.
- **Authentication:** You sign in through Google's browser-based OAuth flow. You can disconnect in Pinlume or revoke access through [Google Account Permissions](https://myaccount.google.com/permissions).

### imgbb

- **Purpose:** Upload screenshots for a shareable image link.
- **Data sent:** The image file you choose to upload.
- **Policy:** [imgbb Privacy Policy](https://imgbb.com/privacy).

### S3-compatible storage

- **Purpose:** Upload a screenshot or recording to the endpoint you configure, including services such as AWS S3, Cloudflare R2, or MinIO.
- **Data sent:** The file you choose to upload and the request metadata required by that endpoint.
- **Control:** Your destination and credentials are configured by you; the maintainer does not receive them.

### Translation

- **Apple Translation:** Uses Apple's translation framework when selected and available.
- **Google Translate:** Text is sent to Google only when you select Google Translate and enable the explicit **Allow sending text to Google Translate** privacy switch.

## Updates

Current beta builds do not check for or download updates automatically. New versions, if any, must be downloaded manually from the GitHub Releases page. If automatic updates are introduced in a future release, this policy will be updated before that feature is enabled.

## Permissions

Pinlume requests only the permissions needed for features you choose to use:

- **Screen Recording:** Capture the screen or record it.
- **Microphone and Camera:** Include microphone audio or a webcam overlay in a recording.
- **Accessibility:** Auto-scroll for scrolling capture and translate text selected in other apps.
- **Input Monitoring:** Display keystrokes during recording when that feature is enabled.

macOS controls these permissions. You can review or revoke them at any time in System Settings.

## Open source

Pinlume is maintained by [duhuajie](https://github.com/duhuajie) and is released under [GPLv3](LICENSE). The public source repository is [github.com/pinlume/pinlume](https://github.com/pinlume/pinlume). See [NOTICE.md](NOTICE.md) for source provenance and attribution.

## Contact

For questions about this policy, open an issue at [github.com/pinlume/pinlume](https://github.com/pinlume/pinlume).

---

## 中文摘要

Pinlume 不提供遥测、分析、广告或由维护者运营的用户内容存储服务。截图、录屏、OCR 结果、剪贴板内容、翻译文本、历史记录和设置默认留在你的 Mac 上；只有你主动选择上传或使用联网翻译时，相关数据才会与所选第三方服务通信。当前 Beta 版不提供自动更新。

Google Drive、imgbb、S3 兼容存储和 Google 翻译均为可选功能。诊断日志默认关闭，开启后只记录尺寸、耗时、状态和错误码等运行元数据。
