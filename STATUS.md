# Companion iOS — 状态

更新：2026-11-15（北京 08:15 前后，V3 已交付）

## V3（已交付）

- 用户反馈（2026-11-15 08:10）："音色传输还是有问题，保持原样本传输吧" + "界面语音输入按钮做大一些，UI 设计一下，不要那种麦克风，最好是动态样式立体化，可以设置两种模式，一种实时对话，一直长按输入语音"。
- WAV 播放（AudioManager）：检测 RIFF 头，WAV 分块缓存，`finishPlayback()`（done 消息时）用 AVAudioPlayer 整段播放原样 WAV（22050Hz 正确采样率，无重采样）；16kHz PCM 流播保留为兜底；mp3（ID3）缓存播放保留。`finishPlayback()` 返回是否起了缓存播放；`onPlaybackFinished`（AVAudioPlayerDelegate）回调让说话状态在音频真正播完时才清除。
- 语音输入 UI 重构（ContentView + ChatViewModel）：大号立体语音球（128pt，暖色径向渐变球体 + 光泽高光 + 外辉光 + 投影，无麦克风图标）；状态动画（待机呼吸、聆听脉冲光环+放大、说话放大+波形条、等待三点）；两种模式切换（分段选择器，存 UserDefaults）：**实时对话**（点一下开始、再点一下结束）与**长按说话**（按住说、松开发送，默认）。小月头像、对话记录、文字输入保留不变；不发 voice 字段（GLM-4-Voice 音色固定）。
- 后端（并行任务）：WAV 直通——server.js 不再解析/重采样，原样发送 GLM-4-Voice WAV 字节（RIFF 头，22050Hz）；已验证 text turn 345,390 字节、voice turn 232,750 字节，源 == 发送，health 显示 "audio":"wav-passthrough"。
- **V3 IPA 已交付 2026-11-15 08:15**：run 43657225876 SUCCESS（commit `c48592d`，Git Database API 推送，build.sh 保持 mode 100755，未用 Contents API）。Companion.ipa 1,944,959 字节，sha256 `011e01018b4d31ababc9a4008d444a274daa31140ff288cdb8036dfdae5cb4e3`，本地副本 `~/workspace/companion-ios/Companion.ipa`。
- 待手机实测：覆盖 V2 装；两种模式都试（实时对话点一下开始/再点结束、长按说话按住/松开）；听音色是否与智谱控制台一致（原样 WAV）；确认大球动画、头像动画正常。

## V2（已交付）

- 麦克风闪退已修：AudioManager 重写为稳健录音路径（先请求权限再碰引擎；tap 用输入节点自身输出格式 + AVAudioConverter 转 16kHz PCM16；装/卸 tap 前先停引擎；移除音频路径全部 force-unwrap；mp3 检测只认 ID3 标签，避免把原始 PCM 误判成 mp3 而吞掉 TTS 音频；`.allowBluetooth` 改 `.allowBluetoothHFP`）。
- 主界面已重构为虚拟形象中心：大圆头像 小月（`XiaoYue` asset，`xiaoyue-headphones.png` 裁去底部 baked-in 文字后 950x950）+ 名字 + 状态行；状态驱动动画（待机呼吸起伏、聆听脉冲光环、说话弹跳+波形条、等待三点动画）；对话记录为头像下方紧凑滚动区；麦克风按钮突出；ChatViewModel 新增 `isSpeaking` 标志。
- 音色选择器已去掉（范围变更 2026-11-15 00:54）：后端切回 GLM-4-Voice 端到端（音色固定），start 消息只发 `{"type":"start","format":"pcm16k"}`，不发 voice 字段。
- 后端（并行任务）：切回 GLM-4-Voice + WAV 解析重采样修复（V1 声音不对的可能根因：WAV 字节当原始 PCM 流出且未重采样到 16kHz）。
- **V2 IPA 已交付 2026-11-15 01:01**：run 43618695381 SUCCESS。Companion.ipa 1,926,887 字节，sha256 `18d930d9b2588a10b319325436539c374a2302834552cf99bff4abd7524e8bdf`，本地副本 `~/workspace/companion-ios/Companion.ipa`。构建插曲：首次 run 43618554754 失败（`./build.sh: Permission denied`——Contents API 上传丢了可执行位）；已用 Git Database API 把 build.sh 恢复为 mode 100755（commit `d92f5c6`），重跑即绿。注意：以后凡经 Contents API 推送 build.sh 都要复查可执行位。
- 待手机实测：装 IPA，按住说话，验证与小月语音往返、音色是否与智谱控制台一致、闪退是否修复、头像动画是否正常。

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
