import re
import logging

from aiogram import Router, F, Bot
from aiogram.filters import Command
from aiogram.fsm.context import FSMContext
from aiogram.types import (
    CallbackQuery,
    InlineKeyboardMarkup,
    InlineKeyboardButton,
    Message,
)
from aiogram.utils.keyboard import InlineKeyboardBuilder

import config
from database import (
    create_pack,
    delete_pack,
    get_active_pack,
    get_pack,
    get_user_packs,
    set_active_pack,
    short_name_exists,
)
from states import PackCreation

logger = logging.getLogger(__name__)
router = Router()


def _packs_keyboard(packs: list) -> InlineKeyboardMarkup:
    builder = InlineKeyboardBuilder()
    for pack in packs:
        pid, name, short_name, _ = pack
        builder.button(text=name, callback_data=f"select_pack:{pid}")
    builder.button(text="+ создать набор", callback_data="create_pack")
    builder.adjust(1)
    return builder.as_markup()


def _pack_keyboard(pack_id: int) -> InlineKeyboardMarkup:
    builder = InlineKeyboardBuilder()
    builder.button(text="← назад", callback_data="back_to_list")
    builder.button(text="удалить", callback_data=f"pack_delete_ask:{pack_id}")
    builder.adjust(2)
    return builder.as_markup()


def _delete_confirm_keyboard(pack_id: int) -> InlineKeyboardMarkup:
    builder = InlineKeyboardBuilder()
    builder.button(text="да, удалить", callback_data=f"pack_delete_yes:{pack_id}")
    builder.button(text="нет", callback_data=f"select_pack:{pack_id}")
    builder.adjust(2)
    return builder.as_markup()


async def _show_main_menu(target, user_id: int):
    """Редактирует сообщение target (Message или CallbackQuery.message) на главное меню."""
    packs = await get_user_packs(user_id)
    text = "твои наборы:" if packs else "наборов пока нет"
    if hasattr(target, "edit_text"):
        await target.edit_text(text, reply_markup=_packs_keyboard(packs))
    else:
        await target.answer(text, reply_markup=_packs_keyboard(packs))


# ──────────────────────────────── /start ────────────────────────────────

@router.message(Command("start"))
async def cmd_start(message: Message, state: FSMContext) -> None:
    await state.clear()
    packs = await get_user_packs(message.from_user.id)
    text = "твои наборы:" if packs else "наборов пока нет"
    await message.answer(text, reply_markup=_packs_keyboard(packs))


# ──────────────────────────────── выбор набора ────────────────────────────────

@router.callback_query(F.data.startswith("select_pack:"))
async def cb_select_pack(callback: CallbackQuery, state: FSMContext) -> None:
    await state.clear()
    pack_id = int(callback.data.split(":")[1])
    await set_active_pack(callback.from_user.id, pack_id)

    pack = await get_pack(pack_id)
    if not pack:
        await callback.answer("набор не найден", show_alert=True)
        return

    _, _, name, short_name, is_initialized = pack
    note = "" if is_initialized else "\n(ссылка появится после первого стикера)"
    await callback.message.edit_text(
        f"{name}\nt.me/addstickers/{short_name}{note}\n\nкидай видео, кружки или фото",
        reply_markup=_pack_keyboard(pack_id),
    )
    await callback.answer()


@router.callback_query(F.data == "back_to_list")
async def cb_back_to_list(callback: CallbackQuery, state: FSMContext) -> None:
    await state.clear()
    await _show_main_menu(callback.message, callback.from_user.id)
    await callback.answer()


# ──────────────────────────────── удаление набора ────────────────────────────────

@router.callback_query(F.data.startswith("pack_delete_ask:"))
async def cb_delete_ask(callback: CallbackQuery) -> None:
    pack_id = int(callback.data.split(":")[1])
    pack = await get_pack(pack_id)
    if not pack:
        await callback.answer("набор не найден", show_alert=True)
        return
    _, _, name, _, _ = pack
    await callback.message.edit_text(
        f"удалить «{name}»?",
        reply_markup=_delete_confirm_keyboard(pack_id),
    )
    await callback.answer()


@router.callback_query(F.data.startswith("pack_delete_yes:"))
async def cb_delete_yes(callback: CallbackQuery) -> None:
    pack_id = int(callback.data.split(":")[1])
    await delete_pack(pack_id)
    await _show_main_menu(callback.message, callback.from_user.id)
    await callback.answer("набор удалён")


# ──────────────────────────────── создание набора ────────────────────────────────

@router.callback_query(F.data == "create_pack")
async def cb_create_pack(callback: CallbackQuery, state: FSMContext) -> None:
    await state.set_state(PackCreation.waiting_name)
    await state.update_data(bot_msg_id=callback.message.message_id)
    await callback.message.edit_text("название набора:")
    await callback.answer()


@router.message(PackCreation.waiting_name)
async def process_pack_name(message: Message, state: FSMContext, bot: Bot) -> None:
    name = (message.text or "").strip()

    # удаляем сообщение пользователя
    try:
        await message.delete()
    except Exception:
        pass

    data = await state.get_data()
    bot_msg_id = data.get("bot_msg_id")

    if not name or len(name) > 64:
        if bot_msg_id:
            await bot.edit_message_text(
                "название от 1 до 64 символов, попробуй ещё раз:",
                chat_id=message.chat.id,
                message_id=bot_msg_id,
            )
        return

    await state.update_data(pack_name=name)
    await state.set_state(PackCreation.waiting_short_name)

    if bot_msg_id:
        await bot.edit_message_text(
            "короткое имя для ссылки\n(латиница, цифры, _):",
            chat_id=message.chat.id,
            message_id=bot_msg_id,
        )


@router.message(PackCreation.waiting_short_name)
async def process_pack_short_name(message: Message, state: FSMContext, bot: Bot) -> None:
    raw = (message.text or "").strip().lower()

    try:
        await message.delete()
    except Exception:
        pass

    data = await state.get_data()
    bot_msg_id = data.get("bot_msg_id")
    pack_name = data.get("pack_name", "")

    async def edit(text: str, **kwargs):
        if bot_msg_id:
            await bot.edit_message_text(text, chat_id=message.chat.id, message_id=bot_msg_id, **kwargs)

    if not re.match(r"^[a-z0-9_]{1,64}$", raw):
        await edit("только латиница, цифры и _ — попробуй ещё раз:")
        return

    bot_name = config.BOT_USERNAME
    full_short_name = f"{raw}_by_{bot_name}"

    if await short_name_exists(full_short_name):
        await edit("такое имя уже занято, придумай другое:")
        return

    pack_id = await create_pack(message.from_user.id, pack_name, full_short_name)
    await set_active_pack(message.from_user.id, pack_id)
    await state.clear()

    packs = await get_user_packs(message.from_user.id)
    kb = _packs_keyboard(packs)

    await edit(
        f"{pack_name}\nt.me/addstickers/{full_short_name}\n(ссылка появится после первого стикера)\n\nкидай видео, кружки или фото",
        reply_markup=_pack_keyboard(pack_id),
    )
