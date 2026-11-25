-- =====================================================================
-- 1(a) Daily health, by day and platform
--   DAU          = distinct devices with an active day (player_day OR purchase)
--   gross_rev    = positive, de-duplicated purchases that day (refunds shown separately)
--   ARPDAU       = gross_rev / DAU
--   payer_share  = distinct purchasing devices / DAU
-- Numerator and denominator come from the same population (active_days
-- includes every purchaser), so payer_share can never exceed 100%.
-- =====================================================================
\set ON_ERROR_STOP on
SET client_min_messages = warning;
\pset footer off

DROP VIEW IF EXISTS v_daily_health;
CREATE VIEW v_daily_health AS
WITH dau AS (
    SELECT a.activity_date AS day, p.platform, COUNT(DISTINCT a.device_id) AS dau
    FROM active_days a JOIN players p USING (device_id)
    GROUP BY 1, 2
),
rev AS (
    SELECT pu.purchase_date AS day, p.platform,
           SUM(pu.usd_amount)           AS gross_rev,
           COUNT(DISTINCT pu.device_id) AS payers
    FROM purchases pu JOIN players p USING (device_id)
    GROUP BY 1, 2
),
ref AS (
    SELECT r.refund_date AS day, p.platform, SUM(r.refund_usd) AS refunds
    FROM refunds r JOIN players p USING (device_id)
    GROUP BY 1, 2
)
SELECT d.day, d.platform, d.dau,
       COALESCE(r.gross_rev, 0)                                AS gross_rev,
       COALESCE(f.refunds, 0)                                  AS refunds,
       COALESCE(r.gross_rev, 0) - COALESCE(f.refunds, 0)       AS net_rev,
       ROUND(COALESCE(r.gross_rev, 0) / d.dau, 4)              AS arpdau,
       COALESCE(r.payers, 0)                                   AS payers,
       ROUND(COALESCE(r.payers, 0)::NUMERIC / d.dau, 4)        AS payer_share
FROM dau d
LEFT JOIN rev r USING (day, platform)
LEFT JOIN ref f USING (day, platform);

\qecho '=== 1(a) daily health by day and platform (full table: outputs/01a_daily_health.csv) ==='
SELECT * FROM v_daily_health ORDER BY day, platform LIMIT 14;
\copy (SELECT * FROM v_daily_health ORDER BY day, platform) TO 'outputs/01a_daily_health.csv' WITH (FORMAT csv, HEADER true)

\qecho '=== 1(a) weekly roll-up (easier to read than 240 rows) ==='
SELECT DATE_TRUNC('week', day)::DATE AS week, platform,
       ROUND(AVG(dau))                                   AS avg_dau,
       SUM(gross_rev)                                    AS gross_rev,
       ROUND(SUM(gross_rev) / SUM(dau), 4)               AS arpdau,
       ROUND(SUM(payers)::NUMERIC / SUM(dau), 4)         AS payer_share
FROM v_daily_health
GROUP BY 1, 2 ORDER BY 1, 2;

\qecho '=== 1(a) whole window by platform ==='
-- avg_dau = SUM(dau) / number of days. (AVG(dau) is wrong on the ROLLUP total
-- row: it averages platform-days and gives half the real DAU.)
SELECT platform,
       ROUND(SUM(dau)::NUMERIC / COUNT(DISTINCT day)) AS avg_dau,
       SUM(gross_rev)                             AS gross_rev,
       SUM(refunds)                               AS refunds,
       ROUND(SUM(gross_rev) / SUM(dau), 4)        AS arpdau,
       ROUND(SUM(payers)::NUMERIC / SUM(dau), 4)  AS payer_share
FROM v_daily_health GROUP BY ROLLUP (platform) ORDER BY platform;

\qecho '=== 1(a) sanity checks: totals must agree with the purchases table ==='
SELECT (SELECT SUM(gross_rev) FROM v_daily_health)  AS rev_in_1a,
       (SELECT SUM(usd_amount) FROM purchases)       AS rev_in_purchases,
       (SELECT MAX(payer_share) FROM v_daily_health) AS max_payer_share,
       (SELECT COUNT(*) FROM v_daily_health)         AS rows_should_be_240;
