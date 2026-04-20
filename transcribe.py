#!/usr/bin/env python3
"""
实时转写模块 — 从 stdin 读取 PCM 流，用本地 FunASR (SenseVoice) 转写。

输入: raw PCM (16-bit signed LE, mono, 16000 Hz) via stdin
输出: 转写文本到 stdout（每句一行），日志到 stderr

依赖: pip install funasr modelscope torch torchaudio
注意: SenseVoice 输出带 <|zh|><|NEUTRAL|> 等标签，需清理后输出。
"""

import sys
import os
import time
import argparse
import logging
import warnings
import re
import numpy as np
from pathlib import Path

# 屏蔽 debug 日志、进度条和警告
os.environ["MODELSCOPE_LOG_LEVEL"] = "40"
os.environ["FUNASR_DISABLE_LOG"] = "1"
os.environ["TQDM_DISABLE"] = "1"
logging.disable(logging.WARNING)
warnings.filterwarnings("ignore")

# 静音 import
_real_stdout = sys.stdout
sys.stdout = open(os.devnull, "w")
try:
    from funasr import AutoModel
except ImportError:
    sys.stdout = _real_stdout
    print("错误: 请先安装 funasr: pip install funasr modelscope torch torchaudio", file=sys.stderr)
    sys.exit(1)
finally:
    sys.stdout = _real_stdout

# PCM 参数
SAMPLE_RATE = 16000
BYTES_PER_SAMPLE = 2

# VAD 参数
FRAME_MS = 100  # 每帧 100ms
FRAME_SAMPLES = SAMPLE_RATE * FRAME_MS // 1000  # 1600 samples
FRAME_BYTES = FRAME_SAMPLES * BYTES_PER_SAMPLE  # 3200 bytes

SPEECH_THRESHOLD = float(os.environ.get("MEETING_SPEECH_THRESHOLD", "0.005"))  # 语音能量阈值（默认 0.005，嘈杂环境可调高到 0.01-0.02）
SILENCE_FRAMES = 12  # 连续 12 帧静音（1.2s）则认为一句话结束
MIN_SPEECH_FRAMES = 5  # 最少 5 帧（500ms）才算有效语音
MAX_SPEECH_SECONDS = 30  # 最长 30 秒强制切句（与模型 VAD 一致）


def log(msg):
    print(f"[transcribe] {msg}", file=sys.stderr, flush=True)


def suppress_stdout(func, *args, **kwargs):
    """调用函数时屏蔽 stdout"""
    _out = sys.stdout
    sys.stdout = open(os.devnull, "w")
    try:
        return func(*args, **kwargs)
    finally:
        sys.stdout = _out


def main():
    parser = argparse.ArgumentParser(description="实时转写 — stdin PCM → 本地 FunASR → 文本")
    parser.add_argument("--output", "-o", help="转写文本输出文件路径")
    args = parser.parse_args()

    if args.output:
        Path(args.output).parent.mkdir(parents=True, exist_ok=True)
        with open(args.output, "w", encoding="utf-8") as f:
            f.write(f"# 会议转写 {time.strftime('%Y-%m-%d %H:%M')}\n\n")

    log("正在加载 ASR 模型（首次运行需下载，请稍候）...")

    model = suppress_stdout(
        AutoModel,
        model="iic/SenseVoiceSmall",
        vad_model="iic/speech_fsmn_vad_zh-cn-16k-common-pytorch",
        vad_kwargs={"max_single_segment_time": 30000},
        disable_update=True,
    )

    log("模型加载完成，开始接收音频流...")

    sentences = []
    speech_buffer = []  # 累积的语音帧
    silence_count = 0  # 连续静音帧计数
    is_speaking = False  # 当前是否在说话

    def recognize_and_output(audio_frames):
        """识别累积的音频并输出"""
        if not audio_frames:
            return
        audio = np.concatenate(audio_frames)
        duration = len(audio) / SAMPLE_RATE
        if duration < 0.3:  # 太短跳过
            return

        results = suppress_stdout(
            model.generate, input=audio, batch_size_s=300, disable_pbar=True,
            language="zh", use_itn=True,
        )

        for result in results:
            text = re.sub(r"<\|[^|]*\|>", "", result.get("text", "")).strip()
            if not text:
                continue
            timestamp = time.strftime("%H:%M:%S")
            line = f"[{timestamp}] {text}"
            print(line, flush=True)
            sentences.append(line)
            if args.output:
                with open(args.output, "a", encoding="utf-8") as f:
                    f.write(line + "\n")

    try:
        while True:
            data = sys.stdin.buffer.read(FRAME_BYTES)
            if not data:
                break

            frame = np.frombuffer(data, dtype=np.int16).astype(np.float32) / 32768.0
            energy = np.abs(frame).mean()

            if energy >= SPEECH_THRESHOLD:
                # 检测到语音
                speech_buffer.append(frame)
                silence_count = 0
                is_speaking = True

                # 超过最大时长，强制切句
                if len(speech_buffer) * FRAME_MS / 1000 >= MAX_SPEECH_SECONDS:
                    recognize_and_output(speech_buffer)
                    speech_buffer = []
                    is_speaking = False
            else:
                # 静音
                if is_speaking:
                    silence_count += 1
                    speech_buffer.append(frame)  # 保留少量静音（自然过渡）

                    if silence_count >= SILENCE_FRAMES:
                        # 一句话结束
                        if len(speech_buffer) >= MIN_SPEECH_FRAMES:
                            recognize_and_output(speech_buffer)
                        speech_buffer = []
                        silence_count = 0
                        is_speaking = False

    except KeyboardInterrupt:
        pass
    except BrokenPipeError:
        pass

    # 处理剩余
    if speech_buffer and len(speech_buffer) >= MIN_SPEECH_FRAMES:
        recognize_and_output(speech_buffer)

    log(f"转写结束，共 {len(sentences)} 句")
    if args.output:
        log(f"已保存: {args.output}")


if __name__ == "__main__":
    main()
