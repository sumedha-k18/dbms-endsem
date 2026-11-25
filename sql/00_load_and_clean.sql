
\set ON_ERROR_STOP on
\timing off
SET client_min_messages = warning;

DROP TABLE IF EXISTS raw_player_profile, raw_player_day, raw_purchase,
                     raw_currency_spend, raw_ad_view CASCADE;

CREATE TABLE raw_player_profile (
    device_id            BIGINT PRIMARY KEY,
    original_device_id   BIGINT,
    install_date         DATE,
    platform             TEXT,
    country              TEXT,
    country_tier         INT,
    acquisition_channel  TEXT,
    first_purchase_date  DATE
);

CREATE TABLE raw_player_day (
    device_id         BIGINT,
    activity_date     INT,          -- stored as YYYYMMDD integer
    player_level      INT,
    session_count     INT,
    playtime_minutes  NUMERIC,
    app_version       TEXT
);

CREATE TABLE raw_purchase (
    purchase_id       TEXT,         -- NOT unique in the file (see below)
    device_id         BIGINT,
    event_ts          TIMESTAMP,
    pack_name         TEXT,
    usd_amount        NUMERIC(10,2),
    currency_granted  INT,
    sale_flag         INT
);

CREATE TABLE raw_currency_spend (
    device_id        BIGINT,
    event_ts         TIMESTAMP,
    spend_type       TEXT,
    currency_type    TEXT,
    currency_value   INT,
    spend_category   TEXT,
    player_level     INT,
    premium_balance  INT,
    social_balance   INT,
    grind_balance    INT
);

CREATE TABLE raw_ad_view (
    device_id       BIGINT,
    event_ts        TIMESTAMP,
    status          TEXT,
    placement       TEXT,
    reward_type     TEXT,
    reward_amount   INT,
    ad_daily_count  INT,
    ad_daily_cap    INT
);

\copy raw_player_profile FROM 'data/player_profile.csv' WITH (FORMAT csv, HEADER true)
\copy raw_player_day     FROM 'data/player_day.csv'     WITH (FORMAT csv, HEADER true)
\copy raw_purchase       FROM 'data/purchase.csv'       WITH (FORMAT csv, HEADER true)
\copy raw_currency_spend FROM 'data/currency_spend.csv' WITH (FORMAT csv, HEADER true)
\copy raw_ad_view        FROM 'data/ad_view.csv'        WITH (FORMAT csv, HEADER true)

-- =====================================================================
-- CLEAN TABLES
-- =====================================================================
DROP TABLE IF EXISTS players, player_day, purchases, refunds, active_days, ad_views CASCADE;

-- ---------- players ----------
-- person_id: a linked device (original_device_id not null) is the same human
--   on a new device (3,211 of them). For "per player" questions we roll the
--   device up to the original.
-- is_reinstall: these are returning players, NOT new installs, so they are
--   left out of install cohorts (1b, 1c time-to-pay, 3).
-- install_week: week 0 = Jan 1-7 2026. NULL = installed before the window.
CREATE TABLE players AS
SELECT device_id,
       COALESCE(original_device_id, device_id)            AS person_id,
       original_device_id IS NOT NULL                      AS is_reinstall,
       install_date, platform, country, country_tier, acquisition_channel,
       first_purchase_date,
       CASE WHEN install_date >= DATE '2026-01-01'
            THEN (install_date - DATE '2026-01-01') / 7 END AS install_week
FROM raw_player_profile;
ALTER TABLE players ADD PRIMARY KEY (device_id);
CREATE INDEX ON players (person_id);

-- ---------- player_day ----------
-- activity_date is an integer YYYYMMDD -> real DATE
CREATE TABLE player_day AS
SELECT device_id,
       TO_DATE(activity_date::TEXT, 'YYYYMMDD') AS activity_date,
       player_level, session_count, playtime_minutes, app_version
FROM raw_player_day;
CREATE INDEX ON player_day (device_id, activity_date);

-- ---------- purchases & refunds ----------
-- Issue: 122 purchase_ids appear twice (same device, same pack, different
--        timestamp) = one transaction logged twice ($1,841). Keep the first.
-- Issue: 228 rows have a negative amount = refunds. Kept in their own table
--        so "gross revenue" is not silently netted.
CREATE TABLE purchases AS
SELECT purchase_id, device_id, event_ts, event_ts::DATE AS purchase_date,
       pack_name, usd_amount, currency_granted, sale_flag
FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY purchase_id ORDER BY event_ts) AS rn
    FROM raw_purchase
) d
WHERE rn = 1 AND usd_amount > 0;
CREATE INDEX ON purchases (device_id, purchase_date);

CREATE TABLE refunds AS
SELECT purchase_id, device_id, event_ts, event_ts::DATE AS refund_date,
       pack_name, -usd_amount AS refund_usd, sale_flag
FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY purchase_id ORDER BY event_ts) AS rn
    FROM raw_purchase
) d
WHERE rn = 1 AND usd_amount < 0;

-- ---------- active_days ----------
-- Issue: ~2,450 purchases (mostly on sale days) come from a device with no
--        player_day row that date. You cannot buy without opening the game,
--        so a purchase counts as activity. Active day = player_day OR purchase.
--        This keeps numerator (payers) inside the denominator (DAU).
CREATE TABLE active_days AS
SELECT device_id, activity_date FROM player_day
UNION
SELECT device_id, purchase_date FROM purchases;
ALTER TABLE active_days ADD PRIMARY KEY (device_id, activity_date);
CREATE INDEX ON active_days (activity_date);

-- ---------- ad_views ----------
-- Issue: ad_view timestamps are 8 hours ahead of every other table
--        (first event 14:00 on Jan 1, last event 07:59 on May 1, and ~51% of
--        ad rows land on a day the player had no activity; after -8h, 0%).
CREATE TABLE ad_views AS
SELECT device_id,
       event_ts - INTERVAL '8 hours'           AS event_ts,
       (event_ts - INTERVAL '8 hours')::DATE   AS view_date,
       status, placement, reward_type, reward_amount, ad_daily_count, ad_daily_cap
FROM raw_ad_view;
CREATE INDEX ON ad_views (device_id, view_date);

ANALYZE;

-- ---------- load / cleaning checks ----------
\qecho '--- row counts: raw vs clean ---'
SELECT 'raw_purchase rows'        AS check_name, COUNT(*)::TEXT AS value FROM raw_purchase
UNION ALL SELECT 'distinct purchase_id',      COUNT(DISTINCT purchase_id)::TEXT FROM raw_purchase
UNION ALL SELECT 'clean purchases (positive)', COUNT(*)::TEXT FROM purchases
UNION ALL SELECT 'refunds',                   COUNT(*)::TEXT FROM refunds
UNION ALL SELECT 'gross revenue clean $',     SUM(usd_amount)::TEXT FROM purchases
UNION ALL SELECT 'gross revenue raw $ (with duplicates)', SUM(usd_amount)::TEXT FROM raw_purchase WHERE usd_amount > 0
UNION ALL SELECT 'refunds $',                 SUM(refund_usd)::TEXT FROM refunds
UNION ALL SELECT 'players',                   COUNT(*)::TEXT FROM players
UNION ALL SELECT 're-installs (linked devices)', COUNT(*) FILTER (WHERE is_reinstall)::TEXT FROM players
UNION ALL SELECT 'player_day rows',           COUNT(*)::TEXT FROM player_day
UNION ALL SELECT 'active_days rows',          COUNT(*)::TEXT FROM active_days
UNION ALL SELECT 'purchases with no player_day row', (
          SELECT COUNT(*) FROM purchases pu
          WHERE NOT EXISTS (SELECT 1 FROM player_day d
                            WHERE d.device_id = pu.device_id AND d.activity_date = pu.purchase_date))::TEXT
UNION ALL SELECT 'ad rows on an inactive day, RAW clock', (
          SELECT COUNT(*) FROM raw_ad_view a
          WHERE NOT EXISTS (SELECT 1 FROM active_days d
                            WHERE d.device_id = a.device_id AND d.activity_date = a.event_ts::DATE))::TEXT
UNION ALL SELECT 'ad rows on an inactive day, SHIFTED -8h', (
          SELECT COUNT(*) FROM ad_views a
          WHERE NOT EXISTS (SELECT 1 FROM active_days d
                            WHERE d.device_id = a.device_id AND d.activity_date = a.view_date))::TEXT
UNION ALL SELECT 'first purchase before install date', COUNT(*) FILTER (WHERE first_purchase_date < install_date)::TEXT FROM players;

\qecho '--- installs per week (install volume is NOT flat) ---'
SELECT install_week, MIN(install_date) AS week_start, COUNT(*) AS installs,
       COUNT(*) FILTER (WHERE acquisition_channel = 'paid_video') AS paid_video,
       COUNT(*) FILTER (WHERE country_tier = 4)                  AS tier4
FROM players WHERE install_week IS NOT NULL
GROUP BY install_week ORDER BY install_week;
