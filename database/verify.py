"""Проверка схемы и тестовых данных: загрузка, инварианты, выборки."""
import sqlite3, sys, os, io
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

BASE = os.path.dirname(os.path.abspath(__file__))
schema = open(os.path.join(BASE, "schema.sql"), encoding="utf-8").read()
seed = open(os.path.join(BASE, "seed_data.sql"), encoding="utf-8").read()

db = sqlite3.connect(":memory:")
db.executescript(schema)
db.executescript(seed)

ok = True
def check(name, cond, extra=""):
    global ok
    print(("OK   " if cond else "FAIL ") + name + (" " + str(extra) if extra else ""))
    ok = ok and bool(cond)

# --- целостность ---
check("foreign_keys on", db.execute("PRAGMA foreign_keys").fetchone()[0] == 1)
check("integrity_check", db.execute("PRAGMA integrity_check").fetchone()[0] == "ok")
check("foreign_key_check", db.execute("PRAGMA foreign_key_check").fetchall() == [])

tables = [r[0] for r in db.execute(
    "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")]
print("tables:", tables)
check("9 tables", len(tables) == 9, tables)

counts = {t: db.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0] for t in tables}
print("row counts:", counts)
check("gifts = 12", counts["gifts"] == 12)
check("gift_tags >= 15", counts["gift_tags"] >= 15)

# --- нормализация: нет повторяющихся групп/дублей ---
check("no duplicate gift_tags", db.execute(
    "SELECT COUNT(*) FROM (SELECT gift_id, tag_id FROM gift_tags GROUP BY 1,2 HAVING COUNT(*) > 1)").fetchone()[0] == 0)
check("tag names unique (ascii nocase)", db.execute(
    "SELECT COUNT(*) FROM (SELECT name FROM tags GROUP BY lower(name) HAVING COUNT(*) > 1)").fetchone()[0] == 0)

# --- ограничения работают ---
def rejects(sql):
    try:
        db.execute(sql)
        return False
    except sqlite3.IntegrityError:
        return True

check("CHECK price >= 0", rejects("INSERT INTO gifts (user_id,title,price,status,priority) VALUES (1,'x',-1,'desired','low')"))
check("CHECK status enum", rejects("INSERT INTO gifts (user_id,title,status,priority) VALUES (1,'x','lost','low')"))
check("CHECK given requires bought_at", rejects("INSERT INTO gifts (user_id,title,status,priority) VALUES (1,'x','given','low')"))
check("FK user exists", rejects("INSERT INTO gifts (user_id,title,status,priority) VALUES (999,'x','desired','low')"))
check("UNIQUE users.email", rejects("INSERT INTO users (username,email,password_hash) VALUES ('new','anna@example.com','h')"))
check("UNIQUE tags.name NOCASE", rejects("INSERT INTO tags (name) VALUES ('HANDMADE')"))
check("reminder needs object", rejects(
    "INSERT INTO reminders (user_id,title,remind_at) VALUES (1,'x','2027-01-01 09:00:00')"))
check("budget period format", rejects("INSERT INTO budgets (list_id,period,limit_amount) VALUES (1,'2026/12',100)"))

# --- каскадное удаление ---
db2 = sqlite3.connect(":memory:")
db2.executescript(schema); db2.executescript(seed)
db2.execute("PRAGMA foreign_keys = ON")
db2.execute("DELETE FROM gifts WHERE gift_id = 1")
check("cascade gift_tags", db2.execute("SELECT COUNT(*) FROM gift_tags WHERE gift_id = 1").fetchone()[0] == 0)
db2.execute("DELETE FROM users WHERE user_id = 2")
check("cascade user gifts", db2.execute("SELECT COUNT(*) FROM gifts WHERE user_id = 2").fetchone()[0] == 0)

# --- триггер updated_at ---
db.execute("UPDATE gifts SET title = 'Набор керамической посуды (7 предметов)' WHERE gift_id = 1")
row = db.execute("SELECT created_at, updated_at FROM gifts WHERE gift_id = 1").fetchone()
check("trigger updated_at", row[1] >= row[0], row)

# --- представления ---
details = db.execute("SELECT * FROM v_gift_details ORDER BY gift_id LIMIT 3").fetchall()
print("v_gift_details:", details)
check("view v_gift_details rows", len(db.execute("SELECT * FROM v_gift_details").fetchall()) == 12)

usage = db.execute("SELECT list_title, period, limit_amount, spent, remaining FROM v_budget_usage ORDER BY budget_id").fetchall()
print("v_budget_usage:")
for u in usage:
    print("   ", u)
check("view budget math", all(abs(u[3] + u[4] - u[2]) < 1e-9 for u in usage))

# --- типовые запросы приложения ---
print("\n-- фильтр: мои подарки, статус desired, приоритет high --")
for r in db.execute("""SELECT g.title, r.name, c.name, g.priority
                         FROM gifts g
                         LEFT JOIN recipients r ON r.recipient_id = g.recipient_id
                         LEFT JOIN categories c ON c.category_id = g.category_id
                        WHERE g.user_id = 1 AND g.status = 'desired' AND g.priority = 'high'
                        ORDER BY g.price DESC"""):
    print("   ", r)

print("\n-- M:N: подарки с меткой 'идея' --")
for r in db.execute("""SELECT g.title, t.name
                         FROM gifts g
                         JOIN gift_tags gt ON gt.gift_id = g.gift_id
                         JOIN tags t       ON t.tag_id  = gt.tag_id
                        WHERE t.name = 'идея'"""):
    print("   ", r)

print("\n-- поиск по названию (LIKE) --")
for r in db.execute("SELECT title FROM gifts WHERE title LIKE '%набор%' COLLATE NOCASE"):
    print("   ", r[0])

print("\n-- бюджет: перерасход --")
for r in db.execute("SELECT list_title, limit_amount, spent, remaining FROM v_budget_usage WHERE remaining < 0"):
    print("   ", r)

print("\n-- напоминания к отправке --")
for r in db.execute("""SELECT title, remind_at, channel FROM reminders
                        WHERE is_sent = 0 AND remind_at >= '2026-01-01'
                        ORDER BY remind_at"""):
    print("   ", r)

print("\nRESULT:", "ALL CHECKS PASSED" if ok else "SOME CHECKS FAILED")
sys.exit(0 if ok else 1)


