import asyncio
import logging
import shutil

from aiogram import Bot, Dispatcher
from aiogram.fsm.storage.memory import MemoryStorage

import config
from database import init_db
from handlers.start import router as start_router
from handlers.stickers import router as sticker_router

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger(__name__)


async def main() -> None:
    # Проверяем ffmpeg при старте
    if shutil.which("ffmpeg") is None:
        logger.error("ffmpeg NOT FOUND — стикеры работать не будут!")
    else:
        logger.info("ffmpeg found: %s", shutil.which("ffmpeg"))

    bot = Bot(token=config.BOT_TOKEN)
    dp = Dispatcher(storage=MemoryStorage())

    bot_info = await bot.get_me()
    config.BOT_USERNAME = bot_info.username
    logger.info("Bot started: @%s", config.BOT_USERNAME)

    await init_db()

    dp.include_router(start_router)
    dp.include_router(sticker_router)

    try:
        await dp.start_polling(bot, allowed_updates=["message", "callback_query"])
    finally:
        await bot.session.close()


if __name__ == "__main__":
    asyncio.run(main())
