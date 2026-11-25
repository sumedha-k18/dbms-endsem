
\set ON_ERROR_STOP on
\o outputs/00_load_and_clean.txt
\i sql/00_load_and_clean.sql
\o outputs/01a_daily_health.txt
\i sql/01a_daily_health.sql
\o outputs/01b_retention.txt
\i sql/01b_retention.sql
\o outputs/01c_spenders.txt
\i sql/01c_spenders.sql
\o outputs/01d_ads.txt
\i sql/01d_ads.sql
\o outputs/02a_arpdau_deep_dive.txt
\i sql/02a_arpdau_deep_dive.sql
\o outputs/03_channels.txt
\i sql/03_channels.sql
\o outputs/04_churn_model.txt
\i sql/04_churn_model.sql
\o
\echo 'All done - results are in outputs/'
