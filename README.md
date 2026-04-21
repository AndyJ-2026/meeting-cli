# Meeting CLI

会议纪要工具 — ScreenCaptureKit 音频采集 + 本地 FunASR 转写 + Claude 纪要 + Obsidian/飞书。

## 特点

- **无需虚拟音频设备** — macOS ScreenCaptureKit 直接捕获系统音频+麦克风
- **不存音频文件** — 音频只在内存中流过，不占存储
- **完全本地转写** — FunASR (Paraformer-large) 本地运行，免费无限制
- **带标点断句** — Paraformer-large + VAD + 标点模型，输出自然可读
- **AI 纪要** — Claude 自动生成结构化会议纪要
- **多端存储** — 纪要存入 Obsidian，可选上传飞书云文档

## 安装

### 前提

- macOS 13+ (Ventura)
- Python 3
- [Claude Code CLI](https://claude.ai/code)
- [lark-cli](https://github.com/AndyJ-2026/lark-cli)（可选，用于上传飞书）

### 步骤

```bash
git clone https://github.com/AndyJ-2026/meeting-cli.git
cd meeting-cli
./setup.sh
```

`setup.sh` 会自动完成：
1. 编译 Swift 音频采集工具 (audio_capture)
2. 安装 Python 依赖 (funasr, modelscope, torch, torchaudio)
3. 检查 Claude CLI

首次运行时系统会请求屏幕录制和麦克风权限，ASR 模型自动下载（约 2.8GB）。

### 模型说明

| 模型 | 用途 | 大小 |
|------|------|------|
| Paraformer-large | 语音识别（中文，带时间戳） | 848 MB |
| speech_fsmn_vad | 语音活动检测（切分静音段） | 3.9 MB |
| punc_ct-transformer | 标点恢复 | 1.1 GB |

模型来源：阿里达摩院 FunASR，缓存在 `~/.cache/modelscope/`。

---

## 使用

### 开始会议

```bash
# 录麦克风+系统音频
./meeting.sh start

# 只录系统音频（线上会议推荐）
./meeting.sh start --system-only

# 只录指定应用的音频
./meeting.sh start --system-only --app 飞书会议
./meeting.sh start --system-only --app Chrome
```

终端实时显示转写文字。

### 查看可采集的应用

```bash
./meeting.sh start --list-apps
```

### 结束会议

按 **Ctrl+C**，自动：

1. 停止录音
2. Claude 生成结构化纪要
3. 保存到 Obsidian
4. 询问是否上传飞书云文档

---

## 配置

### 环境变量

写入 `~/.zshrc`：

| 环境变量 | 说明 | 默认值 |
|----------|------|--------|
| `MEETING_VAULT` | Obsidian 知识库路径 | `~/Documents/Obsidian Vault` |
| `MEETING_NOTES_FOLDER` | 纪要文件夹名 | `会议纪要` |
| `MEETING_SPEECH_THRESHOLD` | 语音能量阈值，越高越抗噪 | `0.005` |

嘈杂环境建议调高阈值：

```bash
export MEETING_SPEECH_THRESHOLD=0.015
```

### 自定义纪要模板

在知识库的纪要文件夹中创建 `纪要模板.md`，即可自定义纪要格式。CLI 会读取该文件作为 Claude 的生成指令。

路径：`$MEETING_VAULT/$MEETING_NOTES_FOLDER/纪要模板.md`

找不到时使用内置默认模板。

---

## 架构

```
麦克风 ──┐
         ├──→ PCM 流 ──→ FunASR 本地转写 ──→ Claude 纪要 ──→ Obsidian
系统音频 ─┘    (内存)    (Paraformer-large     (AI 总结)      飞书(可选)
                          + VAD + 标点)
```
