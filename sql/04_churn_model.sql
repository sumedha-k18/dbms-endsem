-- =====================================================================
-- 4. Predict which currently-active players will stop playing for the
--    next 14 days - built and evaluated entirely in SQL.
--
-- SETUP
--   Unit       : a PERSON (linked re-install devices rolled up to the
--                original), otherwise a player who changed phone looks
--                like a churner on the old device.
--   As of      : weekly snapshot dates t.
--   Who        : people active at least once in [t-6, t] ("currently
--                active") AND installed at least 7 days before t.
--                Excluded: brand-new players (< 7 days) - their churn is an
--                onboarding problem, solved by the tutorial, not an offer.
--   Label      : churned = 1 if NO active day in [t+1, t+14].
--   Features   : only data on or before t.
--
-- SPLIT (out-of-time, because the model will be used on FUTURE weeks and the
-- player mix is changing fast):
--   train : t = Jan 29 ... Mar 19 (8 weekly snapshots, labels end Apr 2)
--   valid : t = Apr 2  (labels Apr 3-16)  - used to choose the smoothing
--   test  : t = Apr 16 (labels Apr 17-30) - touched once, reported
--   No label window of train overlaps valid/test.
--
-- MODEL: a smoothed "risk table" (a scorecard). Churn rate is learned on
-- train for every cell of recency x frequency x tenure x payer x trend
-- (4 x 4 x 3 x 2 x 3 = 288 cells), shrunk towards the recency x frequency
-- rate when the cell is small:
--     score = (churners_cell + K * rate_parent) / (n_cell + K)
-- K is chosen on the VALID snapshot (section 4a): K = 5 and K = 25 tie
-- (AUC 0.6873 vs 0.6871); K = 25 is used because it is less jumpy on small cells.
-- It is the SQL equivalent of a logistic regression with interactions on
-- bucketed features, and every number in it can be read off a table.
-- =====================================================================
\set ON_ERROR_STOP on
SET client_min_messages = warning;
\pset footer off
\pset null '—'

-- ---------------------------------------------------------------------
-- 0. WHY 14 DAYS? Look at the data before picking a definition.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS p_active;
CREATE TEMP TABLE p_active AS
SELECT DISTINCT p.person_id, a.activity_date AS d
FROM active_days a JOIN players p USING (device_id);
CREATE INDEX ON p_active (person_id, d);
ANALYZE p_active;

\qecho '=== 0a. gaps between consecutive active days ==='
SELECT PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY gap) AS p50,
       PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY gap) AS p75,
       PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY gap) AS p90,
       PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY gap) AS p95,
       ROUND(100.0 * AVG(CASE WHEN gap > 14 THEN 1 ELSE 0 END), 1) AS pct_gaps_over_14
FROM (SELECT d - LAG(d) OVER (PARTITION BY person_id ORDER BY d) AS gap FROM p_active) g
WHERE gap IS NOT NULL;

\qecho '=== 0b. players active in the week before t who then go quiet k days: how many come back? ==='
WITH snaps(t) AS (VALUES (DATE '2026-01-25'), (DATE '2026-02-08')),
ks(k) AS (VALUES (7), (14), (21), (28)),
act AS (SELECT DISTINCT s.t, a.person_id FROM snaps s JOIN p_active a ON a.d BETWEEN s.t - 6 AND s.t)
SELECT k AS quiet_days, COUNT(*) AS players,
       ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM act), 1) AS pct_of_active,
       ROUND(100.0 * AVG(CASE WHEN EXISTS (SELECT 1 FROM p_active a WHERE a.person_id = act.person_id
                     AND a.d BETWEEN act.t + k + 1 AND act.t + k + 30) THEN 1 ELSE 0 END), 1) AS pct_back_within_30d
FROM act CROSS JOIN ks
WHERE NOT EXISTS (SELECT 1 FROM p_active a WHERE a.person_id = act.person_id AND a.d BETWEEN act.t + 1 AND act.t + k)
GROUP BY k ORDER BY k;

-- ---------------------------------------------------------------------
-- 1. Feature + label table
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS p_play;
CREATE TEMP TABLE p_play AS
SELECT p.person_id, d.activity_date AS d, SUM(d.session_count) AS sessions,
       SUM(d.playtime_minutes) AS playtime, MAX(d.player_level) AS lvl
FROM player_day d JOIN players p USING (device_id) GROUP BY 1, 2;
CREATE INDEX ON p_play (person_id, d);

DROP TABLE IF EXISTS p_pay;
CREATE TEMP TABLE p_pay AS
SELECT p.person_id, pu.purchase_date AS d, SUM(pu.usd_amount) AS rev
FROM purchases pu JOIN players p USING (device_id) GROUP BY 1, 2;
CREATE INDEX ON p_pay (person_id, d);

DROP TABLE IF EXISTS person;
CREATE TEMP TABLE person AS
SELECT device_id AS person_id, install_date, platform, country_tier, acquisition_channel
FROM players WHERE device_id IN (SELECT person_id FROM players);
ANALYZE p_play; ANALYZE p_pay; ANALYZE person;

DROP TABLE IF EXISTS churn_data;
CREATE TABLE churn_data AS
WITH snaps(t, split) AS (
    SELECT d::DATE, 'train' FROM GENERATE_SERIES(DATE '2026-01-29', DATE '2026-03-19', INTERVAL '7 days') d
    UNION ALL VALUES (DATE '2026-04-02', 'valid'), (DATE '2026-04-16', 'test')
),
scored AS (
    SELECT s.t, s.split, pr.*
    FROM snaps s JOIN person pr ON pr.install_date <= s.t - 7
    WHERE EXISTS (SELECT 1 FROM p_active a WHERE a.person_id = pr.person_id AND a.d BETWEEN s.t - 6 AND s.t)
),
act AS (
    SELECT s.t, s.person_id,
           s.t - MAX(a.d) FILTER (WHERE a.d <= s.t)                          AS days_since_last,
           COUNT(*) FILTER (WHERE a.d BETWEEN s.t - 6  AND s.t)              AS active_7,
           COUNT(*) FILTER (WHERE a.d BETWEEN s.t - 13 AND s.t - 7)          AS active_prev_7,
           COUNT(*) FILTER (WHERE a.d BETWEEN s.t - 27 AND s.t)              AS active_28,
           COUNT(*) FILTER (WHERE a.d BETWEEN s.t + 1  AND s.t + 14)         AS active_next_14
    FROM scored s JOIN p_active a ON a.person_id = s.person_id AND a.d BETWEEN s.t - 27 AND s.t + 14
    GROUP BY 1, 2
),
play AS (
    SELECT s.t, s.person_id,
           COALESCE(SUM(pp.sessions) FILTER (WHERE pp.d > s.t - 7), 0) AS sessions_7,
           COALESCE(SUM(pp.playtime) FILTER (WHERE pp.d > s.t - 7), 0) AS playtime_7,
           MAX(pp.lvl) AS level_now
    FROM scored s LEFT JOIN p_play pp ON pp.person_id = s.person_id AND pp.d BETWEEN s.t - 27 AND s.t
    GROUP BY 1, 2
),
pay AS (
    SELECT s.t, s.person_id,
           COUNT(pp.d) > 0                                            AS paid_before,
           COALESCE(SUM(pp.rev) FILTER (WHERE pp.d > s.t - 28), 0)    AS rev_28
    FROM scored s LEFT JOIN p_pay pp ON pp.person_id = s.person_id AND pp.d <= s.t
    GROUP BY 1, 2
)
SELECT s.t AS snapshot, s.split, s.person_id, s.platform, s.country_tier, s.acquisition_channel,
       s.t - s.install_date AS tenure_days,
       a.days_since_last, a.active_7, a.active_prev_7, a.active_28,
       pl.sessions_7, pl.playtime_7, pl.level_now,
       py.paid_before, py.rev_28,
       CASE WHEN a.active_next_14 = 0 THEN 1 ELSE 0 END AS churned,
       -- buckets used by the model
       CASE WHEN a.days_since_last = 0 THEN 'R0: today'
            WHEN a.days_since_last = 1 THEN 'R1: 1 day'
            WHEN a.days_since_last <= 3 THEN 'R2: 2-3 days'
            ELSE 'R3: 4-6 days' END                              AS b_recency,
       CASE WHEN a.active_28 <= 2  THEN 'F1: 1-2'
            WHEN a.active_28 <= 5  THEN 'F2: 3-5'
            WHEN a.active_28 <= 10 THEN 'F3: 6-10'
            ELSE 'F4: 11+' END                                   AS b_frequency,
       CASE WHEN s.t - s.install_date <= 30 THEN 'T1: 7-30d'
            WHEN s.t - s.install_date <= 90 THEN 'T2: 31-90d'
            ELSE 'T3: 90d+' END                                  AS b_tenure,
       CASE WHEN py.paid_before THEN 'payer' ELSE 'non-payer' END AS b_payer,
       CASE WHEN a.active_7 > a.active_prev_7 THEN 'up'
            WHEN a.active_7 = a.active_prev_7 THEN 'flat' ELSE 'down' END AS b_trend
FROM scored s
JOIN act  a  ON a.t  = s.t AND a.person_id  = s.person_id
JOIN play pl ON pl.t = s.t AND pl.person_id = s.person_id
JOIN pay  py ON py.t = s.t AND py.person_id = s.person_id;

\qecho '=== 1. rows and churn rate per snapshot ==='
SELECT split, snapshot, COUNT(*) AS players, ROUND(100.0 * AVG(churned), 1) AS churn_pct
FROM churn_data GROUP BY 1, 2 ORDER BY 2;

-- ---------------------------------------------------------------------
-- 2. What predicts churn? (train only) - one feature at a time
-- ---------------------------------------------------------------------
\qecho '=== 2. churn rate by each feature bucket (TRAIN) ==='
SELECT 'recency' AS feature, b_recency AS bucket, COUNT(*) AS n, ROUND(100.0 * AVG(churned), 1) AS churn_pct FROM churn_data WHERE split = 'train' GROUP BY 1, 2
UNION ALL SELECT 'frequency (active days in last 28)', b_frequency, COUNT(*), ROUND(100.0 * AVG(churned), 1) FROM churn_data WHERE split = 'train' GROUP BY 1, 2
UNION ALL SELECT 'tenure', b_tenure, COUNT(*), ROUND(100.0 * AVG(churned), 1) FROM churn_data WHERE split = 'train' GROUP BY 1, 2
UNION ALL SELECT 'payer', b_payer, COUNT(*), ROUND(100.0 * AVG(churned), 1) FROM churn_data WHERE split = 'train' GROUP BY 1, 2
UNION ALL SELECT 'trend (last 7 vs prior 7)',
                 CASE WHEN active_7 > active_prev_7 THEN 'up' WHEN active_7 = active_prev_7 THEN 'flat' ELSE 'down' END,
                 COUNT(*), ROUND(100.0 * AVG(churned), 1) FROM churn_data WHERE split = 'train' GROUP BY 1, 2
UNION ALL SELECT 'country tier', country_tier::TEXT, COUNT(*), ROUND(100.0 * AVG(churned), 1) FROM churn_data WHERE split = 'train' GROUP BY 1, 2
UNION ALL SELECT 'channel', acquisition_channel, COUNT(*), ROUND(100.0 * AVG(churned), 1) FROM churn_data WHERE split = 'train' GROUP BY 1, 2
UNION ALL SELECT 'platform', platform, COUNT(*), ROUND(100.0 * AVG(churned), 1) FROM churn_data WHERE split = 'train' GROUP BY 1, 2
ORDER BY 1, 2;

\qecho '=== 2b. recency x frequency grid, churn % (TRAIN) - the core of the model ==='
SELECT b_recency,
       ROUND(100.0 * AVG(churned) FILTER (WHERE b_frequency = 'F1: 1-2'), 1)  AS "F1: 1-2",
       ROUND(100.0 * AVG(churned) FILTER (WHERE b_frequency = 'F2: 3-5'), 1)  AS "F2: 3-5",
       ROUND(100.0 * AVG(churned) FILTER (WHERE b_frequency = 'F3: 6-10'), 1) AS "F3: 6-10",
       ROUND(100.0 * AVG(churned) FILTER (WHERE b_frequency = 'F4: 11+'), 1)  AS "F4: 11+"
FROM churn_data WHERE split = 'train' GROUP BY 1 ORDER BY 1;

-- ---------------------------------------------------------------------
-- 3. Fit the risk table on TRAIN, score every row
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS risk_parent, risk_cell;
CREATE TABLE risk_parent AS
SELECT b_recency, b_frequency, COUNT(*) AS n, AVG(churned) AS rate
FROM churn_data WHERE split = 'train' GROUP BY 1, 2;

CREATE TABLE risk_cell AS
SELECT b_recency, b_frequency, b_tenure, b_payer, b_trend, COUNT(*) AS n, SUM(churned) AS churners
FROM churn_data WHERE split = 'train' GROUP BY 1, 2, 3, 4, 5;

-- scores for several smoothing strengths K; K is chosen on VALID
DROP TABLE IF EXISTS scores;
CREATE TABLE scores AS
SELECT d.snapshot, d.split, d.person_id, d.churned, k.k,
       (COALESCE(c.churners, 0) + k.k * p.rate) / (COALESCE(c.n, 0) + k.k) AS score,
       d.days_since_last
FROM churn_data d
CROSS JOIN (VALUES (5), (25), (100), (400), (100000)) AS k(k)
JOIN risk_parent p USING (b_recency, b_frequency)
LEFT JOIN risk_cell c USING (b_recency, b_frequency, b_tenure, b_payer, b_trend);

-- ---------------------------------------------------------------------
-- 4. Evaluation
-- AUC (prob. a random churner is ranked above a random stayer) from ranks:
--   AUC = (sum of ranks of churners - n1(n1+1)/2) / (n1 * n0), ties get the average rank.
-- Instead of PR-AUC we report precision / recall at fixed targeting depths
-- (section 6), which is what live-ops will actually use.
-- Brier = mean squared error of the probability (lower is better).
-- ---------------------------------------------------------------------
\qecho '=== 4a. choose K on VALID (K = 100000 means "recency x frequency only") ==='
WITH r AS (
    SELECT k, churned,
           RANK() OVER (PARTITION BY k ORDER BY score)
             + (COUNT(*) OVER (PARTITION BY k, score) - 1) / 2.0 AS rnk
    FROM scores WHERE split = 'valid'
)
SELECT k,
       ROUND((SUM(rnk) FILTER (WHERE churned = 1)
              - SUM(churned)::NUMERIC * (SUM(churned) + 1) / 2)
             / (SUM(churned)::NUMERIC * SUM(1 - churned)), 4) AS auc_valid
FROM r GROUP BY k ORDER BY k;

\qecho '=== 4b. model (K=25) vs a one-line baseline rule, on every split ==='
-- baseline = "rank by days since last active" (what live-ops would do without a model)
WITH both_models AS (
    SELECT split, 'risk table (K=25)' AS model, churned, score FROM scores WHERE k = 25
    UNION ALL
    SELECT split, 'baseline: days since last active', churned, days_since_last::NUMERIC FROM scores WHERE k = 25
),
r AS (
    SELECT split, model, churned, score,
           RANK() OVER (PARTITION BY split, model ORDER BY score)
             + (COUNT(*) OVER (PARTITION BY split, model, score) - 1) / 2.0 AS rnk
    FROM both_models
)
SELECT split, model, COUNT(*) AS rows, ROUND(100.0 * AVG(churned), 1) AS churn_pct,
       ROUND((SUM(rnk) FILTER (WHERE churned = 1) - SUM(churned)::NUMERIC * (SUM(churned) + 1) / 2)
             / (SUM(churned)::NUMERIC * SUM(1 - churned)), 4) AS auc,
       CASE WHEN model LIKE 'risk%' THEN ROUND(AVG((score - churned) ^ 2), 4) END AS brier,
       CASE WHEN model LIKE 'risk%' THEN ROUND(AVG(churned) * (1 - AVG(churned)), 4) END AS brier_if_predict_base_rate
FROM r GROUP BY split, model ORDER BY split DESC, model DESC;

\qecho '=== 4c. calibration on TEST: predicted vs actual churn by risk decile ==='
SELECT decile, COUNT(*) AS players,
       ROUND(100.0 * AVG(score), 1)   AS predicted_pct,
       ROUND(100.0 * AVG(churned), 1) AS actual_pct
FROM (SELECT *, NTILE(10) OVER (ORDER BY score) AS decile FROM scores WHERE split = 'test' AND k = 25) x
GROUP BY decile ORDER BY decile;

-- ---------------------------------------------------------------------
-- 5. Where does it work badly? AUC by segment on TEST
-- ---------------------------------------------------------------------
\qecho '=== 5. TEST performance by segment ==='
WITH t AS (
    SELECT s.score, d.churned, d.country_tier, d.acquisition_channel, d.platform,
           d.b_tenure, d.b_payer, d.b_recency
    FROM scores s JOIN churn_data d USING (snapshot, person_id)
    WHERE s.split = 'test' AND s.k = 25
),
seg AS (
    SELECT 'country tier' AS segment, country_tier::TEXT AS value, score, churned FROM t
    UNION ALL SELECT 'channel', acquisition_channel, score, churned FROM t
    UNION ALL SELECT 'platform', platform, score, churned FROM t
    UNION ALL SELECT 'tenure', b_tenure, score, churned FROM t
    UNION ALL SELECT 'payer', b_payer, score, churned FROM t
    UNION ALL SELECT 'recency', b_recency, score, churned FROM t
),
r AS (
    SELECT segment, value, score, churned,
           RANK() OVER (PARTITION BY segment, value ORDER BY score)
             + (COUNT(*) OVER (PARTITION BY segment, value, score) - 1) / 2.0 AS rnk
    FROM seg
)
SELECT segment, value, COUNT(*) AS players,
       ROUND(100.0 * AVG(churned), 1) AS actual_pct,
       ROUND(100.0 * AVG(score), 1)   AS predicted_pct,
       ROUND((SUM(rnk) FILTER (WHERE churned = 1) - SUM(churned)::NUMERIC * (SUM(churned) + 1) / 2)
             / NULLIF(SUM(churned)::NUMERIC * SUM(1 - churned), 0), 3) AS auc
FROM r GROUP BY segment, value ORDER BY segment, value;

-- ---------------------------------------------------------------------
-- 6. USE: how deep to target, and when it pays.
-- An offer pays for itself on the targeted group if
--     (#churners targeted) * u * V  >  (#offers) * c
-- i.e.  V / c  >  1 / (precision * u)
--   V = value of keeping a player who would have churned (NOT in the data)
--   c = cost of one offer (NOT in the data)
--   u = share of targeted churners the offer actually saves (NOT in the
--       data - needs a holdout test). Shown for u = 10% and 25%.
-- Wasted offers = offers sent to players who would have stayed anyway.
-- ---------------------------------------------------------------------
\qecho '=== 6. targeting policies on the TEST snapshot (Apr 16) ==='
WITH t AS (
    SELECT score, churned,
           ROW_NUMBER() OVER (ORDER BY score DESC, person_id) AS rk,
           COUNT(*) OVER () AS n, SUM(churned) OVER () AS all_churners
    FROM scores WHERE split = 'test' AND k = 25
),
depth(pct) AS (VALUES (5), (10), (20), (30), (50), (100))
SELECT d.pct AS target_top_pct,
       COUNT(*)                                  AS offers,
       ROUND(MIN(t.score), 3)                    AS score_threshold,
       ROUND(100.0 * AVG(t.churned), 1)          AS precision_pct,
       ROUND(100.0 * SUM(t.churned) / MAX(t.all_churners), 1) AS recall_pct,
       COUNT(*) - SUM(t.churned)                 AS wasted_offers,
       ROUND(1 / (AVG(t.churned) * 0.10), 1)     AS breakeven_v_over_c_u10,
       ROUND(1 / (AVG(t.churned) * 0.25), 1)     AS breakeven_v_over_c_u25
FROM depth d JOIN t ON t.rk <= t.n * d.pct / 100.0
GROUP BY d.pct ORDER BY d.pct;

\qecho '=== 6b. the risk table itself (top 15 riskiest cells, TRAIN) ==='
SELECT b_recency, b_frequency, b_tenure, b_payer, b_trend, n,
       ROUND(100.0 * churners / n, 1) AS churn_pct
FROM risk_cell WHERE n >= 200 ORDER BY churners::NUMERIC / n DESC LIMIT 15;
