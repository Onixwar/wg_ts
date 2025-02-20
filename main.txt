import asyncio
import logging
import json
import string
import subprocess
import sqlite3
import time
import html
import os
import telebot
import aiosqlite
import buttons
import dbworker
import emoji as e
import asyncio
import threading
import shutil
import qrcode
import logging

from config import secret_key, account_id, bot_token, one_month_cost, admin_tg_id, trial_period, count_free_from_referrer, UTC_time, tg_token, tg_shop_token
from io import BytesIO
from payment import create, check
from datetime import datetime
from telebot import TeleBot
from telebot import asyncio_filters
from telebot import types
from telebot.async_telebot import AsyncTeleBot
from telebot.asyncio_storage import StateMemoryStorage
from telebot.asyncio_handler_backends import State, StatesGroup
from buttons import main_buttons
from dbworker import User, payment_already_checked
from telebot.asyncio_filters import StateFilter

with open("config.json", encoding="utf-8") as file_handler:
    CONFIG = json.load(file_handler)
    dbworker.CONFIG = CONFIG
    buttons.CONFIG = CONFIG

with open("texts.json", encoding="utf-8") as file_handler:
    text_mess = json.load(file_handler)
    texts_for_bot = text_mess

DATABASE_NAME = "data.sqlite"
BOTAPIKEY = CONFIG["tg_token"]

bot = AsyncTeleBot(CONFIG["tg_token"], state_storage=StateMemoryStorage())


async def initialize_database():
    async with aiosqlite.connect(DATABASE_NAME) as db:
        await db.execute('''
            CREATE TABLE IF NOT EXISTS userss (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                username STRING DEFAULT '',
                full_name TEXT DEFAULT '',
                fullname STRING DEFAULT '',
                tgid INTEGER UNIQUE ON CONFLICT IGNORE,
                registered INTEGER DEFAULT 0,
                trial_expiry INTEGER DEFAULT 0,
                subscription INTEGER DEFAULT 0,
                referrer_id INTEGER DEFAULT NULL,
                referrals INTEGER DEFAULT 0,
                bonus_awarded INTEGER DEFAULT 0,
                referral_paid BOOLEAN DEFAULT FALSE,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                banned BOOLEAN DEFAULT FALSE,
                notion_oneday BOOLEAN DEFAULT FALSE,
                notified_about_expiry INTEGER DEFAULT 0,
                trial_continue BOOLEAN DEFAULT FALSE,
                traffic_sent INTEGER DEFAULT 0,
                traffic_received INTEGER DEFAULT 0,
                referral_bonus_awarded BOOLEAN DEFAULT FALSE,
                public_key TEXT DEFAULT '',
                allowed BOOLEAN DEFAULT 1,
                wg_ipv4 TEXT DEFAULT '',
                wg_ipv6 TEXT DEFAULT '',
                wg_priv_key TEXT DEFAULT '',
                wg_pub_key TEXT DEFAULT '',
                wg_preshared_key TEXT DEFAULT '',
                FOREIGN KEY (referrer_id) REFERENCES userss(id)
            );
        ''')

        await db.execute('''
            CREATE TABLE IF NOT EXISTS payments (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                tgid INTEGER NOT NULL,
                bill_id TEXT NOT NULL,
                amount REAL NOT NULL,
                time_to_add INTEGER NOT NULL,
                mesid TEXT NOT NULL,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            );
        ''')

        await db.execute('''
            CREATE TABLE IF NOT EXISTS user_activity (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                tgid INTEGER,
                last_access TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                usage_count INTEGER DEFAULT 0,
                FOREIGN KEY (tgid) REFERENCES userss(tgid)
            );
        ''')

        await db.execute('''
            CREATE TABLE IF NOT EXISTS static_profiles (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name STRING,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            );
        ''')
        await db.commit()

async def main():
    # Инициализация базы данных перед запуском бота
    await initialize_database()
    await bot.polling(non_stop=True, interval=0, request_timeout=60)


class MyStates(StatesGroup):
    findUserViaId = State()
    editUser = State()
    editUserResetTime = State()
    UserAddTimeDays = State()
    UserAddTimeHours = State()
    UserAddTimeMinutes = State()
    UserAddTimeApprove = State()
    AdminNewUser = State()
    UserRemoveTimeDays = State()  # Добавьте это состояние
    UserRemoveTimeHours = State()
    UserRemoveTimeMinutes = State()
    UserRemoveTimeApprove = State()
    SendMessageToAll = State()
    ConfirmSendMessageToAll = State()


@bot.message_handler(commands=['start'])
async def start(message: types.Message):
    if message.chat.type != "private":
        return

    await bot.delete_state(message.from_user.id)

    user_dat = await User.GetInfo(message.chat.id)
    if not user_dat:
        user_dat = User()
        user_dat.tgid = message.chat.id

    if user_dat.registered:
        await bot.send_message(
            message.chat.id,
            "Информация о подписке",
            parse_mode="HTML",
            reply_markup=await main_buttons(user_dat)
        )
        return

    # Добавляем нового пользователя
    username = "@" + str(message.from_user.username) if message.from_user.username else "@Неизвестно" 
    arg_referrer_id = message.text[7:] if len(message.text) > 7 else None
    referrer_id = arg_referrer_id if arg_referrer_id and arg_referrer_id.isdigit() else None

    await user_dat.Adduser(username, message.from_user.full_name, referrer_id)

    # Повторно получаем данные после добавления
    user_dat = await User.GetInfo(message.chat.id)

    if user_dat and user_dat.registered:
        # Отправляем приветственное сообщение
        await bot.send_message(
            message.chat.id,
            e.emojize(texts_for_bot["hello_message"]),
            parse_mode="HTML",
            reply_markup=await main_buttons(user_dat)
        )
        await bot.send_message(
            message.chat.id,
            e.emojize(texts_for_bot["trial_message"])
        )

        # Добавляем кнопку для подписки на канал
        channel_keyboard = types.InlineKeyboardMarkup()
        channel_keyboard.add(
            types.InlineKeyboardButton(
                e.emojize("🔔 Подпишись на новостной канал"), url="https://t.me/StudyVpn"
            )
        )

        await bot.send_message(
            message.chat.id,
            "Чтобы не пропускать обновления, подпишитесь на наш новостной канал!",
            reply_markup=channel_keyboard
        )

        # Отправляем конфигурацию VPN
        try:
            config_path = f'/root/wg0-client-{user_dat.tgid}.conf'

            # Проверяем наличие файла конфигурации
            if not os.path.exists(config_path):
                await bot.send_message(
                    message.chat.id,
                    "Файл конфигурации отсутствует. Попробую его пересоздать..."
                )
                result = subprocess.call(f'./addusertovpn.sh {user_dat.tgid}', shell=True)

                # Проверяем повторно
                if not os.path.exists(config_path):
                    await bot.send_message(
                        message.chat.id,
                        "Ошибка: файл конфигурации не удалось создать. Обратитесь в поддержку."
                    )
                    return

            # Отправляем файл конфигурации
            with open(config_path, 'rb') as config:
                await bot.send_document(
                    chat_id=message.chat.id,
                    document=config,
                    caption="Ваш файл конфигурации VPN.",
                    visible_file_name=f"{user_dat.tgid}.conf"
                )


        except FileNotFoundError:
            await bot.send_message(
                chat_id=message.chat.id,
                text="Ошибка: файл конфигурации не найден. Обратитесь в поддержку."
            )

@bot.message_handler(state=MyStates.editUser, content_types=["text"])
async def Work_with_Message(m: types.Message):
    async with bot.retrieve_data(m.from_user.id) as data:
        tgid = data['usertgid']
    user_dat = await User.GetInfo(tgid)
    if e.demojize(m.text) == "Назад :right_arrow_curving_left:":
        await bot.reset_data(m.from_user.id)
        await bot.delete_state(m.from_user.id)
        await bot.send_message(m.from_user.id, "Вернул вас назад!", reply_markup=await buttons.admin_buttons())
        return
    if e.demojize(m.text) == "Добавить время":
        await bot.set_state(m.from_user.id, MyStates.UserAddTimeDays)
        Butt_skip = types.ReplyKeyboardMarkup(resize_keyboard=True)
        Butt_skip.add(types.KeyboardButton(e.emojize(f"Пропустить :next_track_button:")))
        await bot.send_message(m.from_user.id, "Введите сколько дней хотите добавить:", reply_markup=Butt_skip)
        return
    if e.demojize(m.text) == "Обнулить время":
        await bot.set_state(m.from_user.id, MyStates.editUserResetTime)
        Butt_skip = types.ReplyKeyboardMarkup(resize_keyboard=True)
        Butt_skip.add(types.KeyboardButton(e.emojize(f"Да")))
        Butt_skip.add(types.KeyboardButton(e.emojize(f"Нет")))
        await bot.send_message(m.from_user.id, "Вы уверены что хотите сбросить время для этого пользователя ?",
                               reply_markup=Butt_skip)
        return
    if e.demojize(m.text) == "Убавить время":
        await bot.set_state(m.from_user.id, MyStates.UserRemoveTimeDays)
        Butt_skip = types.ReplyKeyboardMarkup(resize_keyboard=True)
        Butt_skip.add(types.KeyboardButton(e.emojize(f"Пропустить :next_track_button:")))
        await bot.send_message(m.from_user.id, "Введите сколько дней хотите убрать:", reply_markup=Butt_skip)
        return


@bot.message_handler(state=MyStates.editUserResetTime, content_types=["text"])
async def Work_with_Message(m: types.Message):
    async with bot.retrieve_data(m.from_user.id) as data:
        tgid = data['usertgid']

    if e.demojize(m.text) == "Да":
        db = await aiosqlite.connect(DATABASE_NAME)
        db.row_factory = sqlite3.Row
        await db.execute(f"Update userss set subscription = ?, banned=false, notion_oneday=true where tgid=?",
                         (str(int(time.time())), tgid))
        await db.commit()
        await bot.send_message(m.from_user.id, "Время сброшено!")

    async with bot.retrieve_data(m.from_user.id) as data:
        usertgid = data['usertgid']
    user_dat = await User.GetInfo(usertgid)
    readymes = f"Пользователь: <b>{str(user_dat.fullname)}</b> ({str(user_dat.username)})\nTG-id: <code>{str(user_dat.tgid)}</code>\n\n"

    if int(user_dat.subscription) > int(time.time()):
        readymes += f"Подписка: до <b>{datetime.utcfromtimestamp(int(user_dat.subscription) + CONFIG['UTC_time'] * 3600).strftime('%d.%m.%Y %H:%M')}</b> :check_mark_button:"
    else:
        readymes += f"Подписка: закончилась <b>{datetime.utcfromtimestamp(int(user_dat.subscription) + CONFIG['UTC_time'] * 3600).strftime('%d.%m.%Y %H:%M')}</b> :cross_mark:"
    await bot.set_state(m.from_user.id, MyStates.editUser)

    await bot.send_message(m.from_user.id, e.emojize(readymes),
                           reply_markup=await buttons.admin_buttons_edit_user(user_dat), parse_mode="HTML")


@bot.message_handler(state=MyStates.UserAddTimeDays, content_types=["text"])
async def Work_with_Message(m: types.Message):
    if e.demojize(m.text) == "Пропустить :next_track_button:":
        days = 0
    else:
        try:
            days = int(m.text)
        except:
            await bot.send_message(m.from_user.id, "Должно быть число!\nПопробуйте еще раз.")
            return
        if days < 0:
            await bot.send_message(m.from_user.id, "Не должно быть отрицательным числом!\nПопробуйте еще раз.")
            return

    async with bot.retrieve_data(m.from_user.id) as data:
        data['days'] = days
    await bot.set_state(m.from_user.id, MyStates.UserAddTimeHours)
    Butt_skip = types.ReplyKeyboardMarkup(resize_keyboard=True)
    Butt_skip.add(types.KeyboardButton(e.emojize(f"Пропустить :next_track_button:")))
    await bot.send_message(m.from_user.id, "Введите сколько часов хотите добавить:", reply_markup=Butt_skip)


@bot.message_handler(state=MyStates.UserAddTimeHours, content_types=["text"])
async def Work_with_Message(m: types.Message):
    if e.demojize(m.text) == "Пропустить :next_track_button:":
        hours = 0
    else:
        try:
            hours = int(m.text)
        except:
            await bot.send_message(m.from_user.id, "Должно быть число!\nПопробуйте еще раз.")
            return
        if hours < 0:
            await bot.send_message(m.from_user.id, "Не должно быть отрицательным числом!\nПопробуйте еще раз.")
            return

    async with bot.retrieve_data(m.from_user.id) as data:
        data['hours'] = hours
    await bot.set_state(m.from_user.id, MyStates.UserAddTimeMinutes)
    Butt_skip = types.ReplyKeyboardMarkup(resize_keyboard=True)
    Butt_skip.add(types.KeyboardButton(e.emojize(f"Пропустить :next_track_button:")))
    await bot.send_message(m.from_user.id, "Введите сколько минут хотите добавить:", reply_markup=Butt_skip)


@bot.message_handler(state=MyStates.UserAddTimeMinutes, content_types=["text"])
async def Work_with_Message(m: types.Message):
    if e.demojize(m.text) == "Пропустить :next_track_button:":
        minutes = 0
    else:
        try:
            minutes = int(m.text)
        except:
            await bot.send_message(m.from_user.id, "Должно быть число!\nПопробуйте еще раз.")
            return
        if minutes < 0:
            await bot.send_message(m.from_user.id, "Не должно быть отрицательным числом!\nПопробуйте еще раз.")
            return

    async with bot.retrieve_data(m.from_user.id) as data:
        data['minutes'] = minutes
        hours = data['hours']
        days = data['days']
        tgid = data['usertgid']

    await bot.set_state(m.from_user.id, MyStates.UserAddTimeApprove)
    Butt_skip = types.ReplyKeyboardMarkup(resize_keyboard=True)
    Butt_skip.add(types.KeyboardButton(e.emojize(f"Да")))
    Butt_skip.add(types.KeyboardButton(e.emojize(f"Нет")))
    await bot.send_message(m.from_user.id,
                           f"Пользователю {str(tgid)} добавится:\n\nДни: {str(days)}\nЧасы: {str(hours)}\nМинуты: {str(minutes)}\n\nВсе верно ?",
                           reply_markup=Butt_skip)


@bot.message_handler(state=MyStates.UserAddTimeApprove, content_types=["text"])
async def Work_with_Message(m: types.Message):
    all_time = 0
    if e.demojize(m.text) == "Да":
        async with bot.retrieve_data(m.from_user.id) as data:
            minutes = data['minutes']
            hours = data['hours']
            days = data['days']
            tgid = data['usertgid']
        all_time += minutes * 60
        all_time += hours * 60 * 60
        all_time += days * 60 * 60 * 24
        await AddTimeToUser(tgid, all_time)
        await bot.send_message(m.from_user.id, e.emojize("Время добавлено пользователю!"), parse_mode="HTML")

    async with bot.retrieve_data(m.from_user.id) as data:
        usertgid = data['usertgid']
    user_dat = await User.GetInfo(usertgid)
    readymes = f"Пользователь: <b>{str(user_dat.fullname)}</b> ({str(user_dat.username)})\nTG-id: <code>{str(user_dat.tgid)}</code>\n\n"

    if int(user_dat.subscription) > int(time.time()):
        readymes += f"Подписка: до <b>{datetime.utcfromtimestamp(int(user_dat.subscription) + CONFIG['UTC_time'] * 3600).strftime('%d.%m.%Y %H:%M')}</b> :check_mark_button:"
    else:
        readymes += f"Подписка: закончилась <b>{datetime.utcfromtimestamp(int(user_dat.subscription) + CONFIG['UTC_time'] * 3600).strftime('%d.%m.%Y %H:%M')}</b> :cross_mark:"
    await bot.set_state(m.from_user.id, MyStates.editUser)

    await bot.send_message(m.from_user.id, e.emojize(readymes),
                           reply_markup=await buttons.admin_buttons_edit_user(user_dat), parse_mode="HTML")


@bot.message_handler(state=MyStates.findUserViaId, content_types=["text"])
async def Work_with_Message(m: types.Message):
    await bot.delete_state(m.from_user.id)
    try:
        user_id = int(m.text)
    except:
        await bot.send_message(m.from_user.id, "Неверный Id!", reply_markup=await buttons.admin_buttons())
        return
    user_dat = await User.GetInfo(user_id)
    if not user_dat.registered:
        await bot.send_message(m.from_user.id, "Такого пользователя не существует!",
                               reply_markup=await buttons.admin_buttons())
        return

    readymes = f"Пользователь: <b>{str(user_dat.fullname)}</b> ({str(user_dat.username)})\nTG-id: <code>{str(user_dat.tgid)}</code>\n\n"
    if int(user_dat.subscription) > int(time.time()):
        readymes += f"Подписка: до <b>{datetime.utcfromtimestamp(int(user_dat.subscription) + CONFIG['UTC_time'] * 3600).strftime('%d.%m.%Y %H:%M')}</b> :check_mark_button:"
    else:
        readymes += f"Подписка: закончилась <b>{datetime.utcfromtimestamp(int(user_dat.subscription) + CONFIG['UTC_time'] * 3600).strftime('%d.%m.%Y %H:%M')}</b> :cross_mark:"
    await bot.set_state(m.from_user.id, MyStates.editUser)
    async with bot.retrieve_data(m.from_user.id) as data:
        data['usertgid'] = user_dat.tgid
    await bot.send_message(m.from_user.id, e.emojize(readymes),
                           reply_markup=await buttons.admin_buttons_edit_user(user_dat), parse_mode="HTML")


@bot.message_handler(state=MyStates.AdminNewUser, content_types=["text"])
async def Work_with_Message(m: types.Message):
    if e.demojize(m.text) == "Назад :right_arrow_curving_left:":
        await bot.delete_state(m.from_user.id)
        await bot.send_message(m.from_user.id, "Вернул вас назад!", reply_markup=await buttons.admin_buttons())
        return

    if set(m.text) <= set(string.ascii_letters + string.digits):
        db = await aiosqlite.connect(DATABASE_NAME)
        await db.execute(f"INSERT INTO static_profiles (name) values (?)", (m.text,))
        await db.commit()
        check = subprocess.call(f'./addusertovpn.sh {str(m.text)}', shell=True)
        await bot.delete_state(m.from_user.id)
        await bot.send_message(m.from_user.id,
                               "Пользователь добавлен!", reply_markup=await buttons.admin_buttons_static_users())
    else:
        await bot.send_message(m.from_user.id,
                               "Можно использовать только латинские символы и арабские цифры!\nПопробуйте заново.")
        return


@bot.message_handler(state=MyStates.UserRemoveTimeDays, content_types=["text"])
async def Remove_Time_Days(m: types.Message):
    if e.demojize(m.text) == "Пропустить :next_track_button:":
        days = 0
    else:
        try:
            days = int(m.text)
        except:
            await bot.send_message(m.from_user.id, "Должно быть число!\nПопробуйте еще раз.")
            return
        if days < 0:
            await bot.send_message(m.from_user.id, "Не должно быть отрицательным числом!\nПопробуйте еще раз.")
            return

    async with bot.retrieve_data(m.from_user.id) as data:
        data['days'] = days
    await bot.set_state(m.from_user.id, MyStates.UserRemoveTimeHours)
    Butt_skip = types.ReplyKeyboardMarkup(resize_keyboard=True)
    Butt_skip.add(types.KeyboardButton(e.emojize(f"Пропустить :next_track_button:")))
    await bot.send_message(m.from_user.id, "Введите сколько часов хотите убрать:", reply_markup=Butt_skip)


@bot.message_handler(state=MyStates.UserRemoveTimeHours, content_types=["text"])
async def Remove_Time_Hours(m: types.Message):
    if e.demojize(m.text) == "Пропустить :next_track_button:":
        hours = 0
    else:
        try:
            hours = int(m.text)
        except:
            await bot.send_message(m.from_user.id, "Должно быть число!\nПопробуйте еще раз.")
            return
        if hours < 0:
            await bot.send_message(m.from_user.id, "Не должно быть отрицательным числом!\nПопробуйте еще раз.")
            return

    async with bot.retrieve_data(m.from_user.id) as data:
        data['hours'] = hours
    await bot.set_state(m.from_user.id, MyStates.UserRemoveTimeMinutes)
    Butt_skip = types.ReplyKeyboardMarkup(resize_keyboard=True)
    Butt_skip.add(types.KeyboardButton(e.emojize(f"Пропустить :next_track_button:")))
    await bot.send_message(m.from_user.id, "Введите сколько минут хотите убрать:", reply_markup=Butt_skip)


@bot.message_handler(state=MyStates.UserRemoveTimeMinutes, content_types=["text"])
async def Remove_Time_Minutes(m: types.Message):
    if e.demojize(m.text) == "Пропустить :next_track_button:":
        minutes = 0
    else:
        try:
            minutes = int(m.text)
        except:
            await bot.send_message(m.from_user.id, "Должно быть число!\nПопробуйте еще раз.")
            return
        if minutes < 0:
            await bot.send_message(m.from_user.id, "Не должно быть отрицательным числом!\nПопробуйте еще раз.")
            return

    async with bot.retrieve_data(m.from_user.id) as data:
        data['minutes'] = minutes
        hours = data['hours']
        days = data['days']
        tgid = data['usertgid']

    await bot.set_state(m.from_user.id, MyStates.UserRemoveTimeApprove)
    Butt_skip = types.ReplyKeyboardMarkup(resize_keyboard=True)
    Butt_skip.add(types.KeyboardButton(e.emojize(f"Да")))
    Butt_skip.add(types.KeyboardButton(e.emojize(f"Нет")))
    await bot.send_message(m.from_user.id,
                           f"У пользователя {str(tgid)} будет убрано:\n\nДни: {str(days)}\nЧасы: {str(hours)}\nМинуты: {str(minutes)}\n\nВсе верно?",
                           reply_markup=Butt_skip)


@bot.message_handler(state=MyStates.UserRemoveTimeApprove, content_types=["text"])
async def Remove_Time_Approve(m: types.Message):
    if e.demojize(m.text) == "Да":
        async with bot.retrieve_data(m.from_user.id) as data:
            minutes = data['minutes']
            hours = data['hours']
            days = data['days']
            tgid = data['usertgid']

        all_time = (minutes * 60) + (hours * 3600) + (days * 86400)
        current_time = int(time.time())

        # Уменьшение времени подписки
        user_dat = await User.GetInfo(tgid)
        new_subscription = max(current_time, user_dat.subscription - all_time)

        db = await aiosqlite.connect(DATABASE_NAME)
        await db.execute("UPDATE userss SET subscription = ? WHERE tgid = ?", (new_subscription, tgid))
        await db.commit()
        await db.close()

        await bot.send_message(m.from_user.id, e.emojize("Время уменьшено!"), parse_mode="HTML")
    else:
        await bot.send_message(m.from_user.id, "Операция отменена.", parse_mode="HTML")

    # Возврат в меню редактирования
    await bot.set_state(m.from_user.id, MyStates.editUser)
    user_dat = await User.GetInfo(tgid)
    await bot.send_message(m.from_user.id, e.emojize(f"Время обновлено для пользователя {user_dat.username}."),
                           reply_markup=await buttons.admin_buttons_edit_user(user_dat))






@bot.message_handler(commands=["send_to_all"])
async def send_to_all_start(message: types.Message):
    if message.chat.id != CONFIG["admin_tg_id"]:
        await bot.send_message(message.chat.id, "Команда доступна только администратору.")
        return

    await bot.set_state(message.chat.id, MyStates.SendMessageToAll)
    await bot.send_message(message.chat.id, "Введите сообщение, которое хотите отправить всем пользователям:")

@bot.message_handler(state=MyStates.SendMessageToAll, content_types=["text"])
async def send_to_all_process(message: types.Message):
    # Получаем введенное сообщение
    text = message.text

    # Подтверждение перед отправкой
    markup = types.ReplyKeyboardMarkup(resize_keyboard=True)
    markup.add(types.KeyboardButton("Отправить"))
    markup.add(types.KeyboardButton("Отмена"))

    await bot.set_state(message.chat.id, MyStates.ConfirmSendMessageToAll)
    async with bot.retrieve_data(message.chat.id) as data:
        data["message_to_send"] = text

    await bot.send_message(message.chat.id, f"Вы хотите отправить всем сообщение:\n\n{text}", reply_markup=markup)

@bot.message_handler(state=MyStates.ConfirmSendMessageToAll, content_types=["text"])
async def confirm_send_to_all(message: types.Message):
    if message.text == "Отмена":
        await bot.reset_data(message.chat.id)
        await bot.delete_state(message.chat.id)
        await bot.send_message(message.chat.id, "Отправка сообщения отменена.")
        return

    if message.text == "Отправить":
        async with bot.retrieve_data(message.chat.id) as data:
            text = data["message_to_send"]

        # Отправляем сообщение всем пользователям
        db = sqlite3.connect(DATABASE_NAME)
        db.row_factory = sqlite3.Row
        c = db.execute("SELECT tgid FROM userss WHERE subscription > strftime('%s', 'now')")
        users = c.fetchall()
        c.close()
        db.close()

        for user in users:
            try:
                await bot.send_message(user["tgid"], text, parse_mode="HTML")
            except Exception as e:
                print(f"Не удалось отправить сообщение пользователю {user['tgid']}: {e}")

        await bot.reset_data(message.chat.id)
        await bot.delete_state(message.chat.id)
        await bot.send_message(message.chat.id, "Сообщение отправлено всем пользователям.")



@bot.message_handler(commands=["send_subscription_reminders"])
async def send_subscription_reminders(message: types.Message):
    if message.chat.id != CONFIG["admin_tg_id"]:
        await bot.send_message(message.chat.id, "Команда доступна только администратору.")
        return

    # Получение всех пользователей с активной подпиской
    db = sqlite3.connect(DATABASE_NAME)
    db.row_factory = sqlite3.Row
    c = db.execute("SELECT tgid, subscription FROM userss WHERE subscription > strftime('%s', 'now')")
    users = c.fetchall()
    c.close()
    db.close()

    for user in users:
        time_now = int(time.time())
        remaining_days = (int(user["subscription"]) - time_now) // 86400

        if remaining_days < 3:
            message_text = "⏰ У вас осталось меньше 3 дней подписки. Поспешите приобрести продление!"
        elif remaining_days <= 7:
            message_text = "🎉 У вас осталось 7 дней подписки. Отличная работа, но стоит задуматься о продлении!"
        elif remaining_days <= 14:
            message_text = "👍 У вас еще 14 дней подписки. Так держать, но можно купить сразу несколько месяцев!"

        try:
            await bot.send_message(user["tgid"], message_text, parse_mode="HTML")
        except Exception as e:
            print(f"Не удалось отправить сообщение пользователю {user['tgid']}: {e}")

    await bot.send_message(message.chat.id, "Сообщения о подписках успешно отправлены.")


@bot.message_handler(func=lambda message: e.demojize(message.text) == "Отправить сообщение всем :envelope:")
async def handle_send_to_all_button(message: types.Message):
    if message.chat.id != CONFIG["admin_tg_id"]:
        await bot.send_message(message.chat.id, "Команда доступна только администратору.")
        return
    await send_to_all_start(message)  # Вызываем функцию массовой отправки


@bot.message_handler(func=lambda message: e.demojize(message.text) == "Напомнить о подписке :alarm_clock:")
async def handle_subscription_reminders_button(message: types.Message):
    if message.chat.id != CONFIG["admin_tg_id"]:
        await bot.send_message(message.chat.id, "Команда доступна только администратору.")
        return
    await send_subscription_reminders(message)  # Вызываем функцию отправки напоминаний


@bot.message_handler(commands=["admin"])
async def admin_panel(message: types.Message):
    if message.chat.id != CONFIG["admin_tg_id"]:
        await bot.send_message(message.chat.id, "Команда доступна только администратору.")
        return

    await bot.send_message(
        message.chat.id,
        "Вы вошли в админ-панель.",
        reply_markup=await admin_buttons()
    )





@bot.message_handler(func=lambda message: message.text == e.emojize("Помощь ❓"))
async def help_handler(message: types.Message):
    support_username = "StudyVpnRu"
    support_link = f"tg://resolve?domain={support_username}"

    markup = types.InlineKeyboardMarkup()
    button_yes = types.InlineKeyboardButton("Написать поддержке?", url=support_link)
    button_no = types.InlineKeyboardButton("Нет", callback_data="cancel_help")
    markup.add(button_yes, button_no)

    await bot.send_message(
        message.chat.id,
        "Хотите связаться с поддержкой?",
        reply_markup=markup,
        disable_web_page_preview=True
    )

@bot.callback_query_handler(func=lambda call: call.data == "cancel_help")
async def cancel_help(call: types.CallbackQuery):
    await bot.answer_callback_query(call.id)
    await bot.delete_message(call.message.chat.id, call.message.message_id)



@bot.message_handler(state="*", content_types=["text"])
async def Work_with_Message(m: types.Message):
    user_dat = await User.GetInfo(m.chat.id)

    if user_dat.registered == False:
        try:
            username = "@" + str(m.from_user.username)
        except:

            username = str(m.from_user.id)

        # Определяем referrer_id
        arg_referrer_id = m.text[7:]
        referrer_id = arg_referrer_id if arg_referrer_id != user_dat.tgid else 0

        await user_dat.Adduser(username, m.from_user.full_name, referrer_id)
        await bot.send_message(m.chat.id,
                               texts_for_bot["hello_message"],
                               parse_mode="HTML", reply_markup=await main_buttons(user_dat,wasUpdate=True))
        return
    await user_dat.CheckNewNickname(m)

    if m.from_user.id == CONFIG["admin_tg_id"]:
        if e.demojize(m.text) == "Админ-панель :smiling_face_with_sunglasses:":
            await bot.send_message(m.from_user.id, "Админ панель", reply_markup=await buttons.admin_buttons())
            return
        if e.demojize(m.text) == "Главное меню :right_arrow_curving_left:":
            await bot.send_message(m.from_user.id, e.emojize("Админ-панель :smiling_face_with_sunglasses:"),
                                   reply_markup=await main_buttons(user_dat,wasUpdate=True))
            return
        if e.demojize(m.text) == "Вывести пользователей :bust_in_silhouette:":
            await bot.send_message(m.from_user.id, e.emojize("Выберите каких пользователей хотите вывести."),
                                   reply_markup=await buttons.admin_buttons_output_users())
            return

        if e.demojize(m.text) == "Назад :right_arrow_curving_left:":
            await bot.send_message(m.from_user.id, "Админ панель", reply_markup=await buttons.admin_buttons())
            return

        if m.from_user.id == CONFIG["admin_tg_id"]:
            # Обработка команды statistics для получения статистики
            if e.demojize(m.text) == "statistics :bar_chart:":
                await show_stats(m)
                return

        if e.demojize(m.text) == "Всех пользователей":
            allusers = await user_dat.GetAllUsers()
            readymass = []
            readymes = ""
            for i in allusers:
                # Извлечение данных из записи базы данных
                fullname = i["fullname"] if i["fullname"] is not None else "Неизвестно"
                username = i["username"] if i["username"] is not None else "Неизвестно"
                tgid = i["tgid"] if i["tgid"] is not None else "Неизвестно"
                subscription_time = int(i["subscription"]) if i["subscription"] is not None else 0

                # Форматирование даты подписки
                formatted_date = datetime.utcfromtimestamp(subscription_time + CONFIG['UTC_time'] * 3600).strftime(
                    '%d.%m.%Y %H:%M')

                # Формирование строки для вывода
                raw = f"{fullname} ({username}|<code>{tgid}</code>)"
                date_info = f" - {formatted_date}\n\n" if subscription_time > int(time.time()) else "\n\n"

                # Проверка длины сообщения и добавление в массив
                if len(readymes) + len(raw + date_info) > 4090:
                    readymass.append(readymes)
                    readymes = ""
                readymes += raw + date_info

            # Отправка сообщений
            readymass.append(readymes)
            for msg in readymass:
                await bot.send_message(m.from_user.id, e.emojize(msg), parse_mode="HTML")
            return

        # Только для тех кто в бане как не активный с завершенной подпиской
        if e.demojize(m.text) == "Продлить пробный период":
            db = sqlite3.connect(DATABASE_NAME)
            db.row_factory = sqlite3.Row
            c = db.execute("SELECT * FROM userss WHERE banned=true AND username <> '@None'")
            log = c.fetchall()
            c.close()
            db.close()

            BotChecking = TeleBot(BOTAPIKEY)
            timetoadd = 7 * 60 * 60 * 24
            countAdded = 0
            countBlocked = 0

            db = sqlite3.connect(DATABASE_NAME)
            for i in log:
                try:
                    countAdded += 1
                    db.execute("UPDATE userss SET subscription = ?, banned=false, notion_oneday=false WHERE tgid=?",
                               (str(int(time.time()) + timetoadd), i["tgid"]))
                    db.commit()

                    subprocess.call(f'./addusertovpn.sh {str(i["tgid"])}', shell=True)

                    # Отправляем сообщение пользователю
                    Butt_main = types.ReplyKeyboardMarkup(resize_keyboard=True)
                    Butt_main.add(types.KeyboardButton(e.emojize("Продлить :money_bag:")),
                                  types.KeyboardButton(e.emojize("Как подключить :gear:")))
                    BotChecking.send_message(i['tgid'], texts_for_bot["alert_to_extend_sub"], reply_markup=Butt_main)

                except Exception as ex:
                    print(f"Ошибка при отправке сообщения: {ex}")
                    countAdded -= 1
                    countBlocked += 1
                    continue

            db.close()

            BotChecking.send_message(CONFIG['admin_tg_id'],
                                     f"Добавлен пробный период {countAdded} пользователям. {countBlocked} пользователей заблокировало бота",
                                     parse_mode="HTML")

        if e.demojize(m.text) == "Уведомление об обновлении":
            db = sqlite3.connect(DATABASE_NAME)
            db.row_factory = sqlite3.Row
            c = db.execute(f"SELECT * FROM userss where username <> '@None'")
            log = c.fetchall()
            c.close()
            db.close()
            BotChecking = TeleBot(BOTAPIKEY)
            countSended = 0
            countBlocked = 0
            for i in log:
                try:
                    countSended += 1

                    Butt_main = types.ReplyKeyboardMarkup(resize_keyboard=True)
                    Butt_main.add(types.KeyboardButton(e.emojize(f"Продлить :money_bag:")),
                                  types.KeyboardButton(e.emojize(f"Как подключить :gear:")))
                    BotChecking.send_message(i['tgid'],
                                             texts_for_bot["alert_to_update"],
                                             reply_markup=Butt_main, parse_mode="HTML")
                except:
                    countSended -= 1
                    countBlocked += 1
                    pass

            BotChecking.send_message(CONFIG['admin_tg_id'],
                                     f"Сообщение отправлено {countSended} пользователям. {countBlocked} пользователей заблокировало бота",
                                     parse_mode="HTML")

        if e.demojize(m.text) == "Пользователей с подпиской":
            allusers = await user_dat.GetAllUsersWithSub()
            readymass = []
            readymes = ""

            if len(allusers) == 0:
                await bot.send_message(m.from_user.id, e.emojize("Нету пользователей с подпиской!"),
                                       reply_markup=await buttons.admin_buttons(), parse_mode="HTML")
                return

            for i in allusers:
                # Проверка на None и задание значения по умолчанию
                subscription_time = int(i['subscription']) if i['subscription'] is not None else 0
                fullname = i['fullname'] if i['fullname'] is not None else "Неизвестно"
                username = i['username'] if i['username'] is not None else "Неизвестно"
                tgid = i['tgid'] if i['tgid'] is not None else "Неизвестно"

                # Форматирование строки для вывода
                formatted_date = datetime.utcfromtimestamp(subscription_time + CONFIG['UTC_time'] * 3600).strftime(
                    '%d.%m.%Y %H:%M')

                # Создаем строку для сообщения
                raw = f"{fullname} ({username}|<code>{tgid}</code>) - {formatted_date}\n\n"

                # Проверка длины сообщения перед отправкой
                if len(readymes) + len(raw) > 4090:
                    readymass.append(readymes)
                    readymes = ""
                readymes += raw

            readymass.append(readymes)
            for msg in readymass:
                await bot.send_message(m.from_user.id, e.emojize(msg), parse_mode="HTML")

        if e.demojize(m.text) == "Вывести статичных пользователей":
            db = await aiosqlite.connect(DATABASE_NAME)
            c = await db.execute(f"select * from static_profiles")
            all_staticusers = await c.fetchall()
            await c.close()
            await db.close()
            if len(all_staticusers) == 0:
                await bot.send_message(m.from_user.id, "Статичных пользователей нету!")
                return
            for i in all_staticusers:
                Butt_delete_account = types.InlineKeyboardMarkup()
                Butt_delete_account.add(types.InlineKeyboardButton(e.emojize("Удалить пользователя :cross_mark:"),
                                                                   callback_data=f'DELETE:{str(i[0])}'))

                config = open(f'/root/wg0-client-{str(str(i[1]))}.conf', 'rb')
                await bot.send_document(chat_id=m.chat.id, document=config,
                                        visible_file_name=f"{str(str(i[1]))}.conf",
                                        caption=f"Пользователь: <code>{str(i[1])}</code>", parse_mode="HTML",
                                        reply_markup=Butt_delete_account)

            return

        if e.demojize(m.text) == "Редактировать пользователя по id :pencil:":
            await bot.send_message(m.from_user.id, "Введите Telegram Id пользователя:",
                                   reply_markup=types.ReplyKeyboardRemove())
            await bot.set_state(m.from_user.id, MyStates.findUserViaId)
            return

        if e.demojize(m.text) == "Статичные пользователи":
            await bot.send_message(m.from_user.id, "Выберите пункт меню:",
                                   reply_markup=await buttons.admin_buttons_static_users())
            return

        if e.demojize(m.text) == "Добавить пользователя :plus:":
            await bot.send_message(m.from_user.id,
                                   "Введите имя для нового пользователя!\nМожно использовать только латинские символы и арабские цифры.",
                                   reply_markup=await buttons.admin_buttons_back())
            await bot.set_state(m.from_user.id, MyStates.AdminNewUser)
            return

    if e.demojize(m.text) == "Продлить :money_bag:":
        payment_info = await user_dat.PaymentInfo()

        # if not payment_info is None:
        #     urltopay=CONFIG["url_redirect_to_pay"]+str((await p2p.check(bill_id=payment_info['bill_id'])).pay_url)[-36:]
        #     Butt_payment = types.InlineKeyboardMarkup()
        #     Butt_payment.add(
        #         types.InlineKeyboardButton(e.emojize("Оплатить :money_bag:"), url=urltopay))
        #     Butt_payment.add(
        #         types.InlineKeyboardButton(e.emojize("Отменить платеж :cross_mark:"), callback_data=f'Cancel:'+str(user_dat.tgid)))
        #     await bot.send_message(m.chat.id,"Оплатите прошлый счет или отмените его!",reply_markup=Butt_payment)
        # else:
        if True:
            Butt_payment = types.InlineKeyboardMarkup()
            Butt_payment.add(
                types.InlineKeyboardButton(e.emojize(f"1 мес. 📅 - {int(getCostBySale(1))} руб."),
                                           callback_data="BuyMonth:1"))
            Butt_payment.add(
                types.InlineKeyboardButton(e.emojize(f"3 мес. 📅 - {int(getCostBySale(3))} руб. (-5% ХИТ)"),
                                           callback_data="BuyMonth:3"))
            Butt_payment.add(
                types.InlineKeyboardButton(e.emojize(f"6 мес. 📅 - {int(getCostBySale(6))} руб. (-10%)"),
                                           callback_data="BuyMonth:6"))
            Butt_payment.add(
                types.InlineKeyboardButton(e.emojize(f"12 мес. 📅 - {int(getCostBySale(12))} руб. (-15%)"),
                                           callback_data="BuyMonth:12"))
            Butt_payment.add(
                types.InlineKeyboardButton(
                    e.emojize(f"Бесплатно +1 неделя за нового друга"),
                    callback_data="Referrer"))

            # await bot.send_message(m.chat.id, "<b>Оплатить можно с помощью Банковской карты или Qiwi кошелька!</b>\n\nВыберите на сколько месяцев хотите приобрести подписку:", reply_markup=Butt_payment,parse_mode="HTML")
            await bot.send_message(m.chat.id,
                                   "<b>Оплачиваейте любым удобным вам способом!</b>\n\nВыберите на сколько месяцев хотите приобрести VPN:",
                                   reply_markup=Butt_payment, parse_mode="HTML")

    if e.demojize(m.text) == "Как подключить :gear:":
        if user_dat.trial_subscription == False:
            Butt_how_to = types.InlineKeyboardMarkup()
            Butt_how_to.add(
                types.InlineKeyboardButton(e.emojize("Видеоинструкция"), callback_data="Tutorial"))

            config = open(f'/root/wg0-client-{str(user_dat.tgid)}.conf', 'rb')
            await bot.send_document(chat_id=m.chat.id, document=config, visible_file_name=f"{str(user_dat.tgid)}.conf",
                                    caption=texts_for_bot["how_to_connect_info"], parse_mode="HTML",
                                    reply_markup=Butt_how_to)
        else:
            await bot.send_message(chat_id=m.chat.id, text="Сначала нужно купить подписку!")

    if e.demojize(m.text) == "Рефералы :busts_in_silhouette:":
        countReferal = await user_dat.countReferrerByUser()
        refLink = "https://t.me/StudyVpnBot?start=" + str(user_dat.tgid)

        msg = f"<b>Приглашайте друзей и получайте +1 неделю бесплатно за каждого нового друга</b>\n\r\n\r" \
              f"Количество рефералов: {str(countReferal)} " \
              f"\n\rВаша реферальная ссылка: \n\r<code>{refLink}</code>"

        await bot.send_message(chat_id=m.chat.id, text=msg, parse_mode='HTML')


@bot.callback_query_handler(func=lambda c: 'Referrer' in c.data)
async def Referrer(call: types.CallbackQuery):
    user_dat = await User.GetInfo(call.from_user.id)
    countReferal = await user_dat.countReferrerByUser()
    refLink = "https://t.me/StudyVpnBot?start=" + str(user_dat.tgid)

    msg = f"Приглашайте друзей и получайте +1 неделю безлимитного тарифа за каждого нового друга\n\r\n\r" \
          f"Количество рефералов: {str(countReferal)} " \
          f"\n\rВаша реферальная ссылка: \n\r<code>{refLink}</code>"

    await bot.send_message(chat_id=call.message.chat.id, text=msg, parse_mode='HTML')


@bot.callback_query_handler(func=lambda c: 'Tutorial' in c.data)
async def Tutorial(call: types.CallbackQuery):
    msg = "https://youtube.com/shorts/n-oxWNzDmqQ?feature=share"
    await bot.send_message(chat_id=call.message.chat.id, text=msg, parse_mode='HTML')


@bot.callback_query_handler(func=lambda c: 'BuyMonth:' in c.data)
async def Buy_month(call: types.CallbackQuery):
    user_dat = await User.GetInfo(call.from_user.id)
    chat_id = call.message.chat.id
    Month_count = int(str(call.data).split(":")[1])
    price = 1 if user_dat.tgid == CONFIG["admin_tg_id"] else getCostBySale(Month_count)

    await bot.delete_message(chat_id, call.message.id)
    plans = {
        "count_month": Month_count,
        "price": price,
        "month_count": Month_count,
    }
    payment_url, payment_id = create(plans, chat_id, user_dat.tgid)

    keyboard = [
        [
            types.InlineKeyboardButton('Оплатить', url=payment_url),
            types.InlineKeyboardButton('Проверить оплату', callback_data=f"CheckPurchase:{payment_id}"),
        ],
    ]
    reply_markup = types.InlineKeyboardMarkup(keyboard)
    await bot.send_message(chat_id, text="Ссылка на оплату 💸", reply_markup=reply_markup)

@bot.callback_query_handler(func=lambda c: 'CheckPurchase:' in c.data)
async def check_handler(call: types.CallbackQuery) -> None:
    payment_id = str(call.data).split(":")[1]
    payment_status, payment_metadata = check(payment_id)
    if payment_status:
        if await payment_already_checked(payment_id):
            ## Повторно НЕ фиксируем платеж и пополяем подписку
            await bot.send_message(call.from_user.id, "Проверка оплаты уже выполнена")
            await bot.delete_message(chat_id=call.message.chat.id, message_id=call.message.id)
        else:
            ## Фиксируем платеж и пополняем подписку
            await got_payment(call, payment_metadata)
    else:
        await bot.send_message(call.from_user.id, f"Повторите действие через 3 минуты. Оплата пока не прошла или возникла ошибка, поддержка https://t.me/StudyVpnRu")

# @bot.callback_query_handler(func=lambda c: 'Cancel:' in c.data)
# async def Cancel_payment(call: types.CallbackQuery):
#     user_dat = await User.GetInfo(call.from_user.id)
#     payment_info = await user_dat.PaymentInfo()
#     if not payment_info is None:
#         await user_dat.CancelPayment()
#         await p2p.reject(bill_id=payment_info['bill_id'])
#         await bot.edit_message_text(chat_id=call.from_user.id,message_id=call.message.id,text="Платеж отменен!",reply_markup=None)
#
#
#     await bot.answer_callback_query(call.id)


async def AddTimeToUser(tgid, timetoadd):
    userdat = await User.GetInfo(tgid)
    db = await aiosqlite.connect(DATABASE_NAME)
    db.row_factory = sqlite3.Row

    if int(userdat.subscription) < int(time.time()):
        passdat = int(time.time()) + timetoadd
        await db.execute(f"UPDATE userss SET subscription = ?, banned = false, notion_oneday = false WHERE tgid = ?",
                         (passdat, tgid))
        subprocess.call(f'./addusertovpn.sh {str(tgid)}', shell=True)
        await bot.send_message(tgid, "Ваш доступ обновлен!", reply_markup=await main_buttons(userdat,wasUpdate=True))
    else:
        passdat = int(userdat.subscription) + timetoadd
        await db.execute(f"UPDATE userss SET subscription = ?, notion_oneday = false WHERE tgid = ?",
                         (passdat, tgid))
        await bot.send_message(tgid, "Ваша подписка продлена!", reply_markup=await main_buttons(await User.GetInfo(tgid), wasUpdate=True))

    await db.commit()
    await db.close()

    ## todo: set updste info about actual time of subsription


@bot.callback_query_handler(func=lambda c: 'DELETE:' in c.data or 'DELETYES:' in c.data or 'DELETNO:' in c.data)
async def DeleteUserYesOrNo(call: types.CallbackQuery):
    idstatic = str(call.data).split(":")[1]
    db = await aiosqlite.connect(DATABASE_NAME)
    c = await db.execute(f"select * from static_profiles where id=?", (int(idstatic),))
    staticuser = await c.fetchone()
    await c.close()
    await db.close()
    if staticuser[0] != int(idstatic):
        await bot.answer_callback_query(call.id, "Пользователь уже удален!")
        return

    if "DELETE:" in call.data:
        Butt_delete_account = types.InlineKeyboardMarkup()
        Butt_delete_account.add(
            types.InlineKeyboardButton(e.emojize("Удалить!"), callback_data=f'DELETYES:{str(staticuser[0])}'),
            types.InlineKeyboardButton(e.emojize("Нет"), callback_data=f'DELETNO:{str(staticuser[0])}'))
        await bot.edit_message_reply_markup(call.message.chat.id, call.message.id, reply_markup=Butt_delete_account)
        await bot.answer_callback_query(call.id)
        return
    if "DELETYES:" in call.data:
        db = await aiosqlite.connect(DATABASE_NAME)
        await db.execute(f"delete from static_profiles where id=?", (int(idstatic),))
        await db.commit()
        await bot.delete_message(call.message.chat.id, call.message.id)
        subprocess.call(f'./deleteuserfromvpn.sh {str(staticuser[1])}', shell=True)
        await bot.answer_callback_query(call.id, "Пользователь удален!")
        return
    if "DELETNO:" in call.data:
        Butt_delete_account = types.InlineKeyboardMarkup()
        Butt_delete_account.add(types.InlineKeyboardButton(e.emojize("Удалить пользователя :cross_mark:"),
                                                           callback_data=f'DELETE:{str(idstatic)}'))
        await bot.edit_message_reply_markup(call.message.chat.id, call.message.id, reply_markup=Butt_delete_account)
        await bot.answer_callback_query(call.id)
        return


@bot.pre_checkout_query_handler(func=lambda query: True)
async def checkout(pre_checkout_query):
    print(pre_checkout_query.total_amount)
    month = int(str(pre_checkout_query.invoice_payload).split(":")[1])
    if getCostBySale(month) * 100 != pre_checkout_query.total_amount:
        await bot.answer_pre_checkout_query(pre_checkout_query.id, ok=False,
                                            error_message="Нельзя купить по старой цене!")
        await bot.send_message(pre_checkout_query.from_user.id,
                               "<b>Цена изменилась! Нельзя приобрести по старой цене!</b>", parse_mode="HTML")
    else:
        await bot.answer_pre_checkout_query(pre_checkout_query.id, ok=True,
                                            error_message="Оплата не прошла, попробуйте еще раз!")


def getCostBySale(month):
    cost = month * CONFIG['one_month_cost']
    if month == 3:
        saleAsPersent = 5
    elif month == 6:
        saleAsPersent = 10
    elif month == 12:
        saleAsPersent = 15
    else:
        return int(cost)
    return int(cost - (cost * saleAsPersent / 100))


async def got_payment(m, payment_metadata):
    month = int(payment_metadata.get("month_count"))
    user = await User.GetInfo(m.from_user.id)
    payment_id = str(m.data).split(":")[1]

    addTimeSubscribe = month * 30 * 24 * 60 * 60
    await user.NewPay(payment_id, getCostBySale(month), addTimeSubscribe, m.from_user.id)
    await AddTimeToUser(m.from_user.id, addTimeSubscribe)

    # Проверяем, есть ли у пользователя реферер
    if user.referrer_id:
        referrer_user = await User.GetInfo(user.referrer_id)
        if referrer_user and referrer_user.registered:
            # Начисляем рефереру 7 дней за оплату рефералом
            await AddTimeToUser(referrer_user.tgid, 7 * 86400)

            # Уведомляем реферера о бонусе
            await bot.send_message(
                referrer_user.tgid,
                "🎁 Вам начислено 7 дней за оплату вашего реферала!",
                reply_markup=await main_buttons(referrer_user,wasUpdate=True)
            )

    await bot.send_message(
        m.from_user.id,
        texts_for_bot["success_pay_message"],
        reply_markup=await main_buttons(user, wasUpdate=True),
        parse_mode="HTML"
    )


bot.add_custom_filter(asyncio_filters.StateFilter(bot))


# def checkPayments():
#     while True:
#         try:
#             time.sleep(5)
#             db = sqlite3.connect(DATABASE_NAME)
#             db.row_factory = sqlite3.Row
#             c = db.execute(f"SELECT * FROM payments")
#             log = c.fetchall()
#             c.close()
#             db.close()
#
#             if len(log)>0:
#                 p2pCheck = QiwiP2P(auth_key=QIWI_PRIV_KEY)
#                 for i in log:
#                     status = p2pCheck.check(bill_id=i["bill_id"]).status
#                     if status=="PAID":
#                         BotChecking = TeleBot(BOTAPIKEY)
#
#                         db = sqlite3.connect(DATABASE_NAME)
#                         db.execute(f"DELETE FROM payments where tgid=?",
#                                    (i['tgid'],))
#                         userdat=db.execute(f"SELECT * FROM userss WHERE tgid=?",(i['tgid'],)).fetchone()
#                         if int(userdat[2])<int(time.time()):
#                             passdat=int(time.time())+i["time_to_add"]
#                             db.execute(f"UPDATE userss SET subscription = ?, banned=false, notion_oneday=false where tgid=?",(str(int(time.time())+i["time_to_add"]),i['tgid']))
#                             #check = subprocess.call(f'./addusertovpn.sh {str(i["tgid"])}', shell=True)
#                             BotChecking.send_message(i['tgid'],e.emojize('Данны для входа были обновлены, скачайте новый файл авторизации через раздел "Как подключить :gear:"'))
#                         else:
#                             passdat = int(userdat[2]) + i["time_to_add"]
#                             db.execute(f"UPDATE userss SET subscription = ?, notion_oneday=false where tgid=?",
#                                        (str(int(userdat[2])+i["time_to_add"]), i['tgid']))
#                         db.commit()
#
#
#                         Butt_main = types.ReplyKeyboardMarkup(resize_keyboard=True)
#                         dateto = datetime.utcfromtimestamp(int(passdat) +CONFIG['UTC_time']*3600).strftime('%d.%m.%Y %H:%M')
#                         timenow = int(time.time())
#                         if int(passdat) >= timenow:
#                             Butt_main.add(
#                                 types.KeyboardButton(e.emojize(f":green_circle: До: {dateto} МСК:green_circle:")))
#
#                         Butt_main.add(types.KeyboardButton(e.emojize(f"Продлить :money_bag:")),
#                                       types.KeyboardButton(e.emojize(f"Как подключить :gear:")))
#
#                         BotChecking.edit_message_reply_markup(chat_id=i['tgid'],message_id=i['mesid'],reply_markup=None)
#                         BotChecking.send_message(i['tgid'],
#                                                  texts_for_bot["success_pay_message"],
#                                                  reply_markup=Butt_main)
#
#
#                     if status == "EXPIRED":
#                         BotChecking = TeleBot(BOTAPIKEY)
#                         BotChecking.edit_message_text(chat_id=i['tgid'], message_id=i['mesid'],text="Платеж просрочен.",
#                                                               reply_markup=None)
#                         db = sqlite3.connect(DATABASE_NAME)
#                         db.execute(f"DELETE FROM payments where tgid=?",
#                                    (i['tgid'],))
#                         db.commit()
#
#
#
#
#         except:
#             pass


def checkTime():
    while True:
        try:
            time.sleep(60 * 10)
            db = sqlite3.connect(DATABASE_NAME)
            db.row_factory = sqlite3.Row
            c = db.execute("SELECT * FROM userss")
            log = c.fetchall()
            c.close()
            db.close()
            BotChecking = TeleBot(BOTAPIKEY)

            for i in log:
                time_now = int(time.time())
                remained_time = int(i['subscription']) - time_now

                # Проверка на истекшую подписку
                if remained_time <= 0 and not i['banned']:
                    db = sqlite3.connect(DATABASE_NAME)
                    db.execute("UPDATE userss SET banned=true WHERE tgid=?", (i['tgid'],))
                    db.commit()
                    db.close()
                    subprocess.call(f'./deleteuserfromvpn.sh {str(i["tgid"])}', shell=True)

                    dateto = datetime.utcfromtimestamp(int(i['subscription']) + CONFIG['UTC_time'] * 3600).strftime(
                        '%d.%m.%Y %H:%M')
                    Butt_main = types.ReplyKeyboardMarkup(resize_keyboard=True)
                    Butt_main.add(
                        types.KeyboardButton(e.emojize(f":red_circle: Закончилась: {dateto} МСК:red_circle:")))
                    Butt_main.add(types.KeyboardButton(e.emojize(f"Продлить :money_bag:")),
                                  types.KeyboardButton(e.emojize(f"Рефералы :busts_in_silhouette:")),
                                  types.KeyboardButton(e.emojize(f"Как подключить :gear:")))

                    BotChecking.send_message(i['tgid'],
                                             texts_for_bot["ended_sub_message"],
                                             reply_markup=Butt_main, parse_mode="HTML")

                # Уведомление за 3 дня до окончания подписки
                if 0 < remained_time <= 3 * 86400 and not i['notified_about_expiry']:
                    db = sqlite3.connect(DATABASE_NAME)
                    db.execute("UPDATE userss SET notified_about_expiry=true WHERE tgid=?", (i['tgid'],))
                    db.commit()
                    db.close()

                    Butt_refer = types.InlineKeyboardMarkup()
                    Butt_refer.add(types.InlineKeyboardButton(e.emojize(f"Бесплатно  неделя за нового друга"),
                                                              callback_data="Referrer"))

                    BotChecking.send_message(i['tgid'],
                                             "⚠️ Ваша подписка заканчивается через 3 дня. Продлите её, чтобы продолжить пользоваться услугами.",
                                             reply_markup=Butt_refer,
                                             parse_mode="HTML")

                # Уведомление за 1 день до окончания подписки
                if remained_time <= 86400 and not i['notion_oneday']:
                    db = sqlite3.connect(DATABASE_NAME)
                    db.execute("UPDATE userss SET notion_oneday=true WHERE tgid=?", (i['tgid'],))
                    db.commit()

                    Butt_refer = types.InlineKeyboardMarkup()
                    Butt_refer.add(types.InlineKeyboardButton(e.emojize(f"Бесплатно  неделя за нового друга"),
                                                              callback_data="Referrer"))

                    BotChecking.send_message(i['tgid'],
                                             texts_for_bot["alert_to_renew_sub"],
                                             reply_markup=Butt_refer,
                                             parse_mode="HTML")

                # Продление бесплатного периода для неактивных пользователей
                approveLTV = 60 * 60 * 24 * int(CONFIG['trial_period'])
                expire_time = time_now - int(i['subscription'])

                if expire_time >= approveLTV and not i['trial_continue']:
                    timetoadd = approveLTV
                    newExpireEnd = int(time.time() + timetoadd)
                    db = sqlite3.connect(DATABASE_NAME)
                    db.execute("UPDATE userss SET trial_continue=1 WHERE tgid=?", (i['tgid'],))
                    db.execute("UPDATE userss SET subscription=?, banned=false, notion_oneday=false WHERE tgid=?",
                               (newExpireEnd, i['tgid']))
                    db.commit()
                    db.close()

                    subprocess.call(f'./addusertovpn.sh {str(i["tgid"])}', shell=True)
                    dateto = datetime.utcfromtimestamp(newExpireEnd + CONFIG['UTC_time'] * 3600).strftime(
                        '%d.%m.%Y %H:%M')

                    Butt_main = types.ReplyKeyboardMarkup(resize_keyboard=True)
                    Butt_main.add(types.KeyboardButton(e.emojize(f":green_circle: До: {dateto} МСК:green_circle:")),
                                  types.KeyboardButton(e.emojize(f"Продлить :money_bag:")),
                                  types.KeyboardButton(e.emojize(f"Рефералы :busts_in_silhouette:")),
                                  types.KeyboardButton(e.emojize(f"Как подключить :gear:")))

                    BotChecking.send_message(i['tgid'],
                                             e.emojize(texts_for_bot["alert_to_extend_sub"]),
                                             reply_markup=Butt_main, parse_mode="HTML")

        except Exception as err:
            print(f"Ошибка: {err}")
            pass




@bot.message_handler(commands=['stats'])
async def show_stats(m: types.Message):
    # Проверка, что команду вызывает администратор
    if m.chat.id != CONFIG['admin_tg_id']:
        return

    # Подключаемся к базе данных и получаем статистику
    async with aiosqlite.connect(DATABASE_NAME) as db:
        # Подсчёт активных подписчиков (тех, у кого подписка не истекла)
        active_users_query = await db.execute("SELECT COUNT(*) FROM userss WHERE subscription > ?", (int(time.time()),))
        active_count = await active_users_query.fetchone()

        # Подсчёт всех пользователей
        total_users_query = await db.execute("SELECT COUNT(*) FROM userss")
        total_count = await total_users_query.fetchone()

        # Подсчёт общего дохода
        total_income_query = await db.execute("SELECT SUM(amount) FROM payments")
        total_income = await total_income_query.fetchone()

        # Подсчёт пользователей, зарегистрировавшихся за последние 30 дней
        new_users_query = await db.execute("SELECT COUNT(*) FROM userss WHERE created_at >= datetime('now', '-30 days')")
        new_users_count = await new_users_query.fetchone()

        # Новые пользователи за последний день
        new_users_day_query = await db.execute("SELECT COUNT(*) FROM userss WHERE created_at >= datetime('now', '-1 day')")
        new_users_day_count = await new_users_day_query.fetchone()

        # Новые пользователи за последние 7 дней
        new_users_week_query = await db.execute("SELECT COUNT(*) FROM userss WHERE created_at >= datetime('now', '-7 days')")
        new_users_week_count = await new_users_week_query.fetchone()

        # Подсчёт заблокированных пользователей
        banned_users_query = await db.execute("SELECT COUNT(*) FROM userss WHERE banned = 1")
        banned_count = await banned_users_query.fetchone()

        # Подсчёт пользователей с рефералами
        users_with_referrals_query = await db.execute("SELECT COUNT(*) FROM userss WHERE referrer_id IS NOT NULL")
        referrals_count = await users_with_referrals_query.fetchone()

        # Подсчёт пользователей на пробном периоде
        trial_users_query = await db.execute("SELECT COUNT(*) FROM userss WHERE trial_continue = 1")
        trial_count = await trial_users_query.fetchone()

    # Формируем сообщение со статистикой
    stats_message = (
        f"📊 Статистика:\n\n"
        f"👥 Всего пользователей: {total_count[0]}\n"
        f"🟢 Активные подписчики: {active_count[0]}\n"
        f"🚫 Заблокированные пользователи: {banned_count[0]}\n"
        f"🔗 Пользователи с рефералами: {referrals_count[0]}\n"
        f"🆓 На пробном периоде: {trial_count[0]}\n"
        f"📈 Новые пользователи за день: {new_users_day_count[0]}\n"
        f"📈 Новые пользователи за 7 дней: {new_users_week_count[0]}\n"
        f"📆 Новые за 30 дней: {new_users_count[0]}\n"
        f"💰 Общий доход: {total_income[0] if total_income[0] else 0} RUB\n"
    )

    # Отправляем сообщение со статистикой
    await bot.send_message(m.chat.id, stats_message, parse_mode="HTML")


async def check_subscription_expiry():
    while True:
        async with aiosqlite.connect(DATABASE_NAME) as db:
            c = await db.execute("SELECT * FROM userss WHERE subscription > 0")
            users = await c.fetchall()
            for user in users:
                remaining_time = int(user['subscription']) - int(time.time())
                if 0 < remaining_time <= 3 * 86400:
                    await bot.send_message(
                        user['tgid'],
                        "Ваша подписка истекает через 3 дня! Пожалуйста, продлите её.",
                        reply_markup=await main_buttons(user,wasUpdate=True)
                    )
            await asyncio.sleep(86400)  # Запускать раз в сутки

# Функция резервного копирования базы данных
async def backup_database():
    while True:
        shutil.copy(DATABASE_NAME, f"backup_{int(time.time())}.sqlite")
        await asyncio.sleep(86400)  # Копировать раз в сутки

# История активности пользователя
async def log_user_activity(tgid):
    db = await aiosqlite.connect(DATABASE_NAME)
    await db.execute("INSERT INTO user_activity (tgid, last_access, usage_count) VALUES (?, CURRENT_TIMESTAMP, 1) ON CONFLICT(tgid) DO UPDATE SET last_access = CURRENT_TIMESTAMP, usage_count = usage_count + 1", (tgid,))
    await db.commit()
    await db.close()

# Основная функция для запуска бота и резервного копирования
async def main():
    # Сначала инициализация базы данных
    await initialize_database()
    print("База данных инициализирована.")

    # Запуск резервного копирования
    asyncio.create_task(backup_database())

    # Запуск бота
    await bot.polling(non_stop=True, interval=0, request_timeout=60)

# Запуск основного цикла
if __name__ == '__main__':
    from main import bot
    asyncio.run(main())
