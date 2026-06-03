-- Commercial item acquisition classification.
--
-- Adds a dimension table for commercial_item_acquisition_procedures and
-- a cross-tab view showing commercial vs. non-commercial buying patterns
-- by department, fiscal year, and competition status.
--
-- The commercial/non-commercial distinction is one of the most important
-- strategic signals in federal procurement: commercial items use simplified
-- acquisition, lower barriers, and different pricing dynamics.

-- ─── Dimension table ────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS analytics_dims.fpds_commercial_item_map (
    raw_code        text PRIMARY KEY,
    label           text NOT NULL,
    commercial_family text NOT NULL,
    is_commercial   boolean NOT NULL DEFAULT false,
    sort_order      integer,
    notes           text
);

COMMENT ON TABLE analytics_dims.fpds_commercial_item_map IS
'Maps FPDS commercial_item_acquisition_procedures codes to labels and commercial/non-commercial classification.';

INSERT INTO analytics_dims.fpds_commercial_item_map
    (raw_code, label, commercial_family, is_commercial, sort_order, notes)
VALUES
    ('A', 'Commercial Product/Service',                    'Commercial',     true,  10, 'Standard commercial item acquisition per FAR Part 12.'),
    ('B', 'Products/Services under FAR 12.102(f)',         'Commercial',     true,  20, 'Commercially available off-the-shelf items (COTS) or services acquired under FAR 12.102(f).'),
    ('C', 'Services under FAR 12.102(g)',                  'Commercial',     true,  30, 'Services of a type sold commercially, acquired under FAR 12.102(g).'),
    ('D', 'Commercial Procedures Not Used',                'Non-commercial', false, 40, 'Traditional government acquisition procedures used.'),
    ('E', 'Procedures Not Used (Pre-2006)',                'Non-commercial', false, 50, 'Legacy code for non-commercial procedures prior to FAR updates.'),
    ('UNKNOWN', 'Unknown / Not Reported',                  'Unknown',        false,  0, 'NULL or blank in source data.')
ON CONFLICT (raw_code) DO NOTHING;


-- ─── Report view: commercial vs non-commercial by department and FY ─────────

CREATE OR REPLACE VIEW competition_dynamics.report_deck_commercial_mix_fy AS
SELECT
    fa.contracting_dept_id,
    CASE
        WHEN EXTRACT(month FROM fa.signed_date::timestamp) >= 10
        THEN EXTRACT(year FROM fa.signed_date::timestamp)::integer + 1
        ELSE EXTRACT(year FROM fa.signed_date::timestamp)::integer
    END AS fiscal_year,
    -- Commercial totals
    COUNT(*) FILTER (WHERE COALESCE(cm.is_commercial, false)) AS commercial_action_count,
    SUM(NULLIF(fa.obligated_amount, '')::numeric) FILTER (WHERE COALESCE(cm.is_commercial, false)) AS commercial_obligated,
    COUNT(*) FILTER (WHERE NOT COALESCE(cm.is_commercial, false) AND COALESCE(cm.commercial_family, 'Unknown') != 'Unknown') AS non_commercial_action_count,
    SUM(NULLIF(fa.obligated_amount, '')::numeric) FILTER (WHERE NOT COALESCE(cm.is_commercial, false) AND COALESCE(cm.commercial_family, 'Unknown') != 'Unknown') AS non_commercial_obligated,
    COUNT(*) FILTER (WHERE COALESCE(cm.commercial_family, 'Unknown') = 'Unknown') AS unknown_commercial_action_count,
    -- Total
    COUNT(*) AS total_action_count,
    SUM(NULLIF(fa.obligated_amount, '')::numeric) AS total_obligated,
    -- Shares
    ROUND(COUNT(*) FILTER (WHERE COALESCE(cm.is_commercial, false))::numeric
        / NULLIF(COUNT(*) FILTER (WHERE COALESCE(cm.commercial_family, 'Unknown') != 'Unknown'), 0), 4) AS commercial_action_share,
    ROUND(SUM(NULLIF(fa.obligated_amount, '')::numeric) FILTER (WHERE COALESCE(cm.is_commercial, false))
        / NULLIF(SUM(NULLIF(fa.obligated_amount, '')::numeric) FILTER (WHERE COALESCE(cm.commercial_family, 'Unknown') != 'Unknown'), 0), 4) AS commercial_obligation_share,
    -- Commercial + competed
    COUNT(*) FILTER (WHERE COALESCE(cm.is_commercial, false) AND ecm.is_competed) AS commercial_competed_count,
    SUM(NULLIF(fa.obligated_amount, '')::numeric) FILTER (WHERE COALESCE(cm.is_commercial, false) AND ecm.is_competed) AS commercial_competed_obligated,
    COUNT(*) FILTER (WHERE COALESCE(cm.is_commercial, false) AND ecm.is_not_competed) AS commercial_not_competed_count,
    SUM(NULLIF(fa.obligated_amount, '')::numeric) FILTER (WHERE COALESCE(cm.is_commercial, false) AND ecm.is_not_competed) AS commercial_not_competed_obligated,
    -- Non-commercial + competed
    COUNT(*) FILTER (WHERE NOT COALESCE(cm.is_commercial, false) AND COALESCE(cm.commercial_family, 'Unknown') != 'Unknown' AND ecm.is_competed) AS non_commercial_competed_count,
    SUM(NULLIF(fa.obligated_amount, '')::numeric) FILTER (WHERE NOT COALESCE(cm.is_commercial, false) AND COALESCE(cm.commercial_family, 'Unknown') != 'Unknown' AND ecm.is_competed) AS non_commercial_competed_obligated,
    -- Distinct vendors
    COUNT(DISTINCT fa.uei) FILTER (WHERE COALESCE(cm.is_commercial, false)) AS commercial_distinct_vendors,
    COUNT(DISTINCT fa.uei) FILTER (WHERE NOT COALESCE(cm.is_commercial, false) AND COALESCE(cm.commercial_family, 'Unknown') != 'Unknown') AS non_commercial_distinct_vendors
FROM public.fpds_actions fa
LEFT JOIN analytics_dims.fpds_commercial_item_map cm
    ON COALESCE(fa.commercial_item_acquisition_procedures, 'UNKNOWN') = cm.raw_code
LEFT JOIN analytics_dims.fpds_extent_competed_map ecm
    ON fa.extent_competed = ecm.raw_code
WHERE fa.signed_date IS NOT NULL AND fa.signed_date != ''
GROUP BY fa.contracting_dept_id,
    CASE
        WHEN EXTRACT(month FROM fa.signed_date::timestamp) >= 10
        THEN EXTRACT(year FROM fa.signed_date::timestamp)::integer + 1
        ELSE EXTRACT(year FROM fa.signed_date::timestamp)::integer
    END
ORDER BY fa.contracting_dept_id, fiscal_year;

COMMENT ON VIEW competition_dynamics.report_deck_commercial_mix_fy IS
'Commercial vs. non-commercial acquisition mix by department and fiscal year. Shows the share of procurement using FAR Part 12 commercial procedures, with competition cross-tabs.';


-- ─── Facade views ──────────────────────────────────────────────────────────

CREATE OR REPLACE VIEW analytics_api.competition_commercial_mix_fy
WITH (security_barrier = true) AS
SELECT * FROM competition_dynamics.report_deck_commercial_mix_fy;

COMMENT ON VIEW analytics_api.competition_commercial_mix_fy IS
'Commercial vs. non-commercial buying by department and fiscal year. Shows what share of procurement uses simplified commercial procedures and whether commercial awards are competed.';

CREATE OR REPLACE VIEW analytics_api.dim_commercial_item_codes
WITH (security_barrier = true) AS
SELECT raw_code, label, commercial_family, is_commercial, sort_order, notes
FROM analytics_dims.fpds_commercial_item_map;

COMMENT ON VIEW analytics_api.dim_commercial_item_codes IS
'Commercial item acquisition procedure code lookup. Maps FPDS codes to commercial/non-commercial classification.';
