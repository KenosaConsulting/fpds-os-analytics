-- 051a_fix_contract_pricing_dim.sql
-- Fix: Add USASpending full-text pricing descriptions to fpds_contract_pricing_map
--
-- Problem: The dim table only has FPDS short descriptions (e.g. 'FP WITH EPA')
-- but prime_awards.type_of_contract_pricing uses USASpending full text
-- (e.g. 'FIXED PRICE WITH ECONOMIC PRICE ADJUSTMENT'). The join on raw_desc
-- only matches 5 of 22 distinct values, leaving 96% as 'Unknown'.
--
-- Fix: Add rows for each USASpending-style description that maps to the
-- same pricing_family as its FPDS equivalent.
--
-- Run: psql $CONN -f sql/051a_fix_contract_pricing_dim.sql
-- Expected duration: instant
-- After this: rebuild 051_topic_intel_mv_contract_type.sql
--
-- Date: 2026-06-18

\echo '=== 051a: Fix contract pricing dim ==='
\echo 'Before state:'
SELECT count(*) AS total_rows FROM analytics_dims.fpds_contract_pricing_map;

------------------------------------------------------------------------
-- Add USASpending full-text descriptions as additional rows
-- These map to the same pricing families as the FPDS short forms.
------------------------------------------------------------------------
\echo 'Inserting USASpending pricing descriptions...'

INSERT INTO analytics_dims.fpds_contract_pricing_map 
  (raw_code, raw_desc, pricing_family, risk_profile, is_fixed_price, is_cost_type, is_time_and_materials, is_order_dependent, sort_order, notes)
VALUES
  -- Fixed Price variants
  ('J2', 'FIXED PRICE',                          'Fixed Price',        'LOW_RISK',      true,  false, false, false, 1,  'USASpending alt desc for FFP'),
  ('A2', 'FIXED PRICE REDETERMINATION',          'Fixed Price',        'MODERATE_RISK', true,  false, false, false, 5,  'USASpending alt desc'),
  ('B2', 'FIXED PRICE LEVEL OF EFFORT',          'Fixed Price',        'MODERATE_RISK', true,  false, false, false, 6,  'USASpending alt desc'),
  ('K2', 'FIXED PRICE WITH ECONOMIC PRICE ADJUSTMENT', 'Fixed Price',  'MODERATE_RISK', true,  false, false, false, 2,  'USASpending alt desc'),
  ('L2', 'FIXED PRICE INCENTIVE',                'Fixed Price',        'MODERATE_RISK', true,  false, false, false, 3,  'USASpending alt desc'),
  ('M2', 'FIXED PRICE AWARD FEE',                'Fixed Price',        'MODERATE_RISK', true,  false, false, false, 4,  'USASpending alt desc'),
  -- Cost Reimbursement variants
  ('R2', 'COST PLUS AWARD FEE',                  'Cost Reimbursement', 'HIGH_RISK',     false, true,  false, false, 10, 'USASpending alt desc'),
  ('V2', 'COST PLUS INCENTIVE FEE',              'Cost Reimbursement', 'HIGH_RISK',     false, true,  false, false, 14, 'USASpending alt desc'),
  ('V3', 'COST PLUS INCENTIVE',                  'Cost Reimbursement', 'HIGH_RISK',     false, true,  false, false, 14, 'USASpending alt desc'),
  ('T2', 'COST SHARING',                         'Cost Reimbursement', 'HIGH_RISK',     false, true,  false, false, 12, 'USASpending alt desc'),
  -- Other / combination / order dependent
  ('12', 'ORDER DEPENDENT (IDV ALLOWS PRICING ARRANGEMENT TO BE DETERMINED SEPARATELY FOR EACH ORDER)', 'Other', 'VARIABLE', false, false, false, true, 20, 'USASpending alt desc'),
  ('13', 'ORDER DEPENDENT (IDV ONLY)',            'Other',             'VARIABLE',      false, false, false, true,  20, 'USASpending alt desc'),
  ('22', 'COMBINATION (TWO OR MORE)',             'Other',             'VARIABLE',      false, false, false, false, 21, 'USASpending alt desc'),
  ('23', 'COMBINATION (APPLIES TO AWARDS WHERE TWO OR MORE OF THE ABOVE APPLY)', 'Other', 'VARIABLE', false, false, false, false, 21, 'USASpending alt desc'),
  ('32', 'OTHER (NONE OF THE ABOVE)',             'Other',             'VARIABLE',      false, false, false, false, 22, 'USASpending alt desc'),
  ('33', 'OTHER (APPLIES TO AWARDS WHERE NONE OF THE ABOVE APPLY)', 'Other', 'VARIABLE', false, false, false, false, 22, 'USASpending alt desc'),
  ('NR', 'NOT REPORTED',                         'Unknown',           'UNKNOWN',       false, false, false, false, 99, 'No pricing data reported')
ON CONFLICT DO NOTHING;

------------------------------------------------------------------------
-- Verify
------------------------------------------------------------------------
\echo ''
\echo 'After state:'
SELECT count(*) AS total_rows FROM analytics_dims.fpds_contract_pricing_map;

\echo ''
\echo 'All entries:'
SELECT raw_code, raw_desc, pricing_family, risk_profile
FROM analytics_dims.fpds_contract_pricing_map
ORDER BY pricing_family, sort_order;

\echo '=== 051a: COMPLETE ==='
