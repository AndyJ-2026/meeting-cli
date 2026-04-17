#!/bin/bash
# meeting-cli — 会议纪要工具
# ScreenCaptureKit 音频采集 + FunASR 本地转写 + Claude 纪要 + Obsidian
#
# 用法:
#   meeting start              开始录音+转写
#   Ctrl+C                     停止，自动生成纪要并存入 Obsidian

set -e

# trap 中不用 set -e，避免命令失败导致整个 trap 中断
cleanup_and_summarize() {
    set +e
    local transcript="$1"
    local pipe_pid="$2"

    echo ""
    echo ""
    echo "正在停止会议..."
    kill "$pipe_pid" 2>/dev/null
    pkill -f "audio_capture" 2>/dev/null
    pkill -f "transcribe.py" 2>/dev/null
    wait "$pipe_pid" 2>/dev/null
    rm -f "$PID_FILE"

    echo "会议已结束。"
    echo ""

    if [ -f "$transcript" ]; then
        LINES=$(grep -c "^\[" "$transcript" 2>/dev/null || echo "0")
        echo "转写: $LINES 句"
        echo ""
        if [ "$LINES" -gt 0 ]; then
            generate_summary "$transcript"
        else
            echo "转写为空，跳过纪要生成。"
        fi
    fi
    exit 0
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TMPDIR_MEETING="${TMPDIR:-/tmp}/meeting-cli"
PID_FILE="$TMPDIR_MEETING/.capture.pid"
CURRENT_SESSION="$TMPDIR_MEETING/.current_session"

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

mkdir -p "$TMPDIR_MEETING"

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
    TRANSCRIPT_FILE="$TMPDIR_MEETING/meeting_${TIMESTAMP}.txt"

    echo "$TRANSCRIPT_FILE" > "$CURRENT_SESSION"

    echo "========================================="
    echo "  会议录音+转写 已开始"
    echo "  转写文件: meeting_${TIMESTAMP}.txt"
    echo "========================================="
    echo ""
    echo "  按 Ctrl+C 结束会议并生成纪要"
    echo ""
    echo "--- 实时转写 ---"
    echo ""

    LOG_FILE="$SCRIPT_DIR/.meeting.log"

    # 启动管道（后台运行）
    "$SCRIPT_DIR/audio_capture" 2>"$LOG_FILE" | \
        python3 "$SCRIPT_DIR/transcribe.py" --output "$TRANSCRIPT_FILE" 2>>"$LOG_FILE" &
    PIPE_PID=$!
    echo "$PIPE_PID" > "$PID_FILE"

    # Ctrl+C 时停止并生成纪要
    trap "cleanup_and_summarize '$TRANSCRIPT_FILE' '$PIPE_PID'" INT TERM

    # 前台等待管道
    wait "$PIPE_PID" 2>/dev/null || true
    rm -f "$PID_FILE"
}

stop_capture() {
    if [ ! -f "$PID_FILE" ]; then
        echo "没有正在进行的会议。"
        exit 1
    fi

    PID=$(cat "$PID_FILE")
    TRANSCRIPT_FILE=$(cat "$CURRENT_SESSION" 2>/dev/null)

    echo "正在停止会议..."

    # 终止所有相关进程
    kill "$PID" 2>/dev/null || true
    pkill -f "audio_capture" 2>/dev/null || true
    pkill -f "transcribe.py" 2>/dev/null || true
    sleep 1

    rm -f "$PID_FILE"

    echo "会议已结束。"

    if [ -n "$TRANSCRIPT_FILE" ] && [ -f "$TRANSCRIPT_FILE" ]; then
        LINES=$(grep -c "^\[" "$TRANSCRIPT_FILE" 2>/dev/null || echo "0")
        echo "转写: $LINES 句"
        echo ""
        if [ "$LINES" -gt 0 ]; then
            generate_summary "$TRANSCRIPT_FILE"
        else
            echo "转写为空，跳过纪要生成。"
        fi
    else
        echo "未找到转写文件。"
    fi
}

generate_summary() {
    local TRANSCRIPT_FILE="$1"

    # 如果没指定文件，用临时目录最新的
    if [ -z "$TRANSCRIPT_FILE" ]; then
        TRANSCRIPT_FILE=$(ls -t "$TMPDIR_MEETING"/meeting_*.txt 2>/dev/null | head -1)
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
    echo "✓ 纪要已保存: $NOTE_FILE"

    # 清理转写临时文件
    rm -f "$TRANSCRIPT_FILE"

    # 询问是否上传飞书
    upload_to_lark "$SUMMARY" "$DATE_STR" "$TIMESTAMP"
}

upload_to_lark() {
    local SUMMARY="$1"
    local DATE_STR="$2"
    local TIMESTAMP="$3"

    # 检查 lark-cli 是否可用
    if ! command -v lark &>/dev/null; then
        return
    fi

    echo ""
    echo -n "是否上传到飞书云文档？[y/N] "
    read -r REPLY </dev/tty

    case "$REPLY" in
        y|Y|yes|YES)
            echo "正在上传到飞书..."

            DOC_TITLE="${DATE_STR} 会议纪要"

            # 创建文档
            CREATE_RESULT=$(lark doc create --title "$DOC_TITLE" 2>&1)
            DOC_ID=$(echo "$CREATE_RESULT" | grep -o '"document_id":"[^"]*"' | head -1 | cut -d'"' -f4)

            if [ -z "$DOC_ID" ]; then
                echo "创建文档失败: $CREATE_RESULT"
                return
            fi

            # 逐段写入内容
            echo "$SUMMARY" | while IFS= read -r line; do
                # 跳过空行
                [ -z "$line" ] && continue

                # 识别标题
                case "$line" in
                    "# "*)
                        HEADING="${line#\# }"
                        lark doc append "$DOC_ID" --heading "$HEADING" --level 1 >/dev/null 2>&1
                        ;;
                    "## "*)
                        HEADING="${line#\#\# }"
                        lark doc append "$DOC_ID" --heading "$HEADING" --level 2 >/dev/null 2>&1
                        ;;
                    "### "*)
                        HEADING="${line#\#\#\# }"
                        lark doc append "$DOC_ID" --heading "$HEADING" --level 3 >/dev/null 2>&1
                        ;;
                    "- [ ] "*)
                        TODO="${line#- \[ \] }"
                        lark doc append "$DOC_ID" --todo "$TODO" >/dev/null 2>&1
                        ;;
                    "- "*)
                        BULLET="${line#- }"
                        lark doc append "$DOC_ID" --bullet "$BULLET" >/dev/null 2>&1
                        ;;
                    "---")
                        lark doc append "$DOC_ID" --divider >/dev/null 2>&1
                        ;;
                    *)
                        lark doc append "$DOC_ID" --text "$line" >/dev/null 2>&1
                        ;;
                esac
            done

            echo "✓ 已上传到飞书: $DOC_TITLE (ID: $DOC_ID)"
            ;;
        *)
            echo "跳过上传。"
            ;;
    esac
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
    help|*)
        echo "Meeting CLI — 会议纪要工具"
        echo ""
        echo "用法:"
        echo "  meeting start              开始录音+实时转写"
        echo "  meeting stop               停止，自动生成纪要"
        echo ""
        echo "配置（环境变量）:"
        echo "  MEETING_VAULT              知识库路径 (默认: ~/Documents/Obsidian Vault)"
        echo "  MEETING_NOTES_FOLDER       纪要文件夹 (默认: 会议纪要)"
        ;;
esac
