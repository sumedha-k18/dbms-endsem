-- =====================================================================
-- 1(c) Spender behaviour
-- =====================================================================
\set ON_ERROR_STOP on
SET client_min_messages = warning;
\pset footer off

-- ---- 1(c)-i Revenue concentration -------------------------------------
-- Unit = person (linked devices rolled up). Revenue = net of refunds.
-- Main answer ranks PAYERS ONLY (net revenue > 0). The "all players"
-- version is shown for comparison: ~86% of people pay $0, so "top 10% of
-- everyone" already contains every payer and the shares look extreme.
\qecho '=== 1(c)-i revenue concentration ==='
WITH gross AS (
    SELECT p.person_id, SUM(pu.usd_amount) AS g
    FROM purchases pu JOIN players p USING (device_id) GROUP BY 1
),
ref AS (
    SELECT p.person_id, SUM(r.refund_usd) AS r
    FROM refunds r JOIN players p USING (device_id) GROUP BY 1
),
everyone AS (
    SELECT DISTINCT p.person_id,
           COALESCE(g.g, 0) - COALESCE(r.r, 0) AS net_rev
    FROM players p
    LEFT JOIN gross g USING (person_id)
    LEFT JOIN ref r   USING (person_id)
),
ranked AS (
    SELECT 'payers only' AS population, net_rev,
           PERCENT_RANK() OVER (ORDER BY net_rev DESC) AS pr
    FROM everyone WHERE net_rev > 0
    UNION ALL
    SELECT 'all players', net_rev,
           PERCENT_RANK() OVER (ORDER BY net_rev DESC)
    FROM everyone
)
SELECT population, COUNT(*) AS people_ranked,
       ROUND(SUM(net_rev) FILTER (WHERE pr < 0.01) / SUM(net_rev), 3) AS top_1pct_share,
       ROUND(SUM(net_rev) FILTER (WHERE pr < 0.10) / SUM(net_rev), 3) AS top_10pct_share,
       ROUND(SUM(net_rev) FILTER (WHERE pr < 0.50) / SUM(net_rev), 3) AS top_50pct_share
FROM ranked GROUP BY population ORDER BY population DESC;

-- ---- 1(c)-ii Time to first purchase ------------------------------------
-- Population: NEW installs Jan 1 - Mar 31, so everyone has >= 30 days observed.
-- Earlier installs are excluded: if they paid before Jan 1 we would see a
-- wrong, later "first" purchase.
-- 110 players have first_purchase_date one day BEFORE install_date (install
-- date logged late) -> clipped to day 0.
-- Careful: GREATEST(NULL, 0) returns 0 (GREATEST ignores NULLs), which would
-- silently turn every non-payer into a "day 0" payer - hence the CASE.
-- Horizon B repeats it for January installs (all observed >= 89 days).
\qecho '=== 1(c)-ii time to first purchase ==='
WITH base AS (
    SELECT install_date,
           CASE WHEN first_purchase_date IS NULL THEN NULL
                ELSE GREATEST(first_purchase_date - install_date, 0) END AS days_to_pay
    FROM players
    WHERE NOT is_reinstall
      AND install_date BETWEEN DATE '2026-01-01' AND DATE '2026-03-31'
),
labelled AS (
    SELECT 'A: Jan-Mar installs, first 30 days' AS horizon,
           CASE WHEN days_to_pay IS NULL OR days_to_pay > 30 THEN '7: did not pay'
                WHEN days_to_pay = 0   THEN '1: day 0'
                WHEN days_to_pay <= 3  THEN '2: day 1-3'
                WHEN days_to_pay <= 7  THEN '3: day 4-7'
                WHEN days_to_pay <= 14 THEN '4: day 8-14'
                ELSE                        '5: day 15-30' END AS bucket
    FROM base
    UNION ALL
    SELECT 'B: Jan installs, first 89 days',
           CASE WHEN days_to_pay IS NULL OR days_to_pay > 89 THEN '7: did not pay'
                WHEN days_to_pay = 0   THEN '1: day 0'
                WHEN days_to_pay <= 3  THEN '2: day 1-3'
                WHEN days_to_pay <= 7  THEN '3: day 4-7'
                WHEN days_to_pay <= 14 THEN '4: day 8-14'
                WHEN days_to_pay <= 30 THEN '5: day 15-30'
                ELSE                        '6: day 31-89' END
    FROM base WHERE install_date < DATE '2026-02-01'
)
SELECT horizon, bucket, COUNT(*) AS players,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY horizon), 2) AS pct_of_installs
FROM labelled GROUP BY 1, 2 ORDER BY 1, 2;

\qecho '=== 1(c)-ii percentiles of days-to-first-purchase, among Jan installs who paid within 89 days ==='
SELECT COUNT(*) AS payers,
       PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY d) AS p25_days,
       PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY d) AS median_days,
       PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY d) AS p75_days
FROM (SELECT GREATEST(first_purchase_date - install_date, 0) AS d
      FROM players
      WHERE NOT is_reinstall AND first_purchase_date IS NOT NULL
        AND install_date BETWEEN DATE '2026-01-01' AND DATE '2026-01-31'
        AND first_purchase_date - install_date <= 89) x;

-- ---- 1(c)-iii Repeat purchase gap ---------------------------------------
-- LAG() over each person's purchases (de-duplicated; refunds excluded).
\qecho '=== 1(c)-iii repeat purchase gap (days) ==='
WITH ordered AS (
    SELECT p.person_id, pu.event_ts,
           LAG(pu.event_ts) OVER (PARTITION BY p.person_id ORDER BY pu.event_ts) AS prev_ts
    FROM purchases pu JOIN players p USING (device_id)
),
gaps AS (
    SELECT person_id, EXTRACT(EPOCH FROM event_ts - prev_ts) / 86400.0 AS gap_days
    FROM ordered WHERE prev_ts IS NOT NULL
)
SELECT COUNT(DISTINCT person_id) AS repeat_buyers,
       COUNT(*)                  AS gaps,
       ROUND(PERCENTILE_CONT(0.10) WITHIN GROUP (ORDER BY gap_days)::NUMERIC, 1) AS p10,
       ROUND(PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY gap_days)::NUMERIC, 1) AS p25,
       ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY gap_days)::NUMERIC, 1) AS median,
       ROUND(PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY gap_days)::NUMERIC, 1) AS p75,
       ROUND(PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY gap_days)::NUMERIC, 1) AS p90,
       ROUND(AVG(gap_days)::NUMERIC, 1) AS mean
FROM gaps;

\qecho '=== 1(c)-iii gap histogram (note the bump near 15 days = the sale cycle) ==='
WITH ordered AS (
    SELECT p.person_id, pu.event_ts,
           LAG(pu.event_ts) OVER (PARTITION BY p.person_id ORDER BY pu.event_ts) AS prev_ts
    FROM purchases pu JOIN players p USING (device_id)
)
SELECT CASE WHEN g < 1 THEN '00: <1 day'
            WHEN g < 7 THEN '01: 1-6'
            WHEN g < 13 THEN '02: 7-12'
            WHEN g < 18 THEN '03: 13-17'
            WHEN g < 28 THEN '04: 18-27'
            WHEN g < 33 THEN '05: 28-32'
            WHEN g < 60 THEN '06: 33-59'
            ELSE '07: 60+' END AS gap_bucket,
       COUNT(*) AS gaps
FROM (SELECT EXTRACT(EPOCH FROM event_ts - prev_ts) / 86400.0 AS g
      FROM ordered WHERE prev_ts IS NOT NULL) x
GROUP BY 1 ORDER BY 1;
