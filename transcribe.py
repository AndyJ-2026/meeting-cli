#!/usr/bin/env python3
"""
实时转写模块 — 从 stdin 读取 PCM 流，用本地 FunASR (paraformer) 实时转写。

输入: raw PCM (16-bit signed LE, mono, 16000 Hz) via stdin
输出: 转写文本到 stdout（每句一行），日志到 stderr

依赖: pip install funasr modelscope torch torchaudio

用法:
  ./audio_capture | python3 transcribe.py
  ./audio_capture | python3 transcribe.py --output transcript.txt
"""

import sys
import time
import argparse
import threading
import numpy as np
from pathlib import Path

try:
    from funasr import AutoModel
except ImportError:
    print("错误: 请先安装 funasr: pip install funasr modelscope torch torchaudio", file=sys.stderr)
    sys.exit(1)

# PCM 参数（与 audio_capture 输出一致）
SAMPLE_RATE = 16000
BYTES_PER_SAMPLE = 2
# 每次处理 600ms 的音频（paraformer-streaming 推荐 chunk_size）
CHUNK_DURATION_MS = 600
CHUNK_SIZE = SAMPLE_RATE * BYTES_PER_SAMPLE * CHUNK_DURATION_MS // 1000


def log(msg):
    print(f"[transcribe] {msg}", file=sys.stderr, flush=True)


def main():
    parser = argparse.ArgumentParser(description="实时转写 — stdin PCM → 本地 FunASR → 文本")
    parser.add_argument("--output", "-o", help="转写文本输出文件路径")
    args = parser.parse_args()

    # 初始化输出文件
    if args.output:
        Path(args.output).parent.mkdir(parents=True, exist_ok=True)
        with open(args.output, "w", encoding="utf-8") as f:
            f.write(f"# 会议转写 {time.strftime('%Y-%m-%d %H:%M')}\n\n")

    # 加载模型（首次运行会自动下载 ~1GB）
    log("正在加载 ASR 模型（首次运行需下载，请稍候）...")

    model = AutoModel(
        model="paraformer-zh-streaming",
        vad_model="fsmn-vad",
        punc_model="ct-punc",
    )

    log("模型加载完成")
    log("开始接收音频流（stdin）...")
    log("按 Ctrl+C 停止")

    sentences = []
    lock = threading.Lock()
    cache = {}

    try:
        while True:
            data = sys.stdin.buffer.read(CHUNK_SIZE)
            if not data:
                log("stdin 已关闭")
                break

            # PCM bytes → float32 numpy array
            audio = np.frombuffer(data, dtype=np.int16).astype(np.float32) / 32768.0

            # 流式识别
            results = model.generate(
                input=audio,
                cache=cache,
                is_final=False,
                chunk_size=[0, 10, 5],  # [lookback, chunk, lookahead] in 60ms frames
            )

            for result in results:
                text = result.get("text", "").strip()
                if not text:
                    continue

                timestamp = time.strftime("%H:%M:%S")
                line = f"[{timestamp}] {text}"
                print(line, flush=True)

                with lock:
                    sentences.append(line)

                if args.output:
                    with open(args.output, "a", encoding="utf-8") as f:
                        f.write(line + "\n")

    except KeyboardInterrupt:
        log("收到中断信号")
    except BrokenPipeError:
        log("管道断开")

    # 处理最后一段
    try:
        results = model.generate(
            input=np.zeros(SAMPLE_RATE, dtype=np.float32),
            cache=cache,
            is_final=True,
            chunk_size=[0, 10, 5],
        )
        for result in results:
            text = result.get("text", "").strip()
            if text:
                timestamp = time.strftime("%H:%M:%S")
                line = f"[{timestamp}] {text}"
                print(line, flush=True)
                sentences.append(line)
                if args.output:
                    with open(args.output, "a", encoding="utf-8") as f:
                        f.write(line + "\n")
    except Exception:
        pass

    log(f"转写结束，共 {len(sentences)} 句")
    if args.output:
        log(f"转写已保存到: {args.output}")


if __name__ == "__main__":
    main()
