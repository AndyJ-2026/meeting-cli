# Meeting CLI

会议纪要工具 — ScreenCaptureKit 音频采集 + 本地 FunASR 转写 + Claude 纪要 + Obsidian/飞书。

## 特点

- **无需虚拟音频设备** — macOS ScreenCaptureKit 直接捕获系统音频+麦克风
- **不存音频文件** — 音频只在内存中流过，不占存储
- **完全本地转写** — FunASR (SenseVoice) 本地运行，免费无限制
- **智能断句** — 能量 VAD 按说话节奏自动断句
- **AI 纪要** — Claude 自动生成结构化会议纪要
- **多端存储** — 纪要存入 Obsidian，可选上传飞书云文档

## 前提

- macOS 13+ (Ventura)
- Python 3
- [Claude Code CLI](https://claude.ai/code)
- [lark-cli](https://github.com/AndyJ-2026/lark-cli)（可选，用于上传飞书）

## 安装

```bash
git clone https://github.com/AndyJ-2026/meeting-cli.git
cd meeting-cli
./setup.sh
```

首次运行系统会请求屏幕录制和麦克风权限，ASR 模型自动下载（约 200MB）。

## 使用

### 开始会议

```bash
./meeting.sh start
```

终端实时显示转写文字。

### 结束会议

按 **Ctrl+C**，自动：

1. 停止录音
2. Claude 生成结构化纪要
3. 保存到 Obsidian
4. 询问是否上传飞书云文档

## 工作原理

```
麦克风 ──┐
         ├──→ PCM 流 ──→ FunASR 本地转写 ──→ Claude 纪要 ──→ Obsidian
系统音频 ─┘    (内存)      (SenseVoice)        (AI 总结)      飞书(可选)
```

## 配置

### 环境变量

通过环境变量配置（写入 `~/.zshrc`）：

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

在 Obsidian 知识库的纪要文件夹中创建 `纪要模板.md`，即可自定义纪要格式和 prompt。CLI 会自动读取该文件作为 Claude 的生成指令。

默认路径：`$MEETING_VAULT/$MEETING_NOTES_FOLDER/纪要模板.md`

找不到模板文件时使用内置默认模板。
