#!/usr/bin/env python3
"""
实时转写模块 — 从 stdin 读取 PCM 流，用本地 FunASR (paraformer) 转写。

输入: raw PCM (16-bit signed LE, mono, 16000 Hz) via stdin
输出: 转写文本到 stdout（每句一行），日志到 stderr

依赖: pip install funasr modelscope torch torchaudio
"""

import sys
import os
import time
import argparse
import logging
import warnings
import numpy as np
from pathlib import Path

# 屏蔽所有 debug 日志和警告
os.environ["FUNASR_LOG_LEVEL"] = "ERROR"
os.environ["MODELSCOPE_LOG_LEVEL"] = "ERROR"
logging.disable(logging.WARNING)
warnings.filterwarnings("ignore")

try:
    from funasr import AutoModel
except ImportError:
    print("错误: 请先安装 funasr: pip install funasr modelscope torch torchaudio", file=sys.stderr)
    sys.exit(1)

# PCM 参数
SAMPLE_RATE = 16000
BYTES_PER_SAMPLE = 2
# 每 5 秒处理一次（非流式，准确率更高）
CHUNK_SECONDS = 5
CHUNK_SIZE = SAMPLE_RATE * BYTES_PER_SAMPLE * CHUNK_SECONDS


def log(msg):
    print(f"[transcribe] {msg}", file=sys.stderr, flush=True)


def main():
    parser = argparse.ArgumentParser(description="实时转写 — stdin PCM → 本地 FunASR → 文本")
    parser.add_argument("--output", "-o", help="转写文本输出文件路径")
    args = parser.parse_args()

    if args.output:
        Path(args.output).parent.mkdir(parents=True, exist_ok=True)
        with open(args.output, "w", encoding="utf-8") as f:
            f.write(f"# 会议转写 {time.strftime('%Y-%m-%d %H:%M')}\n\n")

    log("正在加载 ASR 模型（首次运行需下载，请稍候）...")

    model = AutoModel(
        model="paraformer-zh",
        vad_model="fsmn-vad",
        punc_model="ct-punc",
        disable_update=True,
        disable_log=True,
    )

    log("模型加载完成")
    log("开始接收音频流...")
    log("每 5 秒输出一次转写结果")

    sentences = []

    try:
        while True:
            data = sys.stdin.buffer.read(CHUNK_SIZE)
            if not data:
                break

            audio = np.frombuffer(data, dtype=np.int16).astype(np.float32) / 32768.0

            # 跳过静音段（能量太低不处理）
            if np.abs(audio).mean() < 0.005:
                continue

            results = model.generate(input=audio, batch_size_s=300)

            for result in results:
                text = result.get("text", "").strip()
                if not text:
                    continue

                timestamp = time.strftime("%H:%M:%S")
                line = f"[{timestamp}] {text}"
                print(line, flush=True)
                sentences.append(line)

                if args.output:
                    with open(args.output, "a", encoding="utf-8") as f:
                        f.write(line + "\n")

    except KeyboardInterrupt:
        pass
    except BrokenPipeError:
        pass

    log(f"转写结束，共 {len(sentences)} 句")
    if args.output:
        log(f"已保存: {args.output}")


if __name__ == "__main__":
    main()
