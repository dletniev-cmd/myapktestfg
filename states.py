from aiogram.fsm.state import State, StatesGroup


class PackCreation(StatesGroup):
    waiting_name = State()
    waiting_short_name = State()
