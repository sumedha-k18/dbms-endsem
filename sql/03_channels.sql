
\set ON_ERROR_STOP on
SET client_min_messages = warning;
\pset footer off

DROP TABLE IF EXISTS t_installs;
CREATE TEMP TABLE t_installs AS
SELECT p.device_id, p.acquisition_channel AS channel, p.country_tier AS tier, p.platform,
       (SELECT COUNT(*) FROM active_days a
         WHERE a.device_id = p.device_id AND a.activity_date = p.install_date + 7)                         AS d7,
       (SELECT COUNT(*) FROM active_days a
         WHERE a.device_id = p.device_id AND a.activity_date BETWEEN p.install_date AND p.install_date + 29) AS days30,
       COALESCE((SELECT SUM(usd_amount) FROM purchases pu
         WHERE pu.device_id = p.device_id AND pu.purchase_date BETWEEN p.install_date AND p.install_date + 29), 0) AS rev30
FROM players p
WHERE NOT p.is_reinstall AND p.install_date BETWEEN DATE '2026-01-01' AND DATE '2026-03-31';
ALTER TABLE t_installs ADD COLUMN payer30 INT;
UPDATE t_installs SET payer30 = CASE WHEN rev30 > 0 THEN 1 ELSE 0 END;

-- long format: one row per install per metric, so one query handles all four
DROP TABLE IF EXISTS t_long;
CREATE TEMP TABLE t_long AS
SELECT channel, tier, platform, m.metric, m.val::NUMERIC AS val
FROM t_installs
CROSS JOIN LATERAL (VALUES ('1_d7', d7), ('2_days30', days30),
                           ('3_payer30', payer30), ('4_rev30', rev30)) AS m(metric, val);

\qecho '=== The "obvious" comparison: every player in the file, all revenue seen in the window ==='
SELECT p.acquisition_channel, COUNT(DISTINCT p.device_id) AS players,
       ROUND(COALESCE(SUM(pu.usd_amount), 0) / COUNT(DISTINCT p.device_id), 2) AS window_rev_per_player
FROM players p LEFT JOIN purchases pu USING (device_id)
GROUP BY 1 ORDER BY 1;

\qecho '=== Raw means per channel (new installs Jan-Mar, 30-day horizon) ==='
SELECT channel, COUNT(*) AS installs,
       ROUND(100.0 * AVG(d7), 1)      AS d7_pct,
       ROUND(AVG(days30), 2)          AS active_days_30,
       ROUND(100.0 * AVG(payer30), 1) AS payer30_pct,
       ROUND(AVG(rev30), 2)           AS rev30_usd
FROM t_installs GROUP BY ROLLUP (channel) ORDER BY channel;

\qecho '=== Why raw numbers mislead: the mix of each channel ==='
SELECT channel,
       ROUND(100.0 * AVG(CASE WHEN tier = 1 THEN 1 ELSE 0 END), 1) AS pct_tier1,
       ROUND(100.0 * AVG(CASE WHEN tier = 2 THEN 1 ELSE 0 END), 1) AS pct_tier2,
       ROUND(100.0 * AVG(CASE WHEN tier = 3 THEN 1 ELSE 0 END), 1) AS pct_tier3,
       ROUND(100.0 * AVG(CASE WHEN tier = 4 THEN 1 ELSE 0 END), 1) AS pct_tier4,
       ROUND(100.0 * AVG(CASE WHEN platform = 'iOS' THEN 1 ELSE 0 END), 1) AS pct_ios
FROM t_installs GROUP BY channel ORDER BY channel;

\qecho '=== Within-tier means: D7 % and 30-day revenue per install ==='
SELECT tier,
       ROUND(100.0 * AVG(d7) FILTER (WHERE channel = 'organic'), 1)     AS d7_organic,
       ROUND(100.0 * AVG(d7) FILTER (WHERE channel = 'paid_social'), 1) AS d7_social,
       ROUND(100.0 * AVG(d7) FILTER (WHERE channel = 'paid_video'), 1)  AS d7_video,
       ROUND(AVG(rev30) FILTER (WHERE channel = 'organic'), 2)          AS rev_organic,
       ROUND(AVG(rev30) FILTER (WHERE channel = 'paid_social'), 2)      AS rev_social,
       ROUND(AVG(rev30) FILTER (WHERE channel = 'paid_video'), 2)       AS rev_video
FROM t_installs GROUP BY tier ORDER BY tier;

\qecho '=== Differences with 95% CIs: raw vs adjusted (tier x platform strata) ==='
WITH pairs(comparison, a_ch, b_ch) AS (
    VALUES ('paid_social - organic',    'paid_social', 'organic'),
           ('paid_video - organic',     'paid_video',  'organic'),
           ('paid_video - paid_social', 'paid_video',  'paid_social')
),
-- raw (pooled) statistics per channel
pooled AS (
    SELECT metric, channel, COUNT(*) AS n, AVG(val) AS mean, VAR_SAMP(val) AS var
    FROM t_long GROUP BY 1, 2
),
raw AS (
    SELECT pr.comparison, a.metric, b.mean AS base_mean,
           a.mean - b.mean AS diff,
           SQRT(a.var / a.n + b.var / b.n) AS se
    FROM pairs pr
    JOIN pooled a ON a.channel = pr.a_ch
    JOIN pooled b ON b.channel = pr.b_ch AND b.metric = a.metric
),
-- stratified statistics
strat AS (
    SELECT metric, tier, platform, channel, COUNT(*) AS n, AVG(val) AS mean,
           COALESCE(VAR_SAMP(val), 0) AS var
    FROM t_long GROUP BY 1, 2, 3, 4
),
weights AS (   -- stratum share of ALL installs (same weights for every comparison)
    SELECT tier, platform, COUNT(*)::NUMERIC / SUM(COUNT(*)) OVER () AS w
    FROM t_installs GROUP BY 1, 2
),
adj AS (
    SELECT pr.comparison, a.metric,
           SUM(w.w * (a.mean - b.mean))                   AS diff,
           SQRT(SUM(w.w * w.w * (a.var / a.n + b.var / b.n))) AS se
    FROM pairs pr
    JOIN strat a ON a.channel = pr.a_ch
    JOIN strat b ON b.channel = pr.b_ch AND b.metric = a.metric
                AND b.tier = a.tier AND b.platform = a.platform
    JOIN weights w ON w.tier = a.tier AND w.platform = a.platform
    GROUP BY 1, 2
)
SELECT r.metric, r.comparison,
       ROUND(r.base_mean, 4)                                 AS baseline,
       ROUND(r.diff, 4)                                      AS raw_diff,
       '[' || ROUND(r.diff - 1.96 * r.se, 4) || ', ' || ROUND(r.diff + 1.96 * r.se, 4) || ']' AS raw_95ci,
       ROUND(j.diff, 4)                                      AS adj_diff,
       '[' || ROUND(j.diff - 1.96 * j.se, 4) || ', ' || ROUND(j.diff + 1.96 * j.se, 4) || ']' AS adj_95ci,
       ROUND(100 * j.diff / r.base_mean, 1)                  AS adj_diff_pct,
       ROUND(j.diff / j.se, 2)                               AS z,
       CASE WHEN ABS(j.diff / j.se) > 1.96 THEN 'yes' ELSE 'no' END AS signif_5pct,
       ROUND(2.8 * j.se, 4)                                  AS mde_80pct_power
FROM raw r JOIN adj j USING (comparison, metric)
ORDER BY r.metric, r.comparison;

\qecho '=== Why revenue is so noisy: share of 30-day revenue from the top 1% of installs ==='
SELECT ROUND(SUM(rev30) FILTER (WHERE rk <= n / 100) / SUM(rev30), 3) AS top1pct_share
FROM (SELECT rev30, ROW_NUMBER() OVER (ORDER BY rev30 DESC) AS rk, COUNT(*) OVER () AS n FROM t_installs) x;

\qecho '=== Re-installs by channel (they are excluded above, but attribution credits them as new) ==='
SELECT acquisition_channel,
       COUNT(*) FILTER (WHERE is_reinstall) AS reinstalls,
       ROUND(100.0 * AVG(CASE WHEN is_reinstall THEN 1 ELSE 0 END), 1) AS pct_of_installs
FROM players WHERE install_date >= DATE '2026-01-01'
GROUP BY 1 ORDER BY 1;
