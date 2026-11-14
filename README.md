# AI 陪伴 — iOS 语音陪伴实验版

纯前端（thin client）：只负责录音和放音，所有 AI 处理都在云端后端完成。
App 里没有任何语音识别、大模型、语音合成，不需要登录和账号。

## 架构

- **App**：SwiftUI 聊天界面 + 按住说话按钮 + 文字输入兜底。
- **后端**：WebSocket 中转服务（STT → 大模型 → 克隆音色 TTS），另见后端实现。

## WebSocket 协议（后端 ws://192.144.154.194:8080）

客户端 → 服务端：

| 消息 | 说明 |
| --- | --- |
| `{"type":"start","format":"pcm16k"}` | 开始说话前发送 |
| 二进制 | 16kHz 16-bit 单声道 PCM 音频块（小端序） |
| `{"type":"stop"}` | 松开按钮、停止说话时发送 |
| `{"type":"text","text":"..."}` | 文字输入兜底，服务端当作识别结果处理 |

服务端 → 客户端：

| 消息 | 说明 |
| --- | --- |
| `{"type":"transcript","text":"..."}` | 用户说的话 |
| `{"type":"reply_text","text":"..."}` | 助手回复的文字 |
| 二进制 | TTS 音频（PCM16 16kHz 单声道，或 mp3） |
| `{"type":"done"}` | 本轮结束 |
| `{"type":"error","message":"..."}` | 出错，界面显示 message |

## 构建

```sh
./build.sh        # 生成 Companion.ipa（未签名，用 AltStore/SideStore 重签后安装）
```

要求：Xcode 15+，iOS 16.0+。

GitHub Actions（`.github/workflows/build.yml`）在 macOS runner 上自动构建并上传 IPA artifact。

## 说明

- 显示名：AI 陪伴；Bundle ID：`com.example.companion`（占位，侧载时重签）。
- 实验阶段用 `ws://` 明文连接，后端地址写死在 `Companion/WebSocketClient.swift` 的 `serverURL`。
- 麦克风权限首次使用时申请；`Info.plist` 已放行任意加载（ATS）以便直连裸 IP。
