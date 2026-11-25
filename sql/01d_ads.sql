
\set ON_ERROR_STOP on
SET client_min_messages = warning;
\pset footer off

\qecho '=== check: count=1 rows vs ad player-days, and one cap per player-day? ==='
SELECT (SELECT COUNT(*) FROM ad_views WHERE ad_daily_count = 1)                 AS rows_with_count_1,
       (SELECT COUNT(*) FROM (SELECT DISTINCT device_id, view_date FROM ad_views) x) AS ad_player_days,
       (SELECT COUNT(*) FROM (SELECT device_id, view_date FROM ad_views GROUP BY 1, 2
                              HAVING COUNT(DISTINCT ad_daily_cap) > 1) x)        AS days_with_two_caps,
       (SELECT ROUND(AVG(CASE WHEN n > 1 THEN 1.0 ELSE 0 END), 3)
          FROM (SELECT device_id, COUNT(DISTINCT ad_daily_cap) n FROM ad_views GROUP BY 1) x) AS share_players_seeing_both_caps;

\qecho '=== 1(d)-i share of ad-watching player-days that hit the cap, by cap ==='
WITH pdays AS (
    SELECT device_id, view_date,
           MAX(ad_daily_cap)                            AS cap,
           MAX(ad_daily_count)                          AS max_count,
           COUNT(*) FILTER (WHERE status = 'completed') AS completed
    FROM ad_views GROUP BY 1, 2
)
SELECT cap,
       COUNT(*)                                                         AS ad_player_days,
       ROUND(100.0 * AVG(CASE WHEN max_count >= cap THEN 1 ELSE 0 END), 2) AS pct_hit_cap,
       ROUND(100.0 * AVG(CASE WHEN completed >= cap THEN 1 ELSE 0 END), 2) AS pct_hit_cap_completed_only,
       ROUND(AVG(completed), 3)                                         AS avg_completed_views,
       ROUND(100.0 * AVG(CASE WHEN completed >= 3 THEN 1 ELSE 0 END), 2)   AS pct_3plus_views
FROM pdays GROUP BY ROLLUP (cap) ORDER BY cap;

\qecho '=== 1(d)-ii completed ad views per day (full table: outputs/01d_daily_ad_views.csv) ==='
DROP VIEW IF EXISTS v_daily_ads;
CREATE VIEW v_daily_ads AS
WITH cal AS (
    SELECT d::DATE AS day FROM GENERATE_SERIES(DATE '2026-01-01', DATE '2026-04-30', INTERVAL '1 day') d
),
v AS (
    SELECT view_date AS day,
           COUNT(*) FILTER (WHERE status = 'completed') AS completed_views,
           COUNT(DISTINCT device_id)                     AS watchers
    FROM ad_views GROUP BY 1
),
d AS (SELECT activity_date AS day, COUNT(*) AS dau FROM active_days GROUP BY 1)
SELECT cal.day, d.dau,
       COALESCE(v.completed_views, 0)                            AS completed_views,
       ROUND(COALESCE(v.completed_views, 0)::NUMERIC / d.dau, 3) AS views_per_dau
FROM cal LEFT JOIN v USING (day) LEFT JOIN d USING (day);
\copy (SELECT * FROM v_daily_ads ORDER BY day) TO 'outputs/01d_daily_ad_views.csv' WITH (FORMAT csv, HEADER true)

-- a text "bar chart": one # per 250 views
SELECT day, dau, completed_views, views_per_dau,
       REPEAT('#', (completed_views / 250)::INT) AS bar
FROM v_daily_ads
WHERE day BETWEEN DATE '2026-02-25' AND DATE '2026-03-15'
   OR EXTRACT(DAY FROM day) = 1
ORDER BY day;

\qecho '=== anomaly finder: days whose views per DAU are < 60% of the surrounding week ==='
SELECT day, dau, completed_views, views_per_dau, ROUND(avg7, 3) AS centred_7day_avg
FROM (SELECT day, dau, completed_views, views_per_dau,
             AVG(views_per_dau) OVER (ORDER BY day ROWS BETWEEN 3 PRECEDING AND 3 FOLLOWING) AS avg7
      FROM v_daily_ads) s
WHERE views_per_dau < 0.6 * avg7
ORDER BY day;

\qecho '=== exact edges of the gap (hourly, on the corrected clock) ==='
SELECT DATE_TRUNC('hour', event_ts) AS hour, COUNT(*) AS rows
FROM ad_views
WHERE event_ts BETWEEN TIMESTAMP '2026-03-04 20:00' AND TIMESTAMP '2026-03-07 09:00'
GROUP BY 1 ORDER BY 1;

\qecho '=== views per DAU by month, excluding the gap days (is engagement drifting?) ==='
SELECT DATE_TRUNC('month', day)::DATE AS month,
       ROUND(SUM(completed_views)::NUMERIC / SUM(dau), 3) AS views_per_dau
FROM v_daily_ads WHERE day NOT IN (DATE '2026-03-05', DATE '2026-03-06')
GROUP BY 1 ORDER BY 1;
