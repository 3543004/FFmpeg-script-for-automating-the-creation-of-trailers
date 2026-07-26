# HLS 自动化加密切片脚本 (HLS v6 Standard)

一个基于 **PowerShell & Batch 混合封装** 的 Windows 自动化 HLS (HTTP Live Streaming) 音视频转码与加密切片工具。

脚本遵循 **Apple HLS Version 6** 规范，自动识别 MP4 / MKV 格式视频文件、具备动态 GOP 锁定、绝对 6 秒等长切片、AES-128 随机密钥加密、多码率自适应、多音轨/多字幕解耦与语言智能识别等高级特性。

---

## 🌟 核心特性与亮点

### 1. 动态 GOP 锁定与绝对 6 秒切片
- **彻底解决切片时长偏差**：通过 `ffprobe` 动态读取原视频的真实 FPS，自动计算 `Round(FPS * 6)` 对应的绝对帧数。
- **强制关键帧插入**：结合 `-force_key_frames`、禁用场景切换检测（`-sc_threshold 0` / `-no-scenecut 1`），防止 FFmpeg 因画质变化插入额外 I 帧，彻底消除 HLS 切片时长不均匀（如 10 秒变 6 秒）的经典 Bug。

### 2. 工业级 AES-128 动态加密
- **密码学安全**：采用 `.NET Security.Cryptography` 强随机数生成器，每次运行动态生成 16 字节（128-bit）密钥（`enc.key`）与 32 位十六进制随机 IV（初始向量）。
- **自动化 Key Info 注入**：自动构建 FFmpeg 加密约束文件并在压片结束后无痕清理中间凭证。

### 3. 多码率与智能防拉伸渲染
- **4 种转码预设模式**：
  - **模式 1**：单码率 (1080P)
  - **模式 2**：三码率组合 (480P + 720P + 1080P)
  - **模式 3**：四码率组合 (360P + 480P + 720P + 1080P)
  - **模式 4**：全全高清/4K 组合 (360P 至 4K 共 6 级)
- **智能 Black-Pad 填充**：采用 `scale` + `pad` 复杂滤镜，保持原视频宽高比（支持 4:3、16:9、21:9 等），自动补齐黑边，杜绝画面变形。

### 4. 硬件加速自适应
- 脚本启动时自动探测本机 FFmpeg 环境。
- **优先 GPU 加速**：成功识别 NVIDIA 显卡时采用 `h264_nvenc` (预设 `p4`)；
- **CPU 降级兜底**：无 GPU 时自动降级为 `libx264` (预设 `fast`)。

### 5. 多音轨 / 多字幕解耦与智能语言匹配
- **内/外置轨道全探查**：智能合并 `.mp4`/`.mkv` 内置音字幕轨以及同目录下的外置音频（`.mp3`, `.aac`, `.m4a`）和字幕（`.srt`, `.vtt`）。
- **拓宽匹配算法 (`Parse-TrackLanguage`)**：通过正则边界拓宽识别 `zh`/`chi`/`cht`/`普通话`/`国语` 等标签，精准识别中文与英文。
- **中文优先原则**：自动设置中文轨道为 HLS 的默认播放轨 (`DEFAULT=YES`)。
- **WebVTT 转换与主索引缝合**：将所有字幕转化为 WebVTT 格式，并以独立的 `#EXT-X-MEDIA:TYPE=SUBTITLES` 形式缝合至 `master.m3u8`。

### 6. HLS v6 协议规范重构
- 自动写入 `#EXT-X-VERSION:6` 与 `#EXT-X-INDEPENDENT-SEGMENTS`（独立切片，加速播放器 Seek 拖动）。
- 将 FFmpeg 默认生成的内部文件夹标识（如 `a0`, `a1`）在主索引中重写为用户友好的语言名称（如 `中文`、`English`）。

### 7. 免配置与双击即用
- 采用 **Bat / PowerShell 杂交语法 Header**，双击脚本即可直接运行，自动绕过 PowerShell 脚本执行策略约束 (`-ExecutionPolicy Bypass`) 并设置 UTF-8 编码防乱码。
- **安全清理机制**：压片中途取消或报错时，脚本会自动回滚清理已生成的临时文件及加密文件夹，不留垃圾文件。

---

## 🛠️ 环境要求

1. **操作系统**：Windows 10 / Windows 11 / Windows Server 2016+
2. **依赖依赖项**：
   - **FFmpeg & FFprobe**：必须将其添加至系统的环境变量 `PATH` 中。
   - *(可选)* 支持 NVENC 加速的 NVIDIA 显卡及最新驱动。

---

## 📂 最终输出目录结构结构示例

假定处理视频 `Movie.mp4`，选择了 **模式 2 (480P + 720P + 1080P)**，且探查到 2 条音轨与 1 条字幕，输出目录结构如下：

```text
Movie/
├── enc.key                   # 随机生成 16 字节 AES 加密密钥
├── master.m3u8               # HLS v6 主播放索引 (聚合所有码率、音轨、字幕)
├── v0/                       # 视频流 0 (480P)
│   ├── prog_index.m3u8
│   └── slice_000.ts ...
├── v1/                       # 视频流 1 (720P)
│   ├── prog_index.m3u8
│   └── slice_000.ts ...
├── v2/                       # 视频流 2 (1080P)
│   ├── prog_index.m3u8
│   └── slice_000.ts ...
├── a0/                       # 音频流 0 (例如: 中文 AAC)
│   ├── prog_index.m3u8
│   └── slice_000.ts ...
├── a1/                       # 音频流 1 (例如: English AAC)
│   ├── prog_index.m3u8
│   └── slice_000.ts ...
└── s0/                       # 字幕流 0 (WebVTT)
    ├── prog_index.m3u8
    └── sub.vtt
```

---

## 🚀 使用指南

1. **准备文件**：
   - 将脚本放置在包含待处理视频（`.mp4` 或 `.mkv`）的文件夹中。
   - *(可选)* 若有外置音频或字幕，只需将其命名为与视频同前缀（例如 `Movie_en.srt`）并放在同一目录下。

2. **运行脚本**：
   - 直接**双击** `.bat` 文件启动。

3. **交互操作**：
   - **选择视频**：若目录下有多个视频，根据提示输入数字序号选择。
   - **选择模式**：根据需求选择码率组合（`1`-`4`）。
   - **确认压片**：检查控制台输出的帧率、GOP 帧数、GPU/CPU 编码状态，按 `Enter` 键即刻开始压片（输入 `Q` 退出）。

---

## 🔍 技术实现两阶段流程图

```text
  【输入源视频 / 外挂音字幕】
               │
               ▼
   阶段 1: 探查与硬件检测 (FFprobe)
   - 提取帧率计算 GOP: Round(FPS * 6)
   - 检查显卡是否支持 h264_nvenc
   - 生成加密密钥 (enc.key) 与 随机 IV
               │
               ▼
   阶段 2: 音视频加密转码切片 (FFmpeg)
   - 复杂滤镜处理比例填充 (Aspect Ratio Padding)
   - 强制 6 秒 IDR/Keyframe 锁定 (GOP Lock)
   - 音视频分流 (Video Profiles / Audio Tracks)
   - AES-128 实时加密生成 TS 切片
               │
               ▼
   阶段 3: HLS v6 重构与 WebVTT 缝合
   - 提取/转换 WebVTT 独立字幕
   - 升级 master.m3u8 协议至 Version 6
   - 替换 Friendly Name (a0/a1 -> 中文/English)
   - 绑定 SUBTITLES Group 标记
               │
               ▼
     【打包完成，清理临时凭证】
```

---

## 📄 开源许可

本项目遵循 MIT 许可证，你可以自由修改、分发与商业化使用。
