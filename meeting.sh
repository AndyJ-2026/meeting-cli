#!/bin/bash
# meeting-cli — 会议纪要工具
# ScreenCaptureKit 音频采集 + FunASR 本地转写 + Claude 纪要 + Obsidian
#
# 用法:
#   meeting start              开始录音+转写
#   meeting stop               停止，生成纪要
#   meeting summary [文件]     对指定转写文件生成纪要
#   meeting list               列出历史转写

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TRANSCRIPTS_DIR="$SCRIPT_DIR/transcripts"
PID_FILE="$SCRIPT_DIR/.capture.pid"
CURRENT_SESSION="$SCRIPT_DIR/.current_session"

# ====== 配置 ======
VAULT_DIR="${MEETING_VAULT:-$HOME/Documents/Obsidian Vault}"
NOTES_FOLDER="${MEETING_NOTES_FOLDER:-会议纪要}"

SUMMARY_PROMPT='你是一个专业的会议纪要助手。请根据以下会议转录内容，生成一份结构化的会议纪要。

要求：
1. 用中文输出
2. 按以下格式组织：

# 会议纪要

## 基本信息
- 日期：
- 参会人员：（从对话中推断）

## 会议要点
（按讨论顺序，列出 3-5 个关键议题及结论）

## 决策事项
（明确列出达成的决定）

## 待办事项（Action Items）
（格式：- [ ] 事项内容 @负责人 截止日期）

## 关键讨论记录
（保留重要的讨论细节和观点）

---

以下是转录内容：
'
# ====================

mkdir -p "$TRANSCRIPTS_DIR"

log() {
    echo "[meeting] $1" >&2
}


start_capture() {
    if [ -f "$PID_FILE" ]; then
        OLD_PID=$(cat "$PID_FILE")
        if kill -0 "$OLD_PID" 2>/dev/null; then
            echo "已有会议在进行中。先运行 meeting stop"
            exit 1
        else
            # 进程已死，清理残留
            rm -f "$PID_FILE" "$CURRENT_SESSION"
            pkill -f "audio_capture" 2>/dev/null || true
            pkill -f "transcribe.py" 2>/dev/null || true
        fi
    fi

    # 检查 audio_capture 二进制
    if [ ! -x "$SCRIPT_DIR/audio_capture" ]; then
        echo "audio_capture 未找到，请先运行 ./setup.sh"
        exit 1
    fi

    # 检查 Python 依赖
    if ! python3 -c "import funasr" 2>/dev/null; then
        echo "funasr 未安装，请运行: pip install funasr modelscope torch torchaudio"
        exit 1
    fi

    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    TRANSCRIPT_FILE="$TRANSCRIPTS_DIR/meeting_${TIMESTAMP}.txt"

    echo "$TRANSCRIPT_FILE" > "$CURRENT_SESSION"

    echo "========================================="
    echo "  会议录音+转写 已开始"
    echo "  转写文件: meeting_${TIMESTAMP}.txt"
    echo "========================================="
    echo ""
    echo "  运行 meeting stop 结束会议"
    echo ""
    echo "--- 实时转写 ---"
    echo ""

    LOG_FILE="$SCRIPT_DIR/.meeting.log"

    # 记录当前进程组，方便 stop 时清理
    echo "$$" > "$PID_FILE"

    # 前台运行管道
    # audio_capture 日志 → 日志文件
    # transcribe.py 日志(stderr) → 日志文件，转写文字(stdout) → 终端
    exec "$SCRIPT_DIR/audio_capture" 2>"$LOG_FILE" | \
        python3 "$SCRIPT_DIR/transcribe.py" --output "$TRANSCRIPT_FILE" 2>>"$LOG_FILE"
}

stop_capture() {
    if [ ! -f "$PID_FILE" ]; then
        echo "没有正在进行的会议。"
        exit 1
    fi

    PID=$(cat "$PID_FILE")
    TRANSCRIPT_FILE=$(cat "$CURRENT_SESSION" 2>/dev/null)

    echo ""
    echo "正在停止会议..."

    # 终止所有相关进程
    kill "$PID" 2>/dev/null || true
    pkill -f "audio_capture" 2>/dev/null || true
    pkill -f "transcribe.py" 2>/dev/null || true

    rm -f "$PID_FILE"

    echo "会议已结束。"

    if [ -n "$TRANSCRIPT_FILE" ] && [ -f "$TRANSCRIPT_FILE" ]; then
        LINES=$(wc -l < "$TRANSCRIPT_FILE" | tr -d ' ')
        echo "转写文件: $TRANSCRIPT_FILE ($LINES 句)"
        echo ""

        # 自动生成纪要
        generate_summary "$TRANSCRIPT_FILE"
    else
        echo "未找到转写文件。"
    fi
}

generate_summary() {
    local TRANSCRIPT_FILE="$1"

    # 如果没指定文件，用最新的
    if [ -z "$TRANSCRIPT_FILE" ]; then
        TRANSCRIPT_FILE=$(ls -t "$TRANSCRIPTS_DIR"/meeting_*.txt 2>/dev/null | head -1)
    fi

    if [ -z "$TRANSCRIPT_FILE" ] || [ ! -f "$TRANSCRIPT_FILE" ]; then
        echo "没有找到转写文件。请先开会并转写。"
        exit 1
    fi

    echo "使用转写文件: $(basename "$TRANSCRIPT_FILE")"

    TRANSCRIPT=$(cat "$TRANSCRIPT_FILE")
    if [ -z "$TRANSCRIPT" ]; then
        echo "转写文件为空，无法生成纪要。"
        exit 1
    fi

    # 从文件名提取日期
    TIMESTAMP=$(basename "$TRANSCRIPT_FILE" | grep -o '[0-9]\{8\}_[0-9]\{6\}')
    DATE_STR=$(echo "$TIMESTAMP" | sed 's/\(.\{4\}\)\(.\{2\}\)\(.\{2\}\).*/\1-\2-\3/')

    echo "正在用 Claude 生成会议纪要..."
    echo ""

    SUMMARY=$(echo "${SUMMARY_PROMPT}${TRANSCRIPT}" | claude --print)

    # 输出到终端
    echo "$SUMMARY"
    echo ""

    # 保存到 Obsidian 知识库
    NOTES_DIR="$VAULT_DIR/$NOTES_FOLDER"
    mkdir -p "$NOTES_DIR"
    NOTE_FILE="$NOTES_DIR/${DATE_STR} 会议纪要.md"

    if [ -f "$NOTE_FILE" ]; then
        NOTE_FILE="$NOTES_DIR/${DATE_STR} 会议纪要_${TIMESTAMP}.md"
    fi

    echo "$SUMMARY" > "$NOTE_FILE"
    echo "纪要已保存: $NOTE_FILE"

    # 同时在转写目录保存一份
    echo "$SUMMARY" > "${TRANSCRIPT_FILE%.txt}_summary.md"
}

list_transcripts() {
    echo "历史转写记录:"
    echo ""
    ls -lt "$TRANSCRIPTS_DIR"/meeting_*.txt 2>/dev/null | while read -r line; do
        FILE=$(echo "$line" | awk '{print $NF}')
        BASENAME=$(basename "$FILE")
        LINES=$(wc -l < "$FILE" | tr -d ' ')
        SUMMARY_EXISTS=""
        if [ -f "${FILE%.txt}_summary.md" ]; then
            SUMMARY_EXISTS="[已生成纪要]"
        fi
        echo "  $BASENAME  ($LINES 句) $SUMMARY_EXISTS"
    done

    if [ -z "$(ls "$TRANSCRIPTS_DIR"/meeting_*.txt 2>/dev/null)" ]; then
        echo "  (无记录)"
    fi
}

# 主入口
case "${1:-help}" in
    start)
        start_capture
        ;;
    stop)
        stop_capture
        ;;
    summary)
        generate_summary "$2"
        ;;
    list)
        list_transcripts
        ;;
    help|*)
        echo "Meeting CLI — 会议纪要工具"
        echo ""
        echo "用法:"
        echo "  meeting start              开始录音+实时转写"
        echo "  meeting stop               停止，自动生成纪要"
        echo "  meeting summary [文件]     对指定转写文件生成纪要"
        echo "  meeting list               列出历史转写"
        echo ""
        echo "配置（环境变量）:"
        echo "  MEETING_VAULT              知识库路径 (默认: ~/Documents/Obsidian Vault)"
        echo "  MEETING_NOTES_FOLDER       纪要文件夹 (默认: 会议纪要)"
        ;;
esac
