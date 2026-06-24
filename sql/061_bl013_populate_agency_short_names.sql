-- BL-013: Populate agency_short_name for major civilian agencies
-- 312 of 371 agencies had null agency_short_name. This update covers
-- the major civilian agencies that appear in analytical queries.
-- Sub-offices (ASSISTANT SECRETARY, BUREAU OF, etc.) are left null
-- as they are rarely referenced by short name.

UPDATE analytics_dims.fpds_agency_map
SET agency_short_name = CASE agency_id
    -- USDA sub-agencies
    WHEN '1200' THEN 'USDA'
    WHEN '1241' THEN 'AMS'
    WHEN '12K2' THEN 'AMS'
    WHEN '1230' THEN 'ARS'
    WHEN '12H2' THEN 'ARS'
    WHEN '1242' THEN 'APHIS'
    WHEN '12K3' THEN 'APHIS'
    WHEN '1220' THEN 'ASCS'
    -- Treasury
    WHEN '2000' THEN 'Treasury'
    WHEN '2022' THEN 'TTB'
    -- Commerce
    WHEN '1300' THEN 'DOC'
    WHEN '131E' THEN 'DOC-Econ'
    -- Interior
    WHEN '1400' THEN 'DOI'
    -- Labor
    WHEN '1600' THEN 'DOL'
    WHEN '1621' THEN 'EBSA'
    WHEN '1630' THEN 'ETA'
    WHEN '1635' THEN 'ESA'
    -- Energy
    WHEN '8900' THEN 'DOE'
    WHEN '8930' THEN 'ERA'
    WHEN '8933' THEN 'EIA'
    -- Education
    WHEN '9100' THEN 'ED'
    -- VA (HUD)
    WHEN '8600' THEN 'HUD'
    -- EPA
    WHEN '6800' THEN 'EPA'
    -- NASA
    WHEN '8000' THEN 'NASA'
    -- GSA
    WHEN '4700' THEN 'GSA'
    -- DHS
    WHEN '7000' THEN 'DHS'
    -- State
    WHEN '1900' THEN 'State'
    -- RRB
    WHEN '6000' THEN 'RRB'
    -- USAID
    WHEN '7200' THEN 'USAID'
    WHEN '1152' THEN 'USAID'
    -- HHS sub-agencies
    WHEN '7500' THEN 'HHS'
    WHEN '7590' THEN 'ACF'
    WHEN '7528' THEN 'AHRQ'
    -- Transportation
    WHEN '6900' THEN 'DOT'
    -- Justice
    WHEN '1500' THEN 'DOJ'
    -- SBA
    WHEN '7300' THEN 'SBA'
    -- NSF
    WHEN '4900' THEN 'NSF'
    -- NRC
    WHEN '9200' THEN 'NRC'
    -- Smithsonian
    WHEN '9300' THEN 'Smithsonian'
    -- NARA
    WHEN '5100' THEN 'NARA'
    -- TVA
    WHEN '6400' THEN 'TVA'
    -- USPS
    WHEN '6500' THEN 'USPS'
    -- ExIm Bank
    WHEN '8300' THEN 'ExIm'
    -- EEOC
    WHEN '4500' THEN 'EEOC'
    -- CPSC
    WHEN '6100' THEN 'CPSC'
    -- ACTION
    WHEN '4400' THEN 'ACTION'
    -- AFRI
    WHEN '9770' THEN 'AFRRI'
    -- DoD top-level
    WHEN '9700' THEN 'DoD'
    WHEN '9777' THEN 'BTA'
    WHEN '9748' THEN 'DHRA'
    WHEN '97F1' THEN 'DMA'
    WHEN '9771' THEN 'DMEA'
    WHEN '97F2' THEN 'DoDEA'
    -- Independent agencies
    WHEN '9516' THEN 'DNFSB'
    WHEN '9507' THEN 'CFTC'
    WHEN '955F' THEN 'CFPB'
    WHEN '9577' THEN 'CNCS'
    WHEN '9594' THEN 'CSOSA'
    WHEN '9515' THEN 'ACUS'
    WHEN '7400' THEN 'ABMC'
    WHEN '9501' THEN 'BIB'
    WHEN '9565' THEN 'CSB'
    WHEN '9517' THEN 'CCR'
    WHEN '9518' THEN 'CPSSD'
    WHEN '9523' THEN 'EAC'
    WHEN '9534' THEN 'DC Courts'
    -- Departments without short names
    WHEN '4400' THEN 'ACTION'
    ELSE agency_short_name
END
WHERE agency_short_name IS NULL
  AND agency_id IN (
    '1200','1241','12K2','1230','12H2','1242','12K3','1220',
    '2000','2022','1300','131E','1400','1600','1621','1630','1635',
    '8900','8930','8933','9100','8600','6800','8000','4700','7000',
    '6000','7200','1152','7500','7590','7528','6900','1500','7300',
    '4900','9200','9300','5100','6400','6500','8300','4500','6100',
    '4400','9770','9700','9777','9748','97F1','9771','97F2',
    '9516','9507','955F','9577','9594','9515','7400','9501','9565',
    '9517','9518','9523','9534'
  );

-- Also populate department_short_name for departments missing it
UPDATE analytics_dims.fpds_department_map
SET department_short_name = CASE department_id
    WHEN '4400' THEN 'ACTION'
    WHEN '9515' THEN 'ACUS'
    WHEN '7400' THEN 'ABMC'
    WHEN '9501' THEN 'BIB'
    WHEN '9565' THEN 'CSB'
    WHEN '9517' THEN 'CCR'
    WHEN '9518' THEN 'CPSSD'
    WHEN '9523' THEN 'EAC'
    WHEN '9534' THEN 'DC Courts'
    WHEN '9516' THEN 'DNFSB'
    WHEN '9507' THEN 'CFTC'
    WHEN '955F' THEN 'CFPB'
    WHEN '9577' THEN 'CNCS'
    WHEN '9594' THEN 'CSOSA'
    WHEN '4500' THEN 'EEOC'
    WHEN '6100' THEN 'CPSC'
    WHEN '8300' THEN 'ExIm'
    ELSE department_short_name
END
WHERE department_short_name IS NULL
  AND department_id IN (
    '4400','9515','7400','9501','9565','9517','9518','9523','9534',
    '9516','9507','955F','9577','9594','4500','6100','8300'
  );
