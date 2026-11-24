-- ============================================================================
--  Планировщик подарков — схема реляционной базы данных (SQLite)
--  Лабораторная работа 4. Моделирование данных: ER-модель и нормализация до 3NF
--
--  Файл создаёт схему «с нуля»: таблицы, ограничения целостности, индексы,
--  триггер и представления. Скрипт идемпотентен: повторный запуск удаляет
--  объекты и создаёт их заново (удобно для локальной разработки и CI).
--
--  Запуск:  sqlite3 gifts.db < database/schema.sql
--  Порядок: сначала schema.sql, затем seed_data.sql.
--
--  Модель приведена к третьей нормальной форме (обоснование каждого шага —
--  в database/normalization.md):
--    1NF — все атрибуты атомарны, списков в одной ячейке нет;
--    2NF — каждый неключевой атрибут зависит от всего первичного ключа;
--    3NF — нет транзитивных зависимостей неключевых атрибутов друг от друга.
-- ============================================================================

PRAGMA foreign_keys = ON;

-- Удаление в порядке, обратном зависимостям (для повторного запуска скрипта).
DROP VIEW  IF EXISTS v_budget_usage;
DROP VIEW  IF EXISTS v_upcoming_events;
DROP VIEW  IF EXISTS v_gift_details;
DROP TRIGGER IF EXISTS trg_gifts_updated_at;
DROP TABLE IF EXISTS reminders;
DROP TABLE IF EXISTS budgets;
DROP TABLE IF EXISTS gift_tags;
DROP TABLE IF EXISTS gifts;
DROP TABLE IF EXISTS tags;
DROP TABLE IF EXISTS categories;
DROP TABLE IF EXISTS gift_lists;
DROP TABLE IF EXISTS recipients;
DROP TABLE IF EXISTS users;

-- ----------------------------------------------------------------------------
-- 1. users — владельцы аккаунтов (все данные принадлежат пользователю)
-- ----------------------------------------------------------------------------
CREATE TABLE users (
    user_id        INTEGER PRIMARY KEY AUTOINCREMENT,
    username       TEXT    NOT NULL UNIQUE,
    email          TEXT    NOT NULL UNIQUE,
    password_hash  TEXT    NOT NULL,
    created_at     TEXT    NOT NULL DEFAULT (datetime('now')),

    CHECK (length(trim(username)) BETWEEN 2 AND 50),
    CHECK (email LIKE '%_@_%._%')
);

-- ----------------------------------------------------------------------------
-- 2. recipients — получатели подарков (для кого покупаем)
--    Дата рождения нужна для напоминаний о событиях (issue #21).
-- ----------------------------------------------------------------------------
CREATE TABLE recipients (
    recipient_id  INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id       INTEGER NOT NULL,
    name          TEXT    NOT NULL,
    relation      TEXT,
    birth_date    TEXT,
    interests     TEXT,
    notes         TEXT,
    created_at    TEXT    NOT NULL DEFAULT (datetime('now')),

    FOREIGN KEY (user_id) REFERENCES users (user_id) ON DELETE CASCADE,

    UNIQUE (user_id, name),
    CHECK (length(trim(name)) > 0),
    CHECK (relation IS NULL OR relation IN
           ('family', 'friend', 'colleague', 'partner', 'child', 'other')),
    CHECK (birth_date IS NULL OR date(birth_date) = birth_date)
);

-- ----------------------------------------------------------------------------
-- 3. gift_lists — списки подарков, привязанные к событию
--    (Новый год, день рождения, 8 марта). Заменяет «Projects» из шаблона.
-- ----------------------------------------------------------------------------
CREATE TABLE gift_lists (
    list_id      INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id      INTEGER NOT NULL,
    title        TEXT    NOT NULL,
    description  TEXT,
    event_date   TEXT,
    is_archived  INTEGER NOT NULL DEFAULT 0,
    created_at   TEXT    NOT NULL DEFAULT (datetime('now')),

    FOREIGN KEY (user_id) REFERENCES users (user_id) ON DELETE CASCADE,

    UNIQUE (user_id, title),
    CHECK (length(trim(title)) > 0),
    CHECK (is_archived IN (0, 1)),
    CHECK (event_date IS NULL OR date(event_date) = event_date)
);

-- ----------------------------------------------------------------------------
-- 4. categories — справочник категорий подарка (книги, техника, ...)
-- ----------------------------------------------------------------------------
CREATE TABLE categories (
    category_id  INTEGER PRIMARY KEY AUTOINCREMENT,
    name         TEXT    NOT NULL UNIQUE,
    description  TEXT,
    color        TEXT,
    icon         TEXT,

    CHECK (length(trim(name)) > 0),
    CHECK (color IS NULL OR color LIKE '#______')
);

-- ----------------------------------------------------------------------------
-- 5. tags — свободные метки («handmade», «до 1000 ₽», «идея»).
--    Связь с подарками — многие-ко-многим через gift_tags (см. п. 7).
-- ----------------------------------------------------------------------------
CREATE TABLE tags (
    tag_id  INTEGER PRIMARY KEY AUTOINCREMENT,
    name    TEXT    NOT NULL COLLATE NOCASE UNIQUE,
    color   TEXT,

    CHECK (length(trim(name)) > 0),
    CHECK (color IS NULL OR color LIKE '#______')
);

-- ----------------------------------------------------------------------------
-- 6. gifts — центральная сущность: конкретный подарок.
--    Денежные суммы хранятся в price, валюта — отдельным атрибутом.
--    Вычисляемые величины (остаток бюджета, счётчики) не хранятся,
--    а считаются представлениями — это требование 3NF.
-- ----------------------------------------------------------------------------
CREATE TABLE gifts (
    gift_id       INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id       INTEGER NOT NULL,
    list_id       INTEGER,
    recipient_id  INTEGER,
    category_id   INTEGER,
    title         TEXT    NOT NULL,
    description   TEXT,
    price         REAL    NOT NULL DEFAULT 0,
    currency      TEXT    NOT NULL DEFAULT 'RUB',
    status        TEXT    NOT NULL DEFAULT 'desired',
    priority      TEXT    NOT NULL DEFAULT 'medium',
    purchase_url  TEXT,
    due_date      TEXT,
    bought_at     TEXT,
    created_at    TEXT    NOT NULL DEFAULT (datetime('now')),
    updated_at    TEXT    NOT NULL DEFAULT (datetime('now')),

    FOREIGN KEY (user_id)      REFERENCES users      (user_id)      ON DELETE CASCADE,
    FOREIGN KEY (list_id)      REFERENCES gift_lists (list_id)      ON DELETE SET NULL,
    FOREIGN KEY (recipient_id) REFERENCES recipients (recipient_id) ON DELETE SET NULL,
    FOREIGN KEY (category_id)  REFERENCES categories (category_id)  ON DELETE SET NULL,

    CHECK (length(trim(title)) > 0),
    CHECK (price >= 0),
    CHECK (length(currency) = 3 AND currency = upper(currency)),
    CHECK (status   IN ('desired', 'in_cart', 'bought', 'given')),
    CHECK (priority IN ('low', 'medium', 'high')),
    CHECK (due_date  IS NULL OR date(due_date) = due_date),
    -- Дата покупки заполняется только у купленных/подаренных подарков,
    -- а статус «подарен» невозможен без даты покупки.
    CHECK (bought_at IS NULL OR status IN ('bought', 'given')),
    CHECK (status <> 'given' OR bought_at IS NOT NULL)
);

-- ----------------------------------------------------------------------------
-- 7. gift_tags — разрешение связи M:N между подарками и метками.
--    Составной первичный ключ (gift_id, tag_id) — классическое решение для
--    связи многие-ко-многим, устраняющее 1NF-нарушение «список меток в ячейке».
-- ----------------------------------------------------------------------------
CREATE TABLE gift_tags (
    gift_id  INTEGER NOT NULL,
    tag_id   INTEGER NOT NULL,
    added_at TEXT    NOT NULL DEFAULT (datetime('now')),

    PRIMARY KEY (gift_id, tag_id),
    FOREIGN KEY (gift_id) REFERENCES gifts (gift_id) ON DELETE CASCADE,
    FOREIGN KEY (tag_id)  REFERENCES tags  (tag_id)  ON DELETE CASCADE
);

-- ----------------------------------------------------------------------------
-- 8. budgets — лимит расходов на список подарков на конкретный месяц
--    ('YYYY-MM' — месяц, в котором планируются траты).
--    Фактические траты не дублируются: они агрегируются из gifts по месяцу
--    покупки (bought_at) — см. представление v_budget_usage.
-- ----------------------------------------------------------------------------
CREATE TABLE budgets (
    budget_id     INTEGER PRIMARY KEY AUTOINCREMENT,
    list_id       INTEGER NOT NULL,
    period        TEXT    NOT NULL,
    limit_amount  REAL    NOT NULL,
    currency      TEXT    NOT NULL DEFAULT 'RUB',
    created_at    TEXT    NOT NULL DEFAULT (datetime('now')),

    FOREIGN KEY (list_id) REFERENCES gift_lists (list_id) ON DELETE CASCADE,

    UNIQUE (list_id, period),
    CHECK (period GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]'
           AND substr(period, 6, 2) BETWEEN '01' AND '12'),
    CHECK (limit_amount >= 0),
    CHECK (length(currency) = 3 AND currency = upper(currency))
);

-- ----------------------------------------------------------------------------
-- 9. reminders — напоминания о событии или о конкретном подарке.
--    days_before хранит «за сколько дней» (7 / 3 / 1 / 0), remind_at —
--    точный момент отправки, is_sent/sent_at — состояние доставки.
-- ----------------------------------------------------------------------------
CREATE TABLE reminders (
    reminder_id  INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id      INTEGER NOT NULL,
    gift_id      INTEGER,
    list_id      INTEGER,
    title        TEXT    NOT NULL,
    remind_at    TEXT    NOT NULL,
    days_before  INTEGER NOT NULL DEFAULT 0,
    channel      TEXT    NOT NULL DEFAULT 'in_app',
    is_sent      INTEGER NOT NULL DEFAULT 0,
    sent_at      TEXT,
    created_at   TEXT    NOT NULL DEFAULT (datetime('now')),

    FOREIGN KEY (user_id) REFERENCES users      (user_id) ON DELETE CASCADE,
    FOREIGN KEY (gift_id) REFERENCES gifts      (gift_id) ON DELETE CASCADE,
    FOREIGN KEY (list_id) REFERENCES gift_lists (list_id) ON DELETE CASCADE,

    CHECK (length(trim(title)) > 0),
    CHECK (channel IN ('in_app', 'email')),
    CHECK (days_before >= 0),
    -- Напоминание всегда привязано хотя бы к одному объекту.
    CHECK (gift_id IS NOT NULL OR list_id IS NOT NULL),
    -- Состояние отправки согласовано: отправлено <=> есть sent_at.
    CHECK ((is_sent = 0 AND sent_at IS NULL) OR (is_sent = 1 AND sent_at IS NOT NULL))
);

-- ----------------------------------------------------------------------------
-- 10. Индексы для типовых запросов приложения
--     (список подарков пользователя, фильтры, поиск ближайших напоминаний).
--     Внешние ключи в SQLite не индексируются автоматически, поэтому
--     индексы по FK-столбцам создаются явно.
-- ----------------------------------------------------------------------------
CREATE INDEX idx_gifts_user_id       ON gifts (user_id);
CREATE INDEX idx_gifts_list_id       ON gifts (list_id);
CREATE INDEX idx_gifts_recipient_id  ON gifts (recipient_id);
CREATE INDEX idx_gifts_category_id   ON gifts (category_id);
CREATE INDEX idx_gifts_status        ON gifts (status);
CREATE INDEX idx_gifts_priority      ON gifts (priority);
CREATE INDEX idx_gifts_due_date      ON gifts (due_date);
CREATE INDEX idx_gifts_user_status   ON gifts (user_id, status);      -- составной: фильтр «мои неподаренные»

CREATE INDEX idx_recipients_user_id  ON recipients (user_id);
CREATE INDEX idx_lists_user_id       ON gift_lists (user_id);
CREATE INDEX idx_lists_event_date    ON gift_lists (event_date);

CREATE INDEX idx_gift_tags_tag_id    ON gift_tags (tag_id);           -- обратный поиск по метке
CREATE INDEX idx_reminders_user_id   ON reminders (user_id);
CREATE INDEX idx_reminders_remind_at ON reminders (remind_at, is_sent); -- планировщик рассылки
CREATE INDEX idx_budgets_list_id     ON budgets (list_id);

-- ----------------------------------------------------------------------------
-- 11. Триггер: обновление updated_at при изменении значимых полей подарка.
--     Данные не дублируются, а служебная метка времени поддерживается БД.
-- ----------------------------------------------------------------------------
CREATE TRIGGER trg_gifts_updated_at
AFTER UPDATE OF title, description, price, status, priority, due_date,
                list_id, recipient_id, category_id ON gifts
FOR EACH ROW
WHEN NEW.updated_at = OLD.updated_at
BEGIN
    UPDATE gifts
       SET updated_at = datetime('now')
     WHERE gift_id = NEW.gift_id;
END;

-- ----------------------------------------------------------------------------
-- 12. Представления (views) — «вычисляемые» данные вместо денормализации.
-- ----------------------------------------------------------------------------

-- 12.1. Подарок «одной строкой»: подарок + получатель + категория + список.
CREATE VIEW v_gift_details AS
SELECT g.gift_id,
       g.title,
       g.price,
       g.currency,
       g.status,
       g.priority,
       g.due_date,
       g.bought_at,
       r.recipient_id,
       r.name        AS recipient_name,
       c.category_id,
       c.name        AS category_name,
       l.list_id,
       l.title       AS list_title,
       l.event_date
  FROM gifts g
  LEFT JOIN recipients r ON r.recipient_id = g.recipient_id
  LEFT JOIN categories c ON c.category_id  = g.category_id
  LEFT JOIN gift_lists l ON l.list_id      = g.list_id;

-- 12.2. Исполнение бюджета: лимит, фактические траты за месяц, остаток
--       и процент использования. Никакие суммы не хранятся дважды —
--       они агрегируются из gifts по месяцу покупки.
CREATE VIEW v_budget_usage AS
SELECT u.*,
       CASE WHEN u.limit_amount > 0
            THEN ROUND(100.0 * u.spent / u.limit_amount, 1)
            ELSE NULL
       END AS percent_used
  FROM (
        SELECT b.budget_id,
               l.list_id,
               l.title AS list_title,
               b.period,
               b.limit_amount,
               b.currency,
               COALESCE(SUM(CASE WHEN g.status IN ('bought', 'given')
                                  AND substr(g.bought_at, 1, 7) = b.period
                                 THEN g.price ELSE 0 END), 0) AS spent,
               b.limit_amount - COALESCE(SUM(CASE WHEN g.status IN ('bought', 'given')
                                                   AND substr(g.bought_at, 1, 7) = b.period
                                                  THEN g.price ELSE 0 END), 0) AS remaining
          FROM budgets b
          JOIN gift_lists l ON l.list_id = b.list_id
          LEFT JOIN gifts g ON g.list_id = l.list_id
         GROUP BY b.budget_id, l.list_id, l.title, b.period, b.limit_amount, b.currency
       ) AS u;

-- 12.3. Ближайшие события (дни рождения получателей и даты списков)
--       для блока «Скоро праздник» на главном экране.
CREATE VIEW v_upcoming_events AS
SELECT 'birthday' AS event_type,
       r.user_id,
       r.recipient_id AS object_id,
       'День рождения: ' || r.name AS title,
       r.birth_date AS event_date
  FROM recipients r
 WHERE r.birth_date IS NOT NULL
UNION ALL
SELECT 'gift_list',
       l.user_id,
       l.list_id,
       l.title,
       l.event_date
  FROM gift_lists l
 WHERE l.event_date IS NOT NULL
   AND l.is_archived = 0;


