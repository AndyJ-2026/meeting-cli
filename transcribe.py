#!/usr/bin/env python3
"""
实时转写模块 — 从 stdin 读取 PCM 流，推送到 DashScope 实时 ASR，输出转写文本。

输入: raw PCM (16-bit signed LE, mono, 16000 Hz) via stdin
输出: 转写文本到 stdout（每句一行），日志到 stderr

依赖: pip install dashscope

用法:
  ./audio_capture | python3 transcribe.py
  ./audio_capture | python3 transcribe.py --output transcript.txt
"""

import sys
import os
import json
import uuid
import time
import struct
import threading
import argparse
from pathlib import Path

try:
    import dashscope
    from dashscope.audio.asr import Recognition, RecognitionCallback, RecognitionResult
except ImportError:
    print("错误: 请先安装 dashscope: pip install dashscope", file=sys.stderr)
    sys.exit(1)

# PCM 参数（与 audio_capture 输出一致）
SAMPLE_RATE = 16000
CHANNELS = 1
BYTES_PER_SAMPLE = 2
# 每次发送 100ms 的音频数据
CHUNK_DURATION_MS = 100
CHUNK_SIZE = SAMPLE_RATE * CHANNELS * BYTES_PER_SAMPLE * CHUNK_DURATION_MS // 1000  # 3200 bytes


def log(msg):
    print(f"[transcribe] {msg}", file=sys.stderr, flush=True)


class TranscriptionCallback(RecognitionCallback):
    """DashScope ASR 回调"""

    def __init__(self, output_file=None):
        self.sentences = []
        self.output_file = output_file
        self.lock = threading.Lock()

    def on_open(self):
        log("ASR 连接已建立")

    def on_close(self):
        log("ASR 连接已关闭")

    def on_event(self, result: RecognitionResult):
        sentence = result.get_sentence()
        if not sentence:
            return

        text = sentence.get("text", "").strip()
        if not text:
            return

        is_final = sentence.get("sentence_end", False)

        if is_final:
            # 完整句子输出
            timestamp = time.strftime("%H:%M:%S")
            line = f"[{timestamp}] {text}"
            print(line, flush=True)

            with self.lock:
                self.sentences.append(line)

            # 同时写入文件
            if self.output_file:
                with open(self.output_file, "a", encoding="utf-8") as f:
                    f.write(line + "\n")
        else:
            # 中间结果：覆盖当前行显示
            print(f"\r  ... {text}", end="", file=sys.stderr, flush=True)

    def on_error(self, result: RecognitionResult):
        log(f"ASR 错误: {result}")

    def on_complete(self):
        log("ASR 转写完成")
        print("", file=sys.stderr)  # 清除中间结果行

    def get_transcript(self):
        with self.lock:
            return "\n".join(self.sentences)


def main():
    parser = argparse.ArgumentParser(description="实时转写 — stdin PCM → DashScope ASR → 文本")
    parser.add_argument("--output", "-o", help="转写文本输出文件路径")
    parser.add_argument("--model", default="paraformer-realtime-v2", help="ASR 模型 (默认: paraformer-realtime-v2)")
    args = parser.parse_args()

    # 检查 API key
    api_key = os.environ.get("DASHSCOPE_API_KEY")
    if not api_key:
        log("错误: 请设置 DASHSCOPE_API_KEY 环境变量")
        log("  获取方式: https://dashscope.console.aliyun.com/")
        sys.exit(1)

    dashscope.api_key = api_key

    # 初始化输出文件
    if args.output:
        Path(args.output).parent.mkdir(parents=True, exist_ok=True)
        with open(args.output, "w", encoding="utf-8") as f:
            f.write(f"# 会议转写 {time.strftime('%Y-%m-%d %H:%M')}\n\n")

    callback = TranscriptionCallback(output_file=args.output)

    log(f"正在连接 DashScope ASR (模型: {args.model})...")

    recognition = Recognition(
        model=args.model,
        format="pcm",
        sample_rate=SAMPLE_RATE,
        callback=callback,
    )
    recognition.start()

    log("开始接收音频流（stdin）...")
    log("按 Ctrl+C 停止")

    try:
        while True:
            data = sys.stdin.buffer.read(CHUNK_SIZE)
            if not data:
                log("stdin 已关闭")
                break
            recognition.send_audio_frame(data)
    except KeyboardInterrupt:
        log("收到中断信号")
    except BrokenPipeError:
        log("管道断开")
    finally:
        recognition.stop()

    # 输出最终统计
    transcript = callback.get_transcript()
    sentence_count = len(callback.sentences)
    log(f"转写结束，共 {sentence_count} 句")

    if args.output:
        log(f"转写已保存到: {args.output}")


if __name__ == "__main__":
    main()
