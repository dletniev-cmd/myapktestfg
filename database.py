import aiosqlite
from typing import Optional
import config


async def init_db() -> None:
    async with aiosqlite.connect(config.DATABASE_PATH) as db:
        await db.execute("""
            CREATE TABLE IF NOT EXISTS packs (
                id            INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id       INTEGER NOT NULL,
                name          TEXT    NOT NULL,
                short_name    TEXT    NOT NULL UNIQUE,
                is_initialized INTEGER DEFAULT 0
            )
        """)
        await db.execute("""
            CREATE TABLE IF NOT EXISTS user_active_pack (
                user_id  INTEGER PRIMARY KEY,
                pack_id  INTEGER REFERENCES packs(id)
            )
        """)
        await db.commit()


async def get_user_packs(user_id: int) -> list:
    async with aiosqlite.connect(config.DATABASE_PATH) as db:
        async with db.execute(
            "SELECT id, name, short_name, is_initialized FROM packs WHERE user_id = ? ORDER BY id",
            (user_id,)
        ) as cur:
            return await cur.fetchall()


async def get_pack(pack_id: int) -> Optional[tuple]:
    async with aiosqlite.connect(config.DATABASE_PATH) as db:
        async with db.execute(
            "SELECT id, user_id, name, short_name, is_initialized FROM packs WHERE id = ?",
            (pack_id,)
        ) as cur:
            return await cur.fetchone()


async def create_pack(user_id: int, name: str, short_name: str) -> int:
    async with aiosqlite.connect(config.DATABASE_PATH) as db:
        cur = await db.execute(
            "INSERT INTO packs (user_id, name, short_name) VALUES (?, ?, ?)",
            (user_id, name, short_name)
        )
        await db.commit()
        return cur.lastrowid


async def mark_pack_initialized(pack_id: int) -> None:
    async with aiosqlite.connect(config.DATABASE_PATH) as db:
        await db.execute(
            "UPDATE packs SET is_initialized = 1 WHERE id = ?",
            (pack_id,)
        )
        await db.commit()


async def get_active_pack(user_id: int) -> Optional[tuple]:
    async with aiosqlite.connect(config.DATABASE_PATH) as db:
        async with db.execute(
            """
            SELECT p.id, p.user_id, p.name, p.short_name, p.is_initialized
            FROM packs p
            JOIN user_active_pack uap ON p.id = uap.pack_id
            WHERE uap.user_id = ?
            """,
            (user_id,)
        ) as cur:
            return await cur.fetchone()


async def set_active_pack(user_id: int, pack_id: int) -> None:
    async with aiosqlite.connect(config.DATABASE_PATH) as db:
        await db.execute(
            """
            INSERT INTO user_active_pack (user_id, pack_id) VALUES (?, ?)
            ON CONFLICT(user_id) DO UPDATE SET pack_id = excluded.pack_id
            """,
            (user_id, pack_id)
        )
        await db.commit()


async def short_name_exists(short_name: str) -> bool:
    async with aiosqlite.connect(config.DATABASE_PATH) as db:
        async with db.execute(
            "SELECT 1 FROM packs WHERE short_name = ?",
            (short_name,)
        ) as cur:
            return await cur.fetchone() is not None


async def delete_pack(pack_id: int) -> None:
    async with aiosqlite.connect(config.DATABASE_PATH) as db:
        await db.execute(
            "UPDATE user_active_pack SET pack_id = NULL WHERE pack_id = ?",
            (pack_id,)
        )
        await db.execute("DELETE FROM packs WHERE id = ?", (pack_id,))
        await db.commit()
