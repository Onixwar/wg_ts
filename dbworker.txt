from datetime import datetime
import aiosqlite
import sqlite3
import time
import subprocess

CONFIG = {}
DATABASE_NAME = "data.sqlite"


class User:
    def __init__(self):
        self.id = None
        self.tgid = None
        self.subscription = 0
        self.trial_subscription = False
        self.registered = False
        self.referral = True
        self.username = ""
        self.fullname = ""
        self.referrer_id = None

    @classmethod
    async def GetInfo(cls, tgid):
        """Получение информации о пользователе по Telegram ID"""
        self = cls()  # Создаем экземпляр класса User
        self.tgid = tgid
        try:
            db = await aiosqlite.connect(DATABASE_NAME)
            db.row_factory = sqlite3.Row
            c = await db.execute("SELECT * FROM userss WHERE tgid = ?", (tgid,))
            log = await c.fetchone()

            if log:
                self.id = log["id"]
                self.subscription = int(log["subscription"]) if log["subscription"] else 0
                self.trial_subscription = bool(log["banned"]) if log["banned"] is not None else False
                self.registered = True
                self.referral = False
                self.username = log["username"] if log["username"] else ""
                self.fullname = log["fullname"] if log["fullname"] else ""
                self.referrer_id = int(log["referrer_id"]) if log["referrer_id"] else None
            else:
                self.registered = False
                self.referral = True

        except Exception as e:
            print(f"Ошибка при получении информации о пользователе с TG ID {tgid}: {e}")
            self.registered = False
            self.referral = True

        finally:
            if c:
                await c.close()
            if db:
                await db.close()

        return self

    async def PaymentInfo(self):
        db = await aiosqlite.connect(DATABASE_NAME)
        db.row_factory = sqlite3.Row
        c = await db.execute(f"SELECT * FROM payments where tgid=?", (self.tgid,))
        log = await c.fetchone()
        await c.close()
        await db.close()
        return log

    async def CancelPayment(self):
        db = await aiosqlite.connect(DATABASE_NAME)
        await db.execute(f"DELETE FROM payments where tgid=?",
                         (self.tgid,))
        await db.commit()

    async def NewPay(self, bill_id, summ, time_to_add, mesid):
        # pay_info = await self.PaymentInfo()
        # print(pay_info)
        # if pay_info is None:
        db = await aiosqlite.connect(DATABASE_NAME)
        await db.execute(
            f"INSERT INTO payments (tgid,bill_id,amount,time_to_add,mesid, created_at) values (?,?,?,?,?,?)",
            (self.tgid, bill_id, summ, int(time_to_add), str(mesid), datetime.fromtimestamp(time.time())))
        await db.commit()

    async def GetAllPaymentsInWork(self):
        db = await aiosqlite.connect(DATABASE_NAME)
        db.row_factory = sqlite3.Row
        c = await db.execute(f"SELECT * FROM payments")
        log = await c.fetchall()
        await c.close()
        await db.close()
        return log

    async def Adduser(self, username, full_name, referrer_id):
        """
        Функция добавляет нового пользователя в базу данных.
        Если указан `referrer_id`, новому пользователю начисляется 5 дней бесплатной подписки.
        """
        if not self.registered:
            try:
                db = await aiosqlite.connect(DATABASE_NAME)

                # Начисляем 5 дней пробного периода для нового пользователя
                trial_period_days = 5
                subscription_end = int(time.time()) + trial_period_days * 86400

                # Вставляем данные нового пользователя в таблицу userss
                await db.execute(
                    """INSERT INTO userss (tgid, subscription, username, fullname, referrer_id, registered) 
                       VALUES (?, ?, ?, ?, ?, ?)""",
                    (self.tgid, subscription_end, username or str(self.tgid), full_name or "", referrer_id, 1)
                )
                await db.commit()

                # Создаем конфигурацию VPN для нового пользователя
                subprocess.call(f'./addusertovpn.sh {str(self.tgid)}', shell=True)

                # Если есть реферер, уведомляем его о регистрации нового пользователя
                if referrer_id and referrer_id.isdigit():
                    referrer_user = await User.GetInfo(referrer_id)
                    if referrer_user and referrer_user.registered:
                        await bot.send_message(
                            referrer_user.tgid,
                            "🎉 Ваш друг зарегистрировался по вашей ссылке! Вы получите бонус после его оплаты.",
                            parse_mode="HTML",
                            reply_markup=await main_buttons(referrer_user)
                        )

                # Устанавливаем статус регистрации для пользователя
                self.registered = True

            except Exception as e:
                print(f"Ошибка при добавлении пользователя: {e}")
            finally:
                await db.close()

    async def GetAllUsers(self):
        db = await aiosqlite.connect(DATABASE_NAME)
        db.row_factory = sqlite3.Row
        c = await db.execute(f"SELECT * FROM userss")
        log = await c.fetchall()
        await c.close()
        await db.close()
        return log

    async def GetAllUsersDesc(self):
        db = await aiosqlite.connect(DATABASE_NAME)
        db.row_factory = sqlite3.Row
        c = await db.execute(f"SELECT * FROM userss order by id desc limit 50")
        log = await c.fetchall()
        await c.close()
        await db.close()
        return log

    async def GetAllUsersWithSub(self):
        db = await aiosqlite.connect(DATABASE_NAME)
        db.row_factory = sqlite3.Row
        c = await db.execute(f"SELECT * FROM userss where subscription > ? order by id desc limit 30", (str(int(time.time())),))
        log = await c.fetchall()
        await c.close()
        await db.close()
        return log

    async def GetAllUsersWithoutSub(self):
        db = await aiosqlite.connect(DATABASE_NAME)
        db.row_factory = sqlite3.Row
        c = await db.execute(f"SELECT * FROM userss where banned = true")
        log = await c.fetchall()
        await c.close()
        await db.close()
        return log

    async def CheckNewNickname(self, message):
        try:
            username = "@" + str(message.from_user.username)
        except:
            username = str(message.from_user.id)

        if message.from_user.full_name != self.fullname or username != self.username:
            db = await aiosqlite.connect(DATABASE_NAME)
            db.row_factory = sqlite3.Row
            await db.execute(f"Update userss set username = ?, fullname = ? where id = ?",
                             (username, message.from_user.full_name, self.id))
            await db.commit()

    async def countReferrerByUser(self):
        db = await aiosqlite.connect(DATABASE_NAME)
        c = await db.execute(f"select count(*) as count from userss where referrer_id=?",
                         (self.tgid,))
        log = await c.fetchone()
        await db.commit()
        return 0 if log[0] is None else log[0]

    async def addTrialForReferrer(self, referrer_id, days_to_add=7):
        if days_to_add <= 0:
            return

        # Добавляем время рефереру
        addTrialTime = days_to_add * 86400  # 1 день = 86400 секунд
        db = await aiosqlite.connect(DATABASE_NAME)

        await db.execute(
            "UPDATE userss SET subscription = subscription + ?, banned = false, trial_continue = false, notion_oneday = false WHERE tgid = ?",
            (addTrialTime, referrer_id)
        )
        await db.commit()
        await db.close()

        # Уведомляем реферера о начислении бонуса
        referrerUser = await User.GetInfo(referrer_id)
        await bot.send_message(
            referrer_id,
            f"🎉 Вам начислено {days_to_add} дней за оплату вашим рефералом!",
            reply_markup=await main_buttons(referrerUser)
        )


async def generate_admin_report():
    async with aiosqlite.connect(DATABASE_NAME) as db:
        report = ""

        # Количество зарегистрированных пользователей
        c = await db.execute("SELECT COUNT(*) FROM userss")
        total_users = await c.fetchone()
        report += f"👥 Всего пользователей: {total_users[0]}\n"

        # Количество активных подписчиков
        c = await db.execute("SELECT COUNT(*) FROM userss WHERE subscription > ?", (int(time.time()),))
        active_subscribers = await c.fetchone()
        report += f"🟢 Активные подписчики: {active_subscribers[0]}\n"

        # Количество пользователей без подписки
        c = await db.execute("SELECT COUNT(*) FROM userss WHERE subscription <= ?", (int(time.time()),))
        inactive_users = await c.fetchone()
        report += f"🔴 Пользователи без подписки: {inactive_users[0]}\n"

        # Количество заблокированных пользователей
        c = await db.execute("SELECT COUNT(*) FROM userss WHERE banned = 1")
        banned_users = await c.fetchone()
        report += f"🚫 Заблокированные пользователи: {banned_users[0]}\n"

        # Количество рефералов, которые принесли подписчиков
        c = await db.execute("SELECT COUNT(*) FROM userss WHERE referrals > 0")
        users_with_referrals = await c.fetchone()
        report += f"🔗 Пользователи с рефералами: {users_with_referrals[0]}\n"

        return report



async def payment_already_checked(payment_id):
    async with aiosqlite.connect(DATABASE_NAME) as db:
        cursor = await db.execute('SELECT bill_id FROM payments WHERE bill_id = ?', (payment_id,))
        result = await cursor.fetchone()
        await cursor.close()
        return result is not None
