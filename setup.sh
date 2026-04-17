#!/bin/bash
# meeting-cli 安装脚本
# macOS 13+ (Ventura)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Meeting CLI 安装 ==="
echo ""

# 检查 macOS 版本
MACOS_VERSION=$(sw_vers -productVersion | cut -d. -f1)
if [ "$MACOS_VERSION" -lt 13 ]; then
    echo "错误: 需要 macOS 13 (Ventura) 或更高版本"
    echo "当前版本: $(sw_vers -productVersion)"
    exit 1
fi

# 编译 Swift 音频采集工具
echo "[1/3] 编译音频采集工具..."
if [ -f "$SCRIPT_DIR/audio_capture.swift" ]; then
    swiftc -O -o "$SCRIPT_DIR/audio_capture" "$SCRIPT_DIR/audio_capture.swift" \
        -framework ScreenCaptureKit -framework AVFoundation \
        -framework CoreMedia -framework CoreAudio
    echo "  ✓ audio_capture 编译成功"
else
    echo "  错误: audio_capture.swift 未找到"
    exit 1
fi

# 安装 Python 依赖
echo "[2/3] 安装 Python 依赖..."
if python3 -c "import funasr" 2>/dev/null; then
    echo "  ✓ funasr 已安装"
else
    pip3 install funasr modelscope torch torchaudio
    echo "  ✓ funasr 安装完成"
fi

# 检查 Claude CLI
echo "[3/3] 检查 Claude CLI..."
if command -v claude &>/dev/null; then
    echo "  ✓ Claude CLI 已安装"
else
    echo "  ⚠ Claude CLI 未找到，summary 功能需要它"
    echo "  安装: https://claude.ai/code"
fi

# 检查环境变量
echo ""
echo "=== 安装完成 ==="
echo ""
echo "首次使用时："
echo "  • 系统会弹出屏幕录制和麦克风权限请求"
echo "  • ASR 模型会自动下载（约 1GB，仅首次）"
echo ""
echo "使用方法:"
echo "  ./meeting.sh start    开始会议录音+转写"
echo "  ./meeting.sh stop     结束会议，生成纪要"
