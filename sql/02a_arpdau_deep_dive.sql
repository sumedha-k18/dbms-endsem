
\set ON_ERROR_STOP on
SET client_min_messages = warning;
\pset footer off

-- player-day level table, tagged with period, reused by every query below
DROP TABLE IF EXISTS t_period_days;
CREATE TEMP TABLE t_period_days AS
SELECT a.device_id, a.activity_date,
       CASE WHEN a.activity_date <= DATE '2026-01-30' THEN '1_first_30' ELSE '2_last_30' END AS period,
       p.country_tier, p.acquisition_channel, p.platform, p.install_date,
       COALESCE(r.rev, 0) AS rev
FROM active_days a
JOIN players p USING (device_id)
LEFT JOIN (SELECT device_id, purchase_date, SUM(usd_amount) AS rev
           FROM purchases GROUP BY 1, 2) r
       ON r.device_id = a.device_id AND r.purchase_date = a.activity_date
WHERE a.activity_date BETWEEN DATE '2026-01-01' AND DATE '2026-01-30'
   OR a.activity_date BETWEEN DATE '2026-04-01' AND DATE '2026-04-30';

\qecho '=== Q0: check - are there the same number of sale days in each period? ==='
SELECT CASE WHEN purchase_date <= DATE '2026-01-30' THEN '1_first_30' ELSE '2_last_30' END AS period,
       COUNT(DISTINCT purchase_date) FILTER (WHERE n_sale > 20) AS sale_days
FROM (SELECT purchase_date, SUM(sale_flag) AS n_sale FROM purchases GROUP BY 1) s
WHERE purchase_date <= DATE '2026-01-30' OR purchase_date >= DATE '2026-04-01'
GROUP BY 1 ORDER BY 1;

\qecho '=== Q1: overall ARPDAU, and by country tier (share = share of active player-days) ==='
WITH t AS (
    SELECT period, country_tier, COUNT(*) AS player_days, SUM(rev) AS revenue
    FROM t_period_days GROUP BY 1, 2
)
SELECT period, country_tier::TEXT AS tier, player_days,
       ROUND(100.0 * player_days / SUM(player_days) OVER (PARTITION BY period), 1) AS pct_of_player_days,
       revenue, ROUND(revenue / player_days, 4) AS arpdau
FROM t
UNION ALL
SELECT period, 'ALL', SUM(player_days), 100.0, SUM(revenue), ROUND(SUM(revenue) / SUM(player_days), 4)
FROM t GROUP BY period
ORDER BY tier, period;

\qecho '=== Q2: tier-level change, and a mix vs rate decomposition ==='
-- overall ARPDAU = SUM over tiers (share_i * arpdau_i), so the change splits into
--   mix effect  = SUM (share_last - share_first) * arpdau_first   (who is playing)
--   rate effect = SUM share_last * (arpdau_last - arpdau_first)   (how much each tier spends)
WITH t AS (
    SELECT period, country_tier, COUNT(*)::NUMERIC AS n, SUM(rev) AS revenue
    FROM t_period_days GROUP BY 1, 2
),
s AS (
    SELECT period, country_tier, n / SUM(n) OVER (PARTITION BY period) AS share, revenue / n AS arpdau
    FROM t
),
w AS (
    SELECT f.country_tier,
           f.share AS share_first, l.share AS share_last,
           f.arpdau AS arpdau_first, l.arpdau AS arpdau_last
    FROM s f JOIN s l ON l.country_tier = f.country_tier
    WHERE f.period = '1_first_30' AND l.period = '2_last_30'
)
SELECT country_tier::TEXT AS tier,
       ROUND(100 * share_first, 1) AS pct_days_first, ROUND(100 * share_last, 1) AS pct_days_last,
       ROUND(arpdau_first, 4) AS arpdau_first, ROUND(arpdau_last, 4) AS arpdau_last,
       ROUND(100 * (arpdau_last / arpdau_first - 1), 1) AS arpdau_change_pct,
       ROUND((share_last - share_first) * arpdau_first, 4) AS mix_effect,
       ROUND(share_last * (arpdau_last - arpdau_first), 4) AS rate_effect
FROM w
UNION ALL
SELECT 'TOTAL', 100, 100,
       ROUND(SUM(share_first * arpdau_first), 4), ROUND(SUM(share_last * arpdau_last), 4),
       ROUND(100 * (SUM(share_last * arpdau_last) / SUM(share_first * arpdau_first) - 1), 1),
       ROUND(SUM((share_last - share_first) * arpdau_first), 4),
       ROUND(SUM(share_last * (arpdau_last - arpdau_first)), 4)
FROM w
UNION ALL
-- counterfactual: April spending rates, but January's tier mix
SELECT 'APRIL RATES @ JAN MIX', NULL, NULL,
       ROUND(SUM(share_first * arpdau_first), 4), ROUND(SUM(share_first * arpdau_last), 4),
       ROUND(100 * (SUM(share_first * arpdau_last) / SUM(share_first * arpdau_first) - 1), 1),
       NULL, NULL
FROM w
ORDER BY 1;

\qecho '=== Q3: where did the extra tier-4 players come from? new installs by month x channel ==='
SELECT DATE_TRUNC('month', install_date)::DATE AS install_month, acquisition_channel,
       COUNT(*) FILTER (WHERE country_tier = 1) AS tier1,
       COUNT(*) FILTER (WHERE country_tier = 2) AS tier2,
       COUNT(*) FILTER (WHERE country_tier = 3) AS tier3,
       COUNT(*) FILTER (WHERE country_tier = 4) AS tier4,
       COUNT(*) AS total
FROM players
WHERE install_date >= DATE '2026-01-01' AND NOT is_reinstall
GROUP BY 1, 2 ORDER BY 1, 2;

\qecho '=== Q4: is there a second mix effect inside each tier (new vs established players)? ==='
SELECT country_tier AS tier,
       CASE WHEN activity_date - install_date <= 30 THEN 'new (<=30d)' ELSE 'established' END AS player_age,
       COUNT(*) FILTER (WHERE period = '1_first_30') AS days_first,
       COUNT(*) FILTER (WHERE period = '2_last_30')  AS days_last,
       ROUND(SUM(rev) FILTER (WHERE period = '1_first_30') / COUNT(*) FILTER (WHERE period = '1_first_30'), 4) AS arpdau_first,
       ROUND(SUM(rev) FILTER (WHERE period = '2_last_30')  / COUNT(*) FILTER (WHERE period = '2_last_30'), 4)  AS arpdau_last
FROM t_period_days GROUP BY 1, 2 ORDER BY 1, 2;

\qecho '=== Q5: within tier 4, does paid_video spend less than other channels? ==='
SELECT period, acquisition_channel, COUNT(*) AS player_days, ROUND(SUM(rev) / COUNT(*), 4) AS arpdau
FROM t_period_days WHERE country_tier = 4
GROUP BY 1, 2 ORDER BY 1, 2;

\qecho '=== Q6: what the business actually cares about - total revenue per day ==='
SELECT period, COUNT(DISTINCT activity_date) AS days,
       ROUND(COUNT(*)::NUMERIC / COUNT(DISTINCT activity_date)) AS avg_dau,
       ROUND(SUM(rev) / COUNT(DISTINCT activity_date), 0) AS revenue_per_day,
       ROUND(SUM(rev) FILTER (WHERE country_tier < 4) / COUNT(DISTINCT activity_date), 0) AS rev_per_day_tier1_3,
       ROUND(SUM(rev) FILTER (WHERE country_tier = 4) / COUNT(DISTINCT activity_date), 0) AS rev_per_day_tier4
FROM t_period_days GROUP BY 1 ORDER BY 1;

\qecho '=== Q7: value of an install - gross revenue in first 30 days, Jan-Mar new installs ==='
-- Break-even: paying for a tier-4 paid_video install only makes sense if its
-- cost per install (NOT in this data) is below what it returns.
SELECT p.country_tier AS tier, p.acquisition_channel,
       COUNT(DISTINCT p.device_id) AS installs,
       ROUND(COALESCE(SUM(pu.usd_amount), 0) / COUNT(DISTINCT p.device_id), 2) AS rev_per_install_30d
FROM players p
LEFT JOIN purchases pu
       ON pu.device_id = p.device_id
      AND pu.purchase_date BETWEEN p.install_date AND p.install_date + 29
WHERE NOT p.is_reinstall AND p.install_date BETWEEN DATE '2026-01-01' AND DATE '2026-03-31'
GROUP BY ROLLUP (1, 2) ORDER BY 1, 2;

\qecho '=== Q8 (chart data): weekly ARPDAU by tier and tier-4 share, full weeks only ==='
WITH w AS (
    SELECT DATE_TRUNC('week', a.activity_date)::DATE AS week, p.country_tier,
           COUNT(*) AS n, COALESCE(SUM(r.rev), 0) AS rev
    FROM active_days a JOIN players p USING (device_id)
    LEFT JOIN (SELECT device_id, purchase_date, SUM(usd_amount) rev FROM purchases GROUP BY 1, 2) r
           ON r.device_id = a.device_id AND r.purchase_date = a.activity_date
    WHERE a.activity_date BETWEEN DATE '2026-01-05' AND DATE '2026-04-26'
    GROUP BY 1, 2
)
SELECT week,
       ROUND(SUM(rev) FILTER (WHERE country_tier = 1) / SUM(n) FILTER (WHERE country_tier = 1), 3) AS t1,
       ROUND(SUM(rev) FILTER (WHERE country_tier = 2) / SUM(n) FILTER (WHERE country_tier = 2), 3) AS t2,
       ROUND(SUM(rev) FILTER (WHERE country_tier = 3) / SUM(n) FILTER (WHERE country_tier = 3), 3) AS t3,
       ROUND(SUM(rev) FILTER (WHERE country_tier = 4) / SUM(n) FILTER (WHERE country_tier = 4), 3) AS t4,
       ROUND(SUM(rev) / SUM(n), 3) AS all_players,
       ROUND(100.0 * SUM(n) FILTER (WHERE country_tier = 4) / SUM(n), 1) AS tier4_pct_of_days
FROM w GROUP BY week ORDER BY week;
