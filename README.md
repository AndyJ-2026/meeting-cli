# Meeting CLI

会议纪要工具 — ScreenCaptureKit 音频采集 + DashScope 实时转写 + Claude 纪要 + Obsidian。

## 特点

- **无需虚拟音频设备** — 用 macOS ScreenCaptureKit 直接捕获系统音频，不用装 BlackHole
- **不存音频文件** — 音频实时流式处理，只占内存不占存储
- **实时转写** — DashScope ASR 实时出文字，不用等
- **AI 纪要** — Claude 自动生成结构化会议纪要
- **知识沉淀** — 纪要自动存入 Obsidian

## 前提

- macOS 13+ (Ventura)
- Python 3
- [Claude Code CLI](https://claude.ai/code)
- [DashScope API Key](https://dashscope.console.aliyun.com/)

## 安装

```bash
git clone https://github.com/AndyJ-2026/meeting-cli.git
cd meeting-cli
./setup.sh
```

设置 API 密钥（写入 `~/.zshrc`）：

```bash
export DASHSCOPE_API_KEY=sk-xxxxx
```

## 使用

### 开始会议

```bash
./meeting.sh start
```

系统首次运行会请求屏幕录制和麦克风权限。之后自动采集系统音频+麦克风，实时转写显示在终端。

### 结束会议

```bash
./meeting.sh stop
```

自动停止录音，Claude 生成结构化纪要并保存到 Obsidian。

### 其他命令

```bash
./meeting.sh summary [文件]   # 对指定转写文件重新生成纪要
./meeting.sh list              # 列出历史转写记录
```

## 工作原理

```
麦克风 ──┐
         ├──→ PCM 流 ──→ DashScope ASR ──→ 转写文本 ──→ Claude ──→ 纪要 ──→ Obsidian
系统音频 ─┘     (内存)       (实时)           (.txt)       (AI)      (.md)
```

## 配置

| 环境变量 | 说明 | 默认值 |
|----------|------|--------|
| `DASHSCOPE_API_KEY` | DashScope API 密钥 | （必须设置） |
| `MEETING_VAULT` | Obsidian 知识库路径 | `~/Documents/Obsidian Vault` |
| `MEETING_NOTES_FOLDER` | 纪要文件夹名 | `会议纪要` |
