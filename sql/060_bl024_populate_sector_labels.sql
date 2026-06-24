-- BL-024: Populate sector_label in fpds_naics_hierarchy_map
-- All 1,722 rows had sector_code populated but sector_label NULL.
-- This caused sector_label to be null in psc.naics_crosswalk,
-- market.naics_customer_leaders, and naics.growth_leaders.

UPDATE analytics_dims.fpds_naics_hierarchy_map
SET sector_label = CASE sector_code
    WHEN '11' THEN 'Agriculture, Forestry, Fishing and Hunting'
    WHEN '21' THEN 'Mining, Quarrying, and Oil and Gas Extraction'
    WHEN '22' THEN 'Utilities'
    WHEN '23' THEN 'Construction'
    WHEN '31' THEN 'Manufacturing'
    WHEN '32' THEN 'Manufacturing'
    WHEN '33' THEN 'Manufacturing'
    WHEN '42' THEN 'Wholesale Trade'
    WHEN '44' THEN 'Retail Trade'
    WHEN '45' THEN 'Retail Trade'
    WHEN '48' THEN 'Transportation and Warehousing'
    WHEN '49' THEN 'Transportation and Warehousing'
    WHEN '51' THEN 'Information'
    WHEN '52' THEN 'Finance and Insurance'
    WHEN '53' THEN 'Real Estate and Rental and Leasing'
    WHEN '54' THEN 'Professional, Scientific, and Technical Services'
    WHEN '55' THEN 'Management of Companies and Enterprises'
    WHEN '56' THEN 'Administrative and Support and Waste Management and Remediation Services'
    WHEN '61' THEN 'Educational Services'
    WHEN '62' THEN 'Health Care and Social Assistance'
    WHEN '71' THEN 'Arts, Entertainment, and Recreation'
    WHEN '72' THEN 'Accommodation and Food Services'
    WHEN '81' THEN 'Other Services (except Public Administration)'
    WHEN '92' THEN 'Public Administration'
    WHEN '99' THEN 'Unclassified'
    ELSE NULL
END
WHERE sector_code IS NOT NULL AND sector_label IS NULL;

-- Also populate subsector_label if missing (same pattern, 2-digit subsector)
UPDATE analytics_dims.fpds_naics_hierarchy_map
SET subsector_label = CASE LEFT(sector_code, 2)
    WHEN '11' THEN 'Agriculture, Forestry, Fishing and Hunting'
    WHEN '21' THEN 'Mining, Quarrying, and Oil and Gas Extraction'
    WHEN '22' THEN 'Utilities'
    WHEN '23' THEN 'Construction'
    WHEN '31' THEN 'Manufacturing'
    WHEN '32' THEN 'Manufacturing'
    WHEN '33' THEN 'Manufacturing'
    WHEN '42' THEN 'Wholesale Trade'
    WHEN '44' THEN 'Retail Trade'
    WHEN '45' THEN 'Retail Trade'
    WHEN '48' THEN 'Transportation and Warehousing'
    WHEN '49' THEN 'Transportation and Warehousing'
    WHEN '51' THEN 'Information'
    WHEN '52' THEN 'Finance and Insurance'
    WHEN '53' THEN 'Real Estate and Rental and Leasing'
    WHEN '54' THEN 'Professional, Scientific, and Technical Services'
    WHEN '55' THEN 'Management of Companies and Enterprises'
    WHEN '56' THEN 'Administrative and Support and Waste Management and Remediation Services'
    WHEN '61' THEN 'Educational Services'
    WHEN '62' THEN 'Health Care and Social Assistance'
    WHEN '71' THEN 'Arts, Entertainment, and Recreation'
    WHEN '72' THEN 'Accommodation and Food Services'
    WHEN '81' THEN 'Other Services (except Public Administration)'
    WHEN '92' THEN 'Public Administration'
    WHEN '99' THEN 'Unclassified'
    ELSE NULL
END
WHERE subsector_code IS NOT NULL AND subsector_label IS NULL;
