import asyncio
import logging
import os
import tempfile
from collections import defaultdict

from aiogram import Bot, F, Router
from aiogram.exceptions import TelegramBadRequest
from aiogram.types import (
    BufferedInputFile,
    CallbackQuery,
    InputSticker,
    Message,
)

from converter import convert_to_sticker, MAX_STICKER_DURATION
from database import get_active_pack, mark_pack_initialized

logger = logging.getLogger(__name__)
router = Router()

EMOJI = ["🎥"]

# Буферы для альбомов
_album_buffers: dict[str, list[Message]] = defaultdict(list)
_album_tasks: dict[str, asyncio.Task] = {}


def _get_tg_file(message: Message):
    """Возвращает (file_obj, is_photo)."""
    if message.video_note:
        return message.video_note, False
    if message.video:
        return message.video, False
    if message.photo:
        return message.photo[-1], True  # самое большое фото
    return None, False


async def _convert_and_upload(
    bot: Bot,
    user_id: int,
    pack_name: str,
    short_name: str,
    is_initialized: bool,
    tg_file,
    is_photo: bool,
    start_time: float = 0.0,
    clip_duration: float = MAX_STICKER_DURATION,
) -> bool:
    with tempfile.TemporaryDirectory() as tmpdir:
        ext = "jpg" if is_photo else "mp4"
        input_path = os.path.join(tmpdir, f"input.{ext}")
        output_path = os.path.join(tmpdir, "sticker.webm")

        file_info = await bot.get_file(tg_file.file_id)
        await bot.download_file(file_info.file_path, destination=input_path)

        ok = await convert_to_sticker(
            input_path, output_path,
            is_photo=is_photo,
            start_time=start_time,
            clip_duration=clip_duration,
        )
        if not ok:
            return False

        with open(output_path, "rb") as f:
            webm_data = f.read()

    sticker_file = BufferedInputFile(webm_data, filename="sticker.webm")

    if not is_initialized:
        await bot.create_new_sticker_set(
            user_id=user_id,
            name=short_name,
            title=pack_name,
            stickers=[InputSticker(sticker=sticker_file, emoji_list=EMOJI, format="video")],
        )
    else:
        uploaded = await bot.upload_sticker_file(
            user_id=user_id, sticker=sticker_file, sticker_format="video"
        )
        await bot.add_sticker_to_set(
            user_id=user_id,
            name=short_name,
            sticker=InputSticker(sticker=uploaded.file_id, emoji_list=EMOJI, format="video"),
        )

    return True


async def _send_last_sticker(bot: Bot, message: Message, short_name: str, status: Message):
    try:
        sticker_set = await bot.get_sticker_set(short_name)
        last = sticker_set.stickers[-1]
        await status.delete()
        await message.reply_sticker(last.file_id)
    except Exception:
        await status.edit_text("добавлено ✓")


# ──────────────────────────────── альбом ────────────────────────────────

async def _process_album(media_group_id: str, first_msg: Message, bot: Bot):
    await asyncio.sleep(0.7)

    messages = _album_buffers.pop(media_group_id, [])
    _album_tasks.pop(media_group_id, None)

    if not messages:
        return

    user_id = first_msg.from_user.id
    active = await get_active_pack(user_id)
    if not active:
        await first_msg.reply("сначала выбери или создай набор — /start")
        return

    pack_id, _, pack_name, short_name, is_initialized = active
    total = len(messages)
    initialized = bool(is_initialized)

    status = await first_msg.reply(f"создано 0 из {total}")

    done = 0
    for msg in messages:
        tg_file, is_photo = _get_tg_file(msg)
        if not tg_file:
            continue
        try:
            ok = await _convert_and_upload(
                bot, user_id, pack_name, short_name, initialized, tg_file, is_photo
            )
            if ok:
                if not initialized:
                    await mark_pack_initialized(pack_id)
                    initialized = True
                done += 1
                await status.edit_text(f"создано {done} из {total}")
        except Exception as e:
            logger.error("Album item error: %s", e)

    await _send_last_sticker(bot, first_msg, short_name, status)


# ──────────────────────────────── одиночное медиа ────────────────────────────────

@router.message(F.video_note | F.video | F.photo)
async def handle_media(message: Message, bot: Bot) -> None:
    # Альбом
    if message.media_group_id:
        mgid = message.media_group_id
        _album_buffers[mgid].append(message)
        if mgid not in _album_tasks:
            _album_tasks[mgid] = asyncio.create_task(
                _process_album(mgid, message, bot)
            )
        return

    user_id = message.from_user.id
    active = await get_active_pack(user_id)
    if not active:
        await message.reply("сначала выбери или создай набор — /start")
        return

    pack_id, _, pack_name, short_name, is_initialized = active
    tg_file, is_photo = _get_tg_file(message)

    status = await message.reply("обрабатываю...")

    try:
        ok = await _convert_and_upload(
            bot, user_id, pack_name, short_name, bool(is_initialized), tg_file, is_photo
        )
    except TelegramBadRequest as e:
        err = str(e).lower()
        if "video_sticker_too_big" in err:
            await status.edit_text("видео слишком большое")
        elif "sticker_video_no_alpha" in err:
            await status.edit_text("не удалось добавить альфа-канал")
        elif "stickerset_invalid" in err or "name is already occupied" in err:
            await status.edit_text("имя набора занято — создай новый через /start")
        elif "video_too_long" in err or "sticker_video_too_long" in err:
            await status.edit_text(
                "Telegram не принял стикер — слишком длинный.\n"
                "Попробуй отправить более короткое видео (до 5 с)."
            )
        else:
            await status.edit_text(f"ошибка телеграма: {e}")
        return
    except Exception as e:
        logger.error("Error: %s", e)
        await status.edit_text(f"ошибка: {e}")
        return

    if not ok:
        await status.edit_text("не удалось сжать до 256 KB, попробуй покороче")
        return

    if not is_initialized:
        await mark_pack_initialized(pack_id)

    await _send_last_sticker(bot, message, short_name, status)
