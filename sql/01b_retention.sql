
\set ON_ERROR_STOP on
SET client_min_messages = warning;
\pset footer off
\pset null '—'

WITH cohort AS (
    SELECT device_id, install_date, install_week
    FROM players
    WHERE install_week IS NOT NULL AND NOT is_reinstall
),
week_info AS (
    SELECT install_week, MIN(install_date) AS week_start, MAX(install_date) AS week_end,
           COUNT(*) AS cohort_size
    FROM cohort GROUP BY 1
),
flags AS (       -- one row per cohort member, 0/1 flag per milestone
    SELECT c.install_week,
           MAX(CASE WHEN a.activity_date = c.install_date + 1  THEN 1 ELSE 0 END) AS d1,
           MAX(CASE WHEN a.activity_date = c.install_date + 7  THEN 1 ELSE 0 END) AS d7,
           MAX(CASE WHEN a.activity_date = c.install_date + 14 THEN 1 ELSE 0 END) AS d14,
           MAX(CASE WHEN a.activity_date = c.install_date + 30 THEN 1 ELSE 0 END) AS d30
    FROM cohort c
    LEFT JOIN active_days a
           ON a.device_id = c.device_id
          AND a.activity_date IN (c.install_date + 1, c.install_date + 7,
                                  c.install_date + 14, c.install_date + 30)
    GROUP BY c.device_id, c.install_week
)
SELECT w.install_week AS wk, w.week_start, w.cohort_size AS installs,
       CASE WHEN w.week_end + 1  <= DATE '2026-04-30' THEN ROUND(100.0 * AVG(f.d1), 1)  END AS d1_pct,
       CASE WHEN w.week_end + 7  <= DATE '2026-04-30' THEN ROUND(100.0 * AVG(f.d7), 1)  END AS d7_pct,
       CASE WHEN w.week_end + 14 <= DATE '2026-04-30' THEN ROUND(100.0 * AVG(f.d14), 1) END AS d14_pct,
       CASE WHEN w.week_end + 30 <= DATE '2026-04-30' THEN ROUND(100.0 * AVG(f.d30), 1) END AS d30_pct
FROM week_info w JOIN flags f USING (install_week)
GROUP BY w.install_week, w.week_start, w.week_end, w.cohort_size
ORDER BY w.install_week;

\qecho '=== context: play is intermittent, so "active ON day N" is a strict measure ==='
-- share of Jan-Mar installs active on ANY day in days 1-7 vs exactly day 7
SELECT ROUND(100.0 * AVG(CASE WHEN EXISTS (SELECT 1 FROM active_days a WHERE a.device_id = p.device_id
                     AND a.activity_date BETWEEN p.install_date + 1 AND p.install_date + 7) THEN 1 ELSE 0 END), 1) AS active_any_day_1_7_pct,
       ROUND(100.0 * AVG(CASE WHEN EXISTS (SELECT 1 FROM active_days a WHERE a.device_id = p.device_id
                     AND a.activity_date = p.install_date + 7) THEN 1 ELSE 0 END), 1)                      AS active_on_day_7_pct,
       ROUND(100.0 * AVG(CASE WHEN EXISTS (SELECT 1 FROM active_days a WHERE a.device_id = p.device_id
                     AND a.activity_date = p.install_date) THEN 1 ELSE 0 END), 1)                          AS active_on_install_day_pct
FROM players p
WHERE NOT p.is_reinstall AND p.install_date BETWEEN DATE '2026-01-01' AND DATE '2026-03-31';
