# Companion iOS — 状态

更新：2026-11-15（北京 01:00 前后，V2 构建中）

## V2（进行中）

- 麦克风闪退已修：AudioManager 重写为稳健录音路径（先请求权限再碰引擎；tap 用输入节点自身输出格式 + AVAudioConverter 转 16kHz PCM16；装/卸 tap 前先停引擎；移除音频路径全部 force-unwrap；mp3 检测只认 ID3 标签，避免把原始 PCM 误判成 mp3 而吞掉 TTS 音频；`.allowBluetooth` 改 `.allowBluetoothHFP`）。
- 主界面已重构为虚拟形象中心：大圆头像 小月（`XiaoYue` asset，`xiaoyue-headphones.png` 裁去底部 baked-in 文字后 950x950）+ 名字 + 状态行；状态驱动动画（待机呼吸起伏、聆听脉冲光环、说话弹跳+波形条、等待三点动画）；对话记录为头像下方紧凑滚动区；麦克风按钮突出；ChatViewModel 新增 `isSpeaking` 标志。
- 音色选择器已去掉（范围变更 2026-11-15 00:54）：后端切回 GLM-4-Voice 端到端（音色固定），start 消息只发 `{"type":"start","format":"pcm16k"}`，不发 voice 字段。
- 后端（并行任务）：切回 GLM-4-Voice + WAV 解析重采样修复（V1 声音不对的可能根因：WAV 字节当原始 PCM 流出且未重采样到 16kHz）。

## V1（已交付）

- Xcode 工程在 `~/workspace/companion-ios/`（SwiftUI，iOS 16+，显示名“AI 陪伴”，Bundle ID `com.example.companion` 占位）。
- GitHub 仓库已创建：https://github.com/DJ1123000/companion-ios（public）。
- V1 IPA 已交付 2026-11-15 00:20（run 43614365046）：Companion.ipa 130,901 字节，sha256 `657a3df05c51f50ed624b9fb7356a8e6c2987e62e27d05f64d1364545d39b15f`，链接 2026-11-17 00:20 CST 过期；本地副本 `~/workspace/companion-ios/Companion.ipa`。
- GitHub token 已修复（2026-11-15 00:10 重新生成带 workflow 权限；00:13 已存入 Secure Vault），Actions 构建可正常触发。

## 已实现的 WebSocket 协议

- 服务端：`ws://192.144.154.194:8080`
- 发：`{"type":"start","format":"pcm16k"}` → 二进制 PCM16 16kHz 单声道音频块 → `{"type":"stop"}`；文字兜底 `{"type":"text","text":"..."}`。
- 收：`{"type":"reply_text"}`、二进制 TTS 音频（PCM 流播或 mp3 整段播）、`{"type":"done"}`、`{"type":"error"}`。GLM-4-Voice 端到端不发 transcript。
- 断线自动重连一次；UI 显示连接状态（已连接/连接中/连接失败）。
- App 内无 STT/LLM/TTS、无 API Key、无登录。
