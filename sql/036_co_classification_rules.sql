-- FPDS-022 Step 1: User Classification Rule Table
-- Classifies fpds_actions user IDs as human / system / unknown
-- Patterns derived from Step 0 census of all 4 user columns
-- 
-- Two layers:
--   1. Pattern rules (this table) — ILIKE patterns for known system accounts
--   2. Behavioral backstop (applied at directory build time) — volume/span thresholds
--
-- Usage: any user_id matching a pattern rule → system
--        remaining email-format IDs passing behavioral check → presumption human
--        everything else → unknown

BEGIN;

-- ============================================================
-- Layer 1: Pattern Rule Table
-- ============================================================

CREATE TABLE IF NOT EXISTS analytics_dims.fpds_user_classification_rule (
    rule_id       SERIAL PRIMARY KEY,
    pattern       TEXT NOT NULL,           -- ILIKE pattern to match against user_id
    user_class    TEXT NOT NULL DEFAULT 'system',  -- human | system
    category      TEXT,                    -- grouping: migration, closeout, batch_feeder, admin, agency_system, etc.
    notes         TEXT,                    -- why this pattern exists
    created_at    TIMESTAMPTZ DEFAULT now()
);

COMMENT ON TABLE analytics_dims.fpds_user_classification_rule IS
    'FPDS-022: Pattern rules for classifying fpds_actions user IDs as human or system accounts. '
    'Derived from Step 0 census across created_by, approved_by, last_modified_by, closed_by.';

-- ============================================================
-- Insert classification patterns
-- ============================================================

INSERT INTO analytics_dims.fpds_user_classification_rule (pattern, user_class, category, notes) VALUES

-- Migration accounts
('MIGRATOR',            'system', 'migration', 'Generic data migration account — 7.9M created_by actions'),
('DOD_MIGRATOR',        'system', 'migration', 'DoD-specific migration — 3.6M created_by actions'),
('FSSMIGRATOR',         'system', 'migration', 'FSS migration account — 433K actions'),
('%MIGRAT%',            'system', 'migration', 'Catch-all for migration-pattern accounts'),

-- Closeout automation
('DOD_CLOSEOUT',        'system', 'closeout', 'DoD closeout bot — 22.8M last_modified_by, 26.1M closed_by'),
('FPDS_CLOSEOUT',       'system', 'closeout', 'FPDS closeout bot — 6.4M modifier, 6.8M closer'),
('DHS_CLOSEOUT',        'system', 'closeout', 'DHS closeout — 65K across roles'),
('%CLOSEOUT%',          'system', 'closeout', 'Catch-all for closeout automation'),

-- FPDS system admin / correction accounts
('FPDSADMIN',           'system', 'admin', 'FPDS admin — 17.2M modifier actions'),
('FPDSADMIN_COMP',      'system', 'admin', 'FPDS admin compliance variant'),
('FPDSCOMP',            'system', 'admin', 'FPDS compliance account — 534K modifier'),
('FPDSV14',             'system', 'admin', 'FPDS v14 system account — 1.3M modifier'),
('FPDSDM_ADMIN',        'system', 'admin', 'FPDS data management admin'),
('IDV_CORRECT',         'system', 'admin', 'IDV correction bot — 9.9M modifier actions'),
('CHANGE_PIID_USER',    'system', 'admin', 'PIID change system account — 46K modifier'),

-- Agency system admin accounts
('%SYSADMIN%',          'system', 'admin', 'Catches EBS.SYSADMIN.DLA.MIL (26.5M), EPROCUREMENT.SYSADMIN.DLA (9.8M), and agency sysadmins'),
('00.F.%@GSA.GOV',      'system', 'admin', 'GSA system accounts — 00.F.SYSTEMADMIN (10.3M), 00.F.FALCONPROD (4.5M)'),
('NAVYADMIN',           'system', 'admin', 'Navy admin account — 36K modifier'),
('ARMYADMIN',           'system', 'admin', 'Army admin account — 35K modifier'),
('DLAADMIN2',           'system', 'admin', 'DLA admin account — 41K approver'),

-- Bot accounts
('%BOT%',               'system', 'bot', 'Catches BOTDOICO, KSBOT01, SV.IO.OCIO-BOT0443, PBS.BOT.*, HHSAPN_BOT_CCI'),

-- Agency batch feeder systems
('PADDS.%',             'system', 'batch_feeder', 'Army Procurement Automated Data Distribution System — multiple offices, 60-100K each'),
('ACPS5700_%',          'system', 'batch_feeder', 'Air Force AFMC system feeders — Hill, Robins, Tinker, ~80K each'),
('ACPS97AS_%',          'system', 'batch_feeder', 'DLA system feeders via ACPS'),
('USERCW@%',            'system', 'batch_feeder', 'Contract Writing system accounts — SA5700 family, 30-67K each'),
('SYSORIG%',            'system', 'batch_feeder', 'System origination accounts — DISA, Navy, DCMA, eMall'),
('AFMC.%@SA5700%',      'system', 'batch_feeder', 'Air Force Materiel Command system path'),
('COPS.%',              'system', 'batch_feeder', 'COPS system accounts — DISA'),
('CONTRACT.AIRLIFT@%',  'system', 'batch_feeder', 'Airlift contract system path — 49K creator'),

-- FTP / interface / web service accounts
('%FTP',                'system', 'interface', 'FTP feeder accounts — FSSFTP (412K), NASAFTP (38K)'),
('WEBSERVICE',          'system', 'interface', 'Web service integration account — 169K creator'),

-- Agency-specific system accounts (exact or near-exact matches)
('IFCAP.DATA@VA.GOV',   'system', 'agency_system', 'VA IFCAP financial system — 2.8M creator; email format but NOT a person'),
('DCARSSAP%',           'system', 'agency_system', 'Defense Civilian Automated Reporting System SAP — 551K creator, 1.1M approver'),
('PBSLEASE%',           'system', 'agency_system', 'PBS Lease XML feeders — 367K + 316K creator'),
('FBMSUSER',            'system', 'agency_system', 'Financial Business Management System — 131K creator'),
('HUDUSER',             'system', 'agency_system', 'HUD system account — 34K creator'),
('USAIDNEGOTIATOR',     'system', 'agency_system', 'USAID system role account — 111K creator'),
('EPAICMS.ADMIN',       'system', 'agency_system', 'EPA ICM system admin — 66K creator'),
('FAA_ID',              'system', 'agency_system', 'FAA system identifier account — 48K creator'),
('JCCIAADMIN',          'system', 'agency_system', 'JCCIA admin account — 142K creator'),

-- Generic admin pattern (catch remaining *ADMIN accounts not caught above)
('%ADMIN',              'system', 'admin', 'Catch-all for accounts ending in ADMIN')

;

-- ============================================================
-- Verify rule count
-- ============================================================
SELECT COUNT(*) AS total_rules,
       COUNT(DISTINCT category) AS categories
FROM analytics_dims.fpds_user_classification_rule;

COMMIT;
