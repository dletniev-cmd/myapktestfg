import asyncio
import logging
import os

import imageio_ffmpeg

logger = logging.getLogger(__name__)

_FFMPEG = imageio_ffmpeg.get_ffmpeg_exe()

# Telegram ограничивает видеостикеры до 256 KB
MAX_SIZE_BYTES = 256 * 1024

# Максимальная длительность стикера (секунды).
# Telegram официально указывает 3 с, но на практике принимает до ~5 с
# если файл укладывается в 256 KB.
MAX_STICKER_DURATION = 4.9


async def _run_ffmpeg(
    input_path: str,
    output_path: str,
    crf: int,
    is_photo: bool,
    start_time: float = 0.0,
    clip_duration: float = MAX_STICKER_DURATION,
) -> bool:
    vf = (
        "scale=512:512:force_original_aspect_ratio=increase,"
        "crop=512:512,"
        "format=rgba,"
        "geq="
        "r='r(X,Y)':"
        "g='g(X,Y)':"
        "b='b(X,Y)':"
        "a='255*lt(hypot(X-W/2,Y-H/2),W/2)',"
        "format=yuva420p"
    )

    cmd = [_FFMPEG, "-y"]

    if is_photo:
        cmd += ["-loop", "1"]
    elif start_time > 0.0:
        cmd += ["-ss", f"{start_time:.3f}"]

    cmd += [
        "-i", input_path,
        "-vf", vf,
        "-c:v", "libvpx-vp9",
        "-pix_fmt", "yuva420p",
        "-b:v", "0",
        "-crf", str(crf),
        # 24 fps: меньше кадров при той же длине — больше бит на кадр → лучше качество
        "-r", "24",
        "-auto-alt-ref", "0",
        # многопоточное кодирование по строкам (быстрее без потери качества)
        "-row-mt", "1",
        "-an",
        "-t", f"{clip_duration:.3f}",
        output_path,
    ]

    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    _, stderr = await proc.communicate()

    if proc.returncode != 0:
        logger.error("ffmpeg error (crf=%d):\n%s", crf, stderr.decode(errors="replace"))
        return False
    return True


async def convert_to_sticker(
    input_path: str,
    output_path: str,
    is_photo: bool = False,
    start_time: float = 0.0,
    clip_duration: float = MAX_STICKER_DURATION,
) -> bool:
    # Для 5-секундных стикеров начинаем с более высокого CRF,
    # чтобы сразу метить в нужный диапазон битрейта (~400 kbps)
    for crf in [36, 40, 44, 49, 55, 63]:
        ok = await _run_ffmpeg(input_path, output_path, crf, is_photo, start_time, clip_duration)
        if not ok:
            return False
        size = os.path.getsize(output_path)
        logger.info("crf=%d → %d bytes", crf, size)
        if size <= MAX_SIZE_BYTES:
            return True
        logger.warning("too big (%d), retrying with higher crf", size)

    logger.error("could not compress to %d bytes", MAX_SIZE_BYTES)
    return False
