-- ZenSched Process-Serving Local Database Schema
-- SQLite database for clients (law firms, collection agencies, property managers,
-- courts, other servers), a cache of serve addresses, the server roster, cases,
-- the serve addresses on each case, the attempts made at each address, mileage,
-- client invoices / receivables, and subcontractor payouts.
-- DO NOT duplicate live schedule data from ZenSched (shifts, punches, timesheets).
--
-- HOW TO LOAD THIS FILE
--   Normal path: paste this whole file into your AI chat and say
--   "Create these tables in my serve-ops database. Run each statement one at a time."
--   The AI runs each statement through the SQLite MCP tool (sqlite_execute).
--   Most SQLite MCP tools accept ONE statement per call, so every statement
--   below ends with a semicolon and stands alone.
--
--   Alternative (if you have the sqlite3 command-line tool):
--     sqlite3 serve-ops.db < schema.sql
--
-- Every statement is idempotent (IF NOT EXISTS / INSERT OR IGNORE), so it is
-- safe to run this file again on an existing database.
--
-- THIS IS NOT AN AFFIDAVIT GENERATOR, AN E-FILING TOOL, OR A RULES ENGINE. The
-- due_diligence_log view below lists every attempt with its GPS-verified times,
-- outcome, description, and photo count in affidavit order so the agent can
-- paste it into YOUR proof-of-service or declaration template. Nothing here
-- knows your state's attempt thresholds, substituted-service rules, or mailing
-- requirements; cases_ready_for_substitute is a count, not a legal opinion.
--
-- PRIVACY: the servee's (defendant's) name, phone, date of birth, description
-- hints, the plaintiff, the documents, and firm contacts live ONLY in this file
-- on your computer: cases.servee_name, cases.servee_phone, cases.servee_dob,
-- cases.servee_notes, cases.plaintiff, serve_addresses.notes, places.access_notes,
-- servers.license_no. ZenSched receives, per serve address, a location label
-- ("Serve 24-CV-1187 - Marconi Ave"), the street address for the GPS pin, an
-- event title made of the case number and street, and the Attempt Record the
-- server fills in on the phone (outcome, who accepted, PHYSICAL description
-- only, vehicles/occupancy, door photo, documents left, notes).
-- SKILL.md forbids the agent from putting any local-only column into a ZenSched field.

-- Foreign keys are OFF by default in SQLite. This must be run once per
-- connection for ON DELETE CASCADE to work. SKILL.md tells the agent to run it
-- at the start of each session.
PRAGMA foreign_keys = ON;

-- Settings: small key/value store so the agent does not have to be re-told the
-- basics every session (timezone, defaults, business name, form id).
CREATE TABLE IF NOT EXISTS settings (
  key TEXT PRIMARY KEY,
  value TEXT
);

INSERT OR IGNORE INTO settings (key, value) VALUES ('business_name', 'My Process Service');
INSERT OR IGNORE INTO settings (key, value) VALUES ('timezone_offset', '-05:00');
INSERT OR IGNORE INTO settings (key, value) VALUES ('state', NULL);
INSERT OR IGNORE INTO settings (key, value) VALUES ('default_server_id', NULL);
INSERT OR IGNORE INTO settings (key, value) VALUES ('default_attempt_minutes', '20');
INSERT OR IGNORE INTO settings (key, value) VALUES ('default_included_attempts', '3');
INSERT OR IGNORE INTO settings (key, value) VALUES ('invoice_due_days', '30');
INSERT OR IGNORE INTO settings (key, value) VALUES ('invoice_prefix', 'INV');
INSERT OR IGNORE INTO settings (key, value) VALUES ('attempt_form_id', NULL);
-- IRS standard mileage rate for business use. 0.70 is the 2025 rate ($0.70/mile);
-- the IRS announces a new rate each December. Update this once a year.
INSERT OR IGNORE INTO settings (key, value) VALUES ('irs_mileage_rate', '0.70');

-- Clients: who hires you and who pays you. A law firm, a collection agency, a
-- property manager (evictions), a court or public agency, another process
-- server passing overflow, or a direct party. payment_terms_days drives invoice
-- due dates; the default_* fees are what the agent uses when a service request
-- does not state a fee (a trigger copies them onto the case).
CREATE TABLE IF NOT EXISTS clients (
  client_id INTEGER PRIMARY KEY AUTOINCREMENT,
  client_name TEXT NOT NULL,
  client_type TEXT NOT NULL DEFAULT 'law_firm'
    CHECK (client_type IN ('law_firm', 'collection_agency', 'property_manager', 'court', 'process_server', 'direct', 'other')),
  contact_name TEXT,                                -- paralegal / AP contact, LOCAL ONLY
  contact_phone TEXT,
  billing_email TEXT,
  payment_terms_days INTEGER NOT NULL DEFAULT 30,   -- net 30 / net 45; direct = 0
  default_serve_fee REAL,                           -- $ per serve (routine), includes N attempts
  default_included_attempts INTEGER,                -- NULL -> settings.default_included_attempts
  default_extra_attempt_fee REAL,                   -- $ per attempt beyond the included ones
  default_rush_fee REAL,                            -- $ added when the case is rush
  default_bad_address_fee REAL,                     -- $ owed when every address fails (non-service)
  notes TEXT,
  is_active INTEGER DEFAULT 1,
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now'))
);

-- Places: a cache of serve addresses -> ZenSched location ids.
-- Apartment complexes, workplaces, and jails repeat; homes usually do not.
-- normalized_address is the de-dup key: the agent builds it as
-- lowercase(address + city + state + zip) with commas, periods, and '#' removed
-- and whitespace collapsed to single spaces (SQLite cannot collapse whitespace,
-- so the agent does it). The agent looks here FIRST and only calls
-- location_create (geocode, $0.03) on a miss. Hand-tuned pins (location_update)
-- therefore survive for repeat sites. place_label is the ONLY name sent to
-- ZenSched for this address; street_name (no house number) feeds event titles.
-- access_notes is LOCAL ONLY.
CREATE TABLE IF NOT EXISTS places (
  place_id INTEGER PRIMARY KEY AUTOINCREMENT,
  normalized_address TEXT NOT NULL UNIQUE,
  address TEXT NOT NULL,
  city TEXT,
  state TEXT,
  zip TEXT,
  street_name TEXT,                                 -- 'Marconi Ave' (no number); used in event titles
  place_label TEXT,                                 -- sent to ZenSched: 'Serve 24-CV-1187 - Marconi Ave', 'Acme Logistics - Elk Grove'
  zensched_location_id INTEGER,                     -- from location_create (permanent)
  access_notes TEXT,                                -- LOCAL ONLY: gate code, 'unit 12 is rear building', 'dog'
  is_repeat_site INTEGER DEFAULT 0,                 -- 1 = complex / workplace / facility you expect to return to
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now'))
);

-- Servers: in solo mode this is one row (you, is_owner = 1) whose
-- zensched_worker_id came from inviting yourself. In agency mode add a row per
-- subcontracted server with payout_type/payout_value:
--   per_serve   -> $ per case served (or closed as non-service)
--   per_attempt -> $ per attempt actually made
--   percent     -> % of the case's billable total
-- license_no (registration / certification number) is LOCAL ONLY.
CREATE TABLE IF NOT EXISTS servers (
  server_id INTEGER PRIMARY KEY AUTOINCREMENT,
  server_name TEXT NOT NULL,
  email TEXT,
  phone TEXT,
  zensched_worker_id INTEGER UNIQUE,                -- from worker_invite
  is_owner INTEGER DEFAULT 0,                       -- 1 = the business owner (no payouts)
  license_no TEXT,                                  -- LOCAL ONLY: county registration / state certification number
  license_expires TEXT,                             -- ISO date
  payout_type TEXT
    CHECK (payout_type IS NULL OR payout_type IN ('per_serve', 'per_attempt', 'percent')),
  payout_value REAL,                                -- $ (per_serve / per_attempt) or % (percent)
  is_active INTEGER DEFAULT 1,
  notes TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now'))
);

-- Cases: one row per service job from a client. A case has one or more serve
-- addresses (below) and each address gets attempts. The case carries the fee
-- structure as a snapshot (trigger fills from the client's defaults when left
-- NULL) and the deadline the firm gave you (due_by).
--
-- case_no is the COURT's case number (public record; used in ZenSched labels).
-- case_ref is YOUR reference, filled by trigger as 'C-2026-0001' when NULL, so
-- a job with no court number yet (pre-filing subpoena, demand letter) still has
-- a stable handle. Views expose case_label = COALESCE(case_no, case_ref).
--
-- servee_name, servee_phone, servee_dob, servee_notes, plaintiff are LOCAL ONLY
-- and never reach ZenSched.
--
-- status: open -> served | not_served (every address exhausted / bad address)
--                | cancelled (client withdrew). served_attempt_id points at the
-- attempt that effected service; served_manner is copied from it.
CREATE TABLE IF NOT EXISTS cases (
  case_id INTEGER PRIMARY KEY AUTOINCREMENT,
  case_ref TEXT UNIQUE,                             -- 'C-2026-0001', filled by trigger if NULL
  client_id INTEGER NOT NULL,
  client_ref TEXT,                                  -- the firm's file / matter number
  case_no TEXT,                                     -- court case number, e.g. '24-CV-1187'
  court TEXT,                                       -- 'Sacramento Superior Court'
  plaintiff TEXT,                                   -- LOCAL ONLY
  servee_name TEXT,                                 -- LOCAL ONLY: defendant / witness / tenant to be served
  servee_phone TEXT,                                -- LOCAL ONLY
  servee_dob TEXT,                                  -- LOCAL ONLY (ISO date) when the firm supplies it
  servee_notes TEXT,                                -- LOCAL ONLY: 'works nights', 'drives white F-150', skip-trace hints
  document_types TEXT,                              -- 'Summons & Complaint', 'Subpoena', '3-day notice', ...
  is_rush INTEGER DEFAULT 0,
  received_date TEXT DEFAULT (date('now', 'localtime')),
  due_by TEXT,                                      -- ISO date the firm needs service by (or the court deadline)
  status TEXT NOT NULL DEFAULT 'open'
    CHECK (status IN ('open', 'served', 'not_served', 'cancelled')),
  serve_fee REAL,                                   -- NULL -> client default (trigger)
  included_attempts INTEGER,                        -- NULL -> client default -> settings (trigger)
  extra_attempt_fee REAL,                           -- NULL -> client default (trigger)
  rush_fee REAL,                                    -- NULL -> client default (trigger); only billed when is_rush = 1
  mileage_fee REAL,                                 -- $ flat mileage / travel charge to the client (0 unless agreed)
  bad_address_fee REAL,                             -- NULL -> client default (trigger); billed when status = not_served
  other_fee REAL,                                   -- skip trace pass-through, wait time, cancellation fee, ...
  served_at TEXT,                                   -- local 'YYYY-MM-DDTHH:MM', from the serving attempt's check-in
  served_manner TEXT
    CHECK (served_manner IS NULL OR served_manner IN ('personal', 'substituted', 'posted', 'mail', 'refused', 'not_served')),
  served_attempt_id INTEGER,
  mailed_at TEXT,                                   -- ISO date the follow-up mailing went out (substituted / posted), if your rules need one
  proof_sent_at TEXT,                               -- ISO date the proof of service / affidavit went to the client
  notes TEXT,
  invoiced INTEGER DEFAULT 0,
  paid_out INTEGER DEFAULT 0,                       -- 1 = sub payout done for a per_serve / percent sub
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (client_id) REFERENCES clients(client_id) ON DELETE CASCADE,
  FOREIGN KEY (served_attempt_id) REFERENCES attempts(attempt_id) ON DELETE SET NULL
);

-- Serve addresses: where a case can be attempted. One ZenSched LOCATION per
-- place (cached) and one ZenSched EVENT per serve address, rolled every <= 60
-- days if the case outlives the window: zensched_event_id is the CURRENT event
-- and event_valid_until its last valid date. When an attempt date is later than
-- event_valid_until, the agent creates a new event and updates both columns.
-- notes is LOCAL ONLY (who lives there, when the servee is home).
CREATE TABLE IF NOT EXISTS serve_addresses (
  serve_address_id INTEGER PRIMARY KEY AUTOINCREMENT,
  case_id INTEGER NOT NULL,
  place_id INTEGER NOT NULL,
  address_type TEXT NOT NULL DEFAULT 'home'
    CHECK (address_type IN ('home', 'work', 'other')),
  is_active INTEGER DEFAULT 1,                      -- 0 = exhausted / bad address; stop planning attempts here
  notes TEXT,                                       -- LOCAL ONLY
  zensched_event_id INTEGER,                        -- current event window
  event_valid_until TEXT,                           -- ISO date: last day the current event covers
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (case_id) REFERENCES cases(case_id) ON DELETE CASCADE,
  FOREIGN KEY (place_id) REFERENCES places(place_id) ON DELETE RESTRICT
);

-- Attempts: THE driving table. One row per attempt window at a serve address;
-- each row maps to exactly one ZenSched shift. Two ways a row is born:
--   planned  - created at intake (first window) or when the owner schedules more
--   ad hoc   - "attempting Garcia now": scheduled_start = now, is_adhoc = 1, and
--              the server punches within the minute
-- attempt_no is numbered per serve address by trigger (1, 2, 3 ...).
--
-- scheduled_start is LOCAL wall-clock time as 'YYYY-MM-DDTHH:MM' or
-- 'YYYY-MM-DDTHH:MM:SS' with NO offset and no 'Z'; the views append
-- settings.timezone_offset to produce start_iso / end_iso for shift_create.
--
-- status: planned -> attempted (record pulled, not served) | served (record
-- pulled and the owner confirmed service) | cancelled (window not used).
-- outcome / served_person / person_description / vehicles_seen / docs_left /
-- photo_count / record_dc_id come from the Attempt Record. manner is derived
-- from outcome. checked_in_at / checked_out_at / gps_verified /
-- checkin_distance_m are copied from shift_status once, so the due-diligence
-- log and "did Luis actually go" are answered from SQLite for free.
CREATE TABLE IF NOT EXISTS attempts (
  attempt_id INTEGER PRIMARY KEY AUTOINCREMENT,
  serve_address_id INTEGER NOT NULL,
  attempt_no INTEGER,                               -- per serve address, filled by trigger if NULL
  server_id INTEGER,                                -- NULL -> settings.default_server_id (trigger)
  scheduled_start TEXT NOT NULL                     -- local 'YYYY-MM-DDTHH:MM[:SS]', no offset
    CHECK (scheduled_start GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-2][0-9]:[0-5][0-9]*'
           AND scheduled_start NOT GLOB '*T*[+-]*'
           AND scheduled_start NOT GLOB '*Z'),
  duration_minutes INTEGER                          -- NULL -> settings.default_attempt_minutes
    CHECK (duration_minutes IS NULL OR duration_minutes BETWEEN 5 AND 240),
  is_adhoc INTEGER DEFAULT 0,                       -- 1 = "I'm here now" window created on the spot
  status TEXT NOT NULL DEFAULT 'planned'
    CHECK (status IN ('planned', 'attempted', 'served', 'cancelled')),
  outcome TEXT,                                     -- form option key: served___personal, no_answer, bad_address, ...
  manner TEXT
    CHECK (manner IS NULL OR manner IN ('personal', 'substituted', 'posted', 'mail', 'refused', 'not_served')),
  served_person TEXT,                               -- form option key: servee, co_resident_adult, ...
  person_description TEXT,                          -- from the form: PHYSICAL description only, no names
  vehicles_seen TEXT,                               -- from the form: vehicles / signs of occupancy
  docs_left INTEGER,                                -- 1 if documents were left / posted
  photo_count INTEGER DEFAULT 0,                    -- door photos on the submission (the images stay on ZenSched)
  zensched_shift_id INTEGER UNIQUE,
  record_dc_id INTEGER,                             -- Attempt Record submission_id
  checked_in_at TEXT,                               -- from shift_status (ISO with offset)
  checked_out_at TEXT,
  gps_verified INTEGER,                             -- 1 if the check-in punch was on site
  checkin_distance_m INTEGER,
  notes TEXT,                                       -- from the form 'Notes for the file' + owner notes
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (serve_address_id) REFERENCES serve_addresses(serve_address_id) ON DELETE CASCADE,
  FOREIGN KEY (server_id) REFERENCES servers(server_id) ON DELETE SET NULL
);

-- Mileage: one row per trip. attempt_id is NULL for non-attempt trips (court
-- filing run, picking up papers). rate and deduction are filled by trigger when
-- left NULL (rate from settings.irs_mileage_rate at the time of the trip).
CREATE TABLE IF NOT EXISTS mileage (
  trip_id INTEGER PRIMARY KEY AUTOINCREMENT,
  attempt_id INTEGER,
  trip_date TEXT NOT NULL,                          -- ISO date
  miles REAL NOT NULL CHECK (miles >= 0),
  from_label TEXT,                                  -- 'Home', 'Serve 24-CV-1187 - Marconi Ave'
  to_label TEXT,
  purpose TEXT,                                     -- 'C-2026-0001 attempt 2 round trip'
  rate REAL,                                        -- $/mile snapshot (trigger)
  deduction REAL,                                   -- miles * rate (trigger)
  created_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (attempt_id) REFERENCES attempts(attempt_id) ON DELETE SET NULL
);

-- Invoices: one per client per billing run. invoice_number is filled by trigger
-- if left NULL. due_date is invoice_date + the client's payment_terms_days.
-- line_items is a JSON array with one object per case (case_ref, case_no, client
-- ref, status, attempts, fee breakdown) so the invoice can be regenerated.
CREATE TABLE IF NOT EXISTS invoices (
  invoice_id INTEGER PRIMARY KEY AUTOINCREMENT,
  client_id INTEGER NOT NULL,
  invoice_number TEXT UNIQUE,                       -- 'INV-2026-0001'
  invoice_date TEXT NOT NULL,
  due_date TEXT,
  total_amount REAL NOT NULL,
  paid INTEGER DEFAULT 0,
  paid_date TEXT,
  sent_date TEXT,
  line_items TEXT,                                  -- JSON array
  notes TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (client_id) REFERENCES clients(client_id) ON DELETE CASCADE
);

-- Payouts: what you owe a subcontracted server (agency mode). Exactly one of
-- case_id / attempt_id is set, matching the server's payout_type:
--   per_serve / percent -> case_id   (one payout per case)
--   per_attempt         -> attempt_id (one payout per attempt made)
-- amount is filled by trigger when left NULL: per_serve / per_attempt ->
-- servers.payout_value; percent -> billable_total * payout_value / 100.
-- Never insert a payout for the owner row. Partial UNIQUE indexes below keep
-- one payout per case and one per attempt.
CREATE TABLE IF NOT EXISTS payouts (
  payout_id INTEGER PRIMARY KEY AUTOINCREMENT,
  server_id INTEGER NOT NULL,
  case_id INTEGER,
  attempt_id INTEGER,
  amount REAL,                                      -- trigger fills if NULL
  paid INTEGER DEFAULT 0,
  paid_date TEXT,
  notes TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  CHECK ((case_id IS NOT NULL AND attempt_id IS NULL) OR (case_id IS NULL AND attempt_id IS NOT NULL)),
  FOREIGN KEY (server_id) REFERENCES servers(server_id) ON DELETE CASCADE,
  FOREIGN KEY (case_id) REFERENCES cases(case_id) ON DELETE CASCADE,
  FOREIGN KEY (attempt_id) REFERENCES attempts(attempt_id) ON DELETE CASCADE
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_payouts_case ON payouts(case_id) WHERE case_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS ux_payouts_attempt ON payouts(attempt_id) WHERE attempt_id IS NOT NULL;

-- Indexes for common queries
CREATE INDEX IF NOT EXISTS idx_places_location ON places(zensched_location_id);
CREATE INDEX IF NOT EXISTS idx_cases_client ON cases(client_id, invoiced);
CREATE INDEX IF NOT EXISTS idx_cases_status_due ON cases(status, due_by);
CREATE INDEX IF NOT EXISTS idx_cases_case_no ON cases(case_no);
CREATE INDEX IF NOT EXISTS idx_serve_addresses_case ON serve_addresses(case_id, is_active);
CREATE INDEX IF NOT EXISTS idx_serve_addresses_place ON serve_addresses(place_id);
CREATE INDEX IF NOT EXISTS idx_serve_addresses_event ON serve_addresses(zensched_event_id);
CREATE INDEX IF NOT EXISTS idx_attempts_address ON attempts(serve_address_id, attempt_no);
CREATE INDEX IF NOT EXISTS idx_attempts_start ON attempts(scheduled_start);
CREATE INDEX IF NOT EXISTS idx_attempts_status_start ON attempts(status, scheduled_start);
CREATE INDEX IF NOT EXISTS idx_attempts_server ON attempts(server_id, status);
CREATE INDEX IF NOT EXISTS idx_mileage_date ON mileage(trip_date);
CREATE INDEX IF NOT EXISTS idx_mileage_attempt ON mileage(attempt_id);
CREATE INDEX IF NOT EXISTS idx_invoices_client ON invoices(client_id);
CREATE INDEX IF NOT EXISTS idx_invoices_paid ON invoices(paid, due_date);
CREATE INDEX IF NOT EXISTS idx_payouts_server ON payouts(server_id, paid);

-- What a case bills depends on what happened. This is the single place that
-- rule lives; receivables, invoicing, and payouts read billable_total from here
-- rather than re-deriving it.
--   attempts_made  = attempts with status attempted or served, across ALL of the case's addresses
--   extra_attempts = max(0, attempts_made - included_attempts)
--   served      -> serve_fee + extra_attempts * extra_attempt_fee + rush_fee (if rush) + mileage_fee + other_fee
--   not_served  -> bad_address_fee + extra_attempts * extra_attempt_fee + rush_fee (if rush) + mileage_fee + other_fee
--   cancelled   -> other_fee only (a cancellation / attempts-made charge the agent puts in other_fee)
--   open        -> 0 (nothing billable yet)
CREATE VIEW IF NOT EXISTS billable_cases AS
SELECT
  c.case_id,
  c.case_ref,
  c.case_no,
  COALESCE(c.case_no, c.case_ref)                  AS case_label,
  c.client_id,
  c.client_ref,
  c.court,
  c.document_types,
  c.status,
  c.is_rush,
  c.received_date,
  c.due_by,
  date(c.served_at)                                AS served_date,
  c.served_manner,
  COALESCE(a.attempts_made, 0)                     AS attempts_made,
  c.included_attempts,
  MAX(0, COALESCE(a.attempts_made, 0) - COALESCE(c.included_attempts, 0)) AS extra_attempts,
  c.serve_fee,
  c.extra_attempt_fee,
  CASE WHEN c.is_rush = 1 THEN COALESCE(c.rush_fee, 0) ELSE 0 END AS rush_fee_billed,
  c.mileage_fee,
  c.bad_address_fee,
  c.other_fee,
  round(MAX(0, COALESCE(a.attempts_made, 0) - COALESCE(c.included_attempts, 0)) * COALESCE(c.extra_attempt_fee, 0), 2) AS extra_attempt_total,
  CASE c.status
    WHEN 'served' THEN round(COALESCE(c.serve_fee, 0)
                             + MAX(0, COALESCE(a.attempts_made, 0) - COALESCE(c.included_attempts, 0)) * COALESCE(c.extra_attempt_fee, 0)
                             + CASE WHEN c.is_rush = 1 THEN COALESCE(c.rush_fee, 0) ELSE 0 END
                             + COALESCE(c.mileage_fee, 0) + COALESCE(c.other_fee, 0), 2)
    WHEN 'not_served' THEN round(COALESCE(c.bad_address_fee, 0)
                             + MAX(0, COALESCE(a.attempts_made, 0) - COALESCE(c.included_attempts, 0)) * COALESCE(c.extra_attempt_fee, 0)
                             + CASE WHEN c.is_rush = 1 THEN COALESCE(c.rush_fee, 0) ELSE 0 END
                             + COALESCE(c.mileage_fee, 0) + COALESCE(c.other_fee, 0), 2)
    WHEN 'cancelled' THEN round(COALESCE(c.other_fee, 0), 2)
    ELSE 0
  END                                              AS billable_total,
  c.invoiced,
  c.paid_out,
  c.served_attempt_id
FROM cases c
LEFT JOIN (
  SELECT sa.case_id, COUNT(*) AS attempts_made
  FROM attempts at
  JOIN serve_addresses sa ON sa.serve_address_id = at.serve_address_id
  WHERE at.status IN ('attempted', 'served')
  GROUP BY sa.case_id
) a ON a.case_id = c.case_id;

-- Keep updated_at current
CREATE TRIGGER IF NOT EXISTS update_client_timestamp
AFTER UPDATE ON clients
BEGIN
  UPDATE clients SET updated_at = datetime('now') WHERE client_id = NEW.client_id;
END;

CREATE TRIGGER IF NOT EXISTS update_place_timestamp
AFTER UPDATE ON places
BEGIN
  UPDATE places SET updated_at = datetime('now') WHERE place_id = NEW.place_id;
END;

CREATE TRIGGER IF NOT EXISTS update_server_timestamp
AFTER UPDATE ON servers
BEGIN
  UPDATE servers SET updated_at = datetime('now') WHERE server_id = NEW.server_id;
END;

CREATE TRIGGER IF NOT EXISTS update_case_timestamp
AFTER UPDATE OF client_id, client_ref, case_no, court, plaintiff, servee_name, servee_phone, servee_dob,
                servee_notes, document_types, is_rush, received_date, due_by, status, serve_fee,
                included_attempts, extra_attempt_fee, rush_fee, mileage_fee, bad_address_fee, other_fee,
                served_at, served_manner, served_attempt_id, mailed_at, proof_sent_at, notes, invoiced, paid_out
ON cases
BEGIN
  UPDATE cases SET updated_at = datetime('now') WHERE case_id = NEW.case_id;
END;

CREATE TRIGGER IF NOT EXISTS update_serve_address_timestamp
AFTER UPDATE OF case_id, place_id, address_type, is_active, notes, zensched_event_id, event_valid_until
ON serve_addresses
BEGIN
  UPDATE serve_addresses SET updated_at = datetime('now') WHERE serve_address_id = NEW.serve_address_id;
END;

CREATE TRIGGER IF NOT EXISTS update_attempt_timestamp
AFTER UPDATE OF serve_address_id, server_id, scheduled_start, duration_minutes, is_adhoc, status, outcome,
                manner, served_person, person_description, vehicles_seen, docs_left, photo_count,
                zensched_shift_id, record_dc_id, checked_in_at, checked_out_at, gps_verified,
                checkin_distance_m, notes
ON attempts
BEGIN
  UPDATE attempts SET updated_at = datetime('now') WHERE attempt_id = NEW.attempt_id;
END;

-- Auto-number cases: C-2026-0001, C-2026-0002, ... (year received, sequence =
-- case_id, so numbers never collide or reset). An explicit case_ref is kept.
CREATE TRIGGER IF NOT EXISTS number_case
AFTER INSERT ON cases
WHEN NEW.case_ref IS NULL
BEGIN
  UPDATE cases
  SET case_ref = 'C-' || strftime('%Y', COALESCE(NEW.received_date, date('now', 'localtime'))) || '-' || printf('%04d', NEW.case_id)
  WHERE case_id = NEW.case_id;
END;

-- Fill fee defaults the agent left NULL:
--   serve_fee / extra_attempt_fee / rush_fee / bad_address_fee <- clients.default_*, else 0
--   included_attempts <- clients.default_included_attempts, else settings.default_included_attempts, else 3
--   mileage_fee / other_fee <- 0
-- Fees are snapshots: changing a client's defaults later never rewrites history.
CREATE TRIGGER IF NOT EXISTS fill_case_defaults
AFTER INSERT ON cases
BEGIN
  UPDATE cases
  SET serve_fee         = COALESCE(NEW.serve_fee,         (SELECT default_serve_fee         FROM clients WHERE client_id = NEW.client_id), 0),
      included_attempts = COALESCE(NEW.included_attempts, (SELECT default_included_attempts FROM clients WHERE client_id = NEW.client_id),
                                   (SELECT CAST(value AS INTEGER) FROM settings WHERE key = 'default_included_attempts'), 3),
      extra_attempt_fee = COALESCE(NEW.extra_attempt_fee, (SELECT default_extra_attempt_fee FROM clients WHERE client_id = NEW.client_id), 0),
      rush_fee          = COALESCE(NEW.rush_fee,          (SELECT default_rush_fee          FROM clients WHERE client_id = NEW.client_id), 0),
      bad_address_fee   = COALESCE(NEW.bad_address_fee,   (SELECT default_bad_address_fee   FROM clients WHERE client_id = NEW.client_id), 0),
      mileage_fee       = COALESCE(NEW.mileage_fee, 0),
      other_fee         = COALESCE(NEW.other_fee, 0)
  WHERE case_id = NEW.case_id;
END;

-- Number attempts per serve address: the first attempt at an address is 1, the
-- next 2, ... independently of attempts at the case's other addresses. An
-- explicit attempt_no is kept.
CREATE TRIGGER IF NOT EXISTS number_attempt
AFTER INSERT ON attempts
WHEN NEW.attempt_no IS NULL
BEGIN
  UPDATE attempts
  SET attempt_no = (SELECT COALESCE(MAX(attempt_no), 0) + 1
                    FROM attempts
                    WHERE serve_address_id = NEW.serve_address_id AND attempt_id <> NEW.attempt_id)
  WHERE attempt_id = NEW.attempt_id;
END;

-- Fill defaults the agent left NULL:
--   duration_minutes <- settings.default_attempt_minutes (else 20)
--   server_id        <- settings.default_server_id (solo mode: you)
CREATE TRIGGER IF NOT EXISTS fill_attempt_defaults
AFTER INSERT ON attempts
BEGIN
  UPDATE attempts
  SET duration_minutes = COALESCE(NEW.duration_minutes,
                                  (SELECT CAST(value AS INTEGER) FROM settings WHERE key = 'default_attempt_minutes'),
                                  20),
      server_id = COALESCE(NEW.server_id,
                           (SELECT CAST(value AS INTEGER) FROM settings WHERE key = 'default_server_id' AND value IS NOT NULL))
  WHERE attempt_id = NEW.attempt_id;
END;

-- Mileage: snapshot the IRS rate and compute the deduction.
CREATE TRIGGER IF NOT EXISTS fill_mileage_deduction
AFTER INSERT ON mileage
BEGIN
  UPDATE mileage
  SET rate = COALESCE(NEW.rate, (SELECT CAST(value AS REAL) FROM settings WHERE key = 'irs_mileage_rate'), 0),
      deduction = round(NEW.miles * COALESCE(NEW.rate, (SELECT CAST(value AS REAL) FROM settings WHERE key = 'irs_mileage_rate'), 0), 2)
  WHERE trip_id = NEW.trip_id;
END;

CREATE TRIGGER IF NOT EXISTS recompute_mileage_deduction
AFTER UPDATE OF miles, rate ON mileage
BEGIN
  UPDATE mileage SET deduction = round(NEW.miles * COALESCE(NEW.rate, 0), 2) WHERE trip_id = NEW.trip_id;
END;

-- Auto-number invoices: INV-2026-0001, INV-2026-0002, ...
CREATE TRIGGER IF NOT EXISTS number_invoice
AFTER INSERT ON invoices
WHEN NEW.invoice_number IS NULL
BEGIN
  UPDATE invoices
  SET invoice_number = (SELECT COALESCE(value, 'INV') FROM settings WHERE key = 'invoice_prefix')
                       || '-' || strftime('%Y', NEW.invoice_date)
                       || '-' || printf('%04d', NEW.invoice_id)
  WHERE invoice_id = NEW.invoice_id;
END;

-- Payout amount from the server's split when the agent leaves it NULL.
-- per_serve   -> payout_value (row must carry case_id)
-- per_attempt -> payout_value (row must carry attempt_id)
-- percent     -> billable_total of the case * payout_value / 100, rounded to cents
-- If the server has no payout_type, or the row's key does not match the type,
-- the amount stays NULL and payouts_due flags it (needs_amount = 1).
CREATE TRIGGER IF NOT EXISTS fill_payout_amount
AFTER INSERT ON payouts
WHEN NEW.amount IS NULL
BEGIN
  UPDATE payouts
  SET amount = (SELECT CASE
                         WHEN s.payout_type = 'per_serve'   AND NEW.case_id IS NOT NULL    THEN s.payout_value
                         WHEN s.payout_type = 'per_attempt' AND NEW.attempt_id IS NOT NULL THEN s.payout_value
                         WHEN s.payout_type = 'percent'     AND NEW.case_id IS NOT NULL
                           THEN round((SELECT b.billable_total FROM billable_cases b WHERE b.case_id = NEW.case_id) * s.payout_value / 100.0, 2)
                       END
                FROM servers s
                WHERE s.server_id = NEW.server_id)
  WHERE payout_id = NEW.payout_id;
END;

-- Every ACTIVE serve address on an OPEN case with what it needs on ZenSched.
-- The agent runs this right after intake (and when a new address arrives) so
-- every address has a location and a current event BEFORE anyone stands at the
-- door: an "I'm here now" attempt is then a single shift_create.
--   needs_location = 1 -> location_create ($0.03)
--   needs_event    = 1 -> no event, or the event has expired (event_valid_until < today):
--                         event_create (free) + form_assign, window = event_start_date .. event_end_date
--   event_start_date = today; event_end_date = min(case due_by, today + 59 days), never before today
CREATE VIEW IF NOT EXISTS serve_addresses_sync AS
SELECT
  sa.serve_address_id,
  sa.address_type,
  sa.is_active,
  c.case_id,
  c.case_ref,
  c.case_no,
  COALESCE(c.case_no, c.case_ref)                  AS case_label,
  c.due_by,
  cl.client_name,
  p.place_id,
  p.address || COALESCE(', ' || p.city, '') || COALESCE(', ' || p.state, '') || COALESCE(' ' || p.zip, '') AS street_address,
  COALESCE(p.place_label, 'Serve ' || COALESCE(c.case_no, c.case_ref) || ' - ' || COALESCE(p.street_name, p.address)) AS zensched_location_name,
  'Serve ' || COALESCE(c.case_no, c.case_ref) || ' - ' || COALESCE(p.street_name, p.address)                          AS zensched_event_title,
  p.zensched_location_id,
  CASE WHEN p.zensched_location_id IS NULL THEN 1 ELSE 0 END                      AS needs_location,
  sa.zensched_event_id,
  sa.event_valid_until,
  CASE WHEN sa.zensched_event_id IS NULL OR sa.event_valid_until IS NULL
            OR sa.event_valid_until < date('now', 'localtime') THEN 1 ELSE 0 END  AS needs_event,
  date('now', 'localtime')                                                        AS event_start_date,
  CASE
    WHEN c.due_by IS NULL OR c.due_by > date('now', 'localtime', '+59 days') THEN date('now', 'localtime', '+59 days')
    WHEN c.due_by < date('now', 'localtime') THEN date('now', 'localtime')
    ELSE c.due_by
  END                                                                             AS event_end_date,
  (SELECT COUNT(*) FROM attempts at WHERE at.serve_address_id = sa.serve_address_id AND at.status = 'planned') AS planned_attempts,
  (SELECT COUNT(*) FROM attempts at WHERE at.serve_address_id = sa.serve_address_id AND at.status IN ('attempted', 'served')) AS attempts_made,
  'loc-place-' || p.place_id                                                      AS loc_idempotency_key,
  'event-sa-' || sa.serve_address_id || '-' || strftime('%Y%m%d', 'now', 'localtime') AS event_idempotency_key
FROM serve_addresses sa
JOIN cases c ON c.case_id = sa.case_id
JOIN clients cl ON cl.client_id = c.client_id
JOIN places p ON p.place_id = sa.place_id
WHERE c.status = 'open' AND sa.is_active = 1
ORDER BY c.case_id, sa.serve_address_id;

-- Every planned attempt (any date) with everything the agent needs to put it
-- on ZenSched. start_iso / end_iso carry settings.timezone_offset and are ready
-- for shift_create. The idempotency keys and the ZenSched-safe names are ready
-- too. Use attempts_upcoming (below) for the next 7 days; use this view right
-- after intake when the first window is further out.
--   needs_location = 1 -> the place has no ZenSched location yet (location_create)
--   needs_event    = 1 -> the serve address has no event, or its event ends before this attempt (event_create + form_assign)
--   needs_shift    = 1 -> the attempt has no ZenSched shift yet (shift_create)
--   event_start_date / event_end_date -> the window to use when needs_event = 1:
--     start = the attempt date; end = min(case due_by, start + 59 days), never before start
CREATE VIEW IF NOT EXISTS attempts_planned AS
SELECT
  at.attempt_id,
  at.attempt_no,
  at.status,
  at.is_adhoc,
  at.scheduled_start,
  at.duration_minutes,
  strftime('%Y-%m-%dT%H:%M:%S', at.scheduled_start)
    || (SELECT value FROM settings WHERE key = 'timezone_offset')                 AS start_iso,
  strftime('%Y-%m-%dT%H:%M:%S', datetime(at.scheduled_start, '+' || at.duration_minutes || ' minutes'))
    || (SELECT value FROM settings WHERE key = 'timezone_offset')                 AS end_iso,
  CASE
    WHEN CAST(strftime('%w', at.scheduled_start) AS INTEGER) IN (0, 6) THEN 'weekend'
    WHEN CAST(strftime('%H', at.scheduled_start) AS INTEGER) < 12 THEN 'morning'
    WHEN CAST(strftime('%H', at.scheduled_start) AS INTEGER) < 17 THEN 'afternoon'
    ELSE 'evening'
  END                                                                             AS day_part,
  c.case_id,
  c.case_ref,
  c.case_no,
  COALESCE(c.case_no, c.case_ref)                                                 AS case_label,
  c.client_ref,
  c.court,
  c.document_types,
  c.servee_name,
  c.servee_phone,
  c.servee_notes,
  c.is_rush,
  c.due_by,
  CASE WHEN c.due_by IS NOT NULL
       THEN CAST(julianday(c.due_by) - julianday(date('now', 'localtime')) AS INTEGER) END AS days_left,
  c.included_attempts,
  cl.client_id,
  cl.client_name,
  sa.serve_address_id,
  sa.address_type,
  sa.notes                                                                        AS address_notes,
  p.place_id,
  p.address,
  p.city,
  p.state,
  p.zip,
  p.address || COALESCE(', ' || p.city, '') || COALESCE(', ' || p.state, '') || COALESCE(' ' || p.zip, '') AS street_address,
  COALESCE(p.place_label, 'Serve ' || COALESCE(c.case_no, c.case_ref) || ' - ' || COALESCE(p.street_name, p.address)) AS zensched_location_name,
  'Serve ' || COALESCE(c.case_no, c.case_ref) || ' - ' || COALESCE(p.street_name, p.address)                          AS zensched_event_title,
  p.access_notes                                                                  AS place_access_notes,
  p.is_repeat_site,
  p.zensched_location_id,
  CASE WHEN p.zensched_location_id IS NULL THEN 1 ELSE 0 END                      AS needs_location,
  sa.zensched_event_id,
  sa.event_valid_until,
  CASE WHEN sa.zensched_event_id IS NULL OR sa.event_valid_until IS NULL
            OR sa.event_valid_until < date(at.scheduled_start) THEN 1 ELSE 0 END  AS needs_event,
  date(at.scheduled_start)                                                        AS event_start_date,
  CASE
    WHEN c.due_by IS NULL OR c.due_by > date(at.scheduled_start, '+59 days') THEN date(at.scheduled_start, '+59 days')
    WHEN c.due_by < date(at.scheduled_start) THEN date(at.scheduled_start)
    ELSE c.due_by
  END                                                                             AS event_end_date,
  at.zensched_shift_id,
  CASE WHEN at.zensched_shift_id IS NULL THEN 1 ELSE 0 END                        AS needs_shift,
  at.server_id,
  s.server_name,
  s.zensched_worker_id,
  at.notes,
  'loc-place-' || p.place_id                                                      AS loc_idempotency_key,
  'event-sa-' || sa.serve_address_id || '-' || strftime('%Y%m%d', at.scheduled_start) AS event_idempotency_key,
  'shift-attempt-' || at.attempt_id                                               AS shift_idempotency_key
FROM attempts at
JOIN serve_addresses sa ON sa.serve_address_id = at.serve_address_id
JOIN cases c ON c.case_id = sa.case_id
JOIN clients cl ON cl.client_id = c.client_id
JOIN places p ON p.place_id = sa.place_id
LEFT JOIN servers s ON s.server_id = at.server_id
WHERE at.status = 'planned'
ORDER BY at.scheduled_start;

-- Same columns, next 7 days (today through today + 6, local date of the
-- computer running the database).
CREATE VIEW IF NOT EXISTS attempts_upcoming AS
SELECT *
FROM attempts_planned
WHERE date(scheduled_start) BETWEEN date('now', 'localtime') AND date('now', 'localtime', '+6 days')
ORDER BY scheduled_start;

-- Open cases: what is still to be served, how far along each is, and how close
-- the deadline is. attempts_made counts attempted + served rows across all of
-- the case's addresses; next_planned is the earliest planned window from now.
--   overdue_risk: overdue (past due_by) | high (<= 3 days left, or <= 7 days with
--   nothing planned) | medium (<= 7 days) | low | no_deadline
CREATE VIEW IF NOT EXISTS cases_open AS
SELECT
  c.case_id,
  c.case_ref,
  c.case_no,
  COALESCE(c.case_no, c.case_ref)                  AS case_label,
  cl.client_id,
  cl.client_name,
  c.client_ref,
  c.court,
  c.document_types,
  c.servee_name,
  c.is_rush,
  c.received_date,
  c.due_by,
  CASE WHEN c.due_by IS NOT NULL
       THEN CAST(julianday(c.due_by) - julianday(date('now', 'localtime')) AS INTEGER) END AS days_left,
  COALESCE(a.attempts_made, 0)                     AS attempts_made,
  c.included_attempts,
  COALESCE(a.addresses_tried, 0)                   AS addresses_tried,
  (SELECT COUNT(*) FROM serve_addresses sa WHERE sa.case_id = c.case_id AND sa.is_active = 1) AS active_addresses,
  (SELECT COUNT(*) FROM serve_addresses sa WHERE sa.case_id = c.case_id)                      AS total_addresses,
  a.last_attempt_at,
  a.last_outcome,
  np.next_planned,
  np.next_planned_attempt_id,
  CASE
    WHEN c.due_by IS NULL THEN 'no_deadline'
    WHEN c.due_by < date('now', 'localtime') THEN 'overdue'
    WHEN julianday(c.due_by) - julianday(date('now', 'localtime')) <= 3 THEN 'high'
    WHEN julianday(c.due_by) - julianday(date('now', 'localtime')) <= 7 AND np.next_planned IS NULL THEN 'high'
    WHEN julianday(c.due_by) - julianday(date('now', 'localtime')) <= 7 THEN 'medium'
    ELSE 'low'
  END                                              AS overdue_risk,
  c.notes
FROM cases c
JOIN clients cl ON cl.client_id = c.client_id
LEFT JOIN (
  SELECT sa.case_id,
         COUNT(*)                                   AS attempts_made,
         COUNT(DISTINCT sa.serve_address_id)        AS addresses_tried,
         MAX(COALESCE(substr(at.checked_in_at, 1, 16), at.scheduled_start)) AS last_attempt_at,
         (SELECT at2.outcome FROM attempts at2 JOIN serve_addresses sa2 ON sa2.serve_address_id = at2.serve_address_id
          WHERE sa2.case_id = sa.case_id AND at2.status IN ('attempted', 'served')
          ORDER BY COALESCE(at2.checked_in_at, at2.scheduled_start) DESC LIMIT 1) AS last_outcome
  FROM attempts at
  JOIN serve_addresses sa ON sa.serve_address_id = at.serve_address_id
  WHERE at.status IN ('attempted', 'served')
  GROUP BY sa.case_id
) a ON a.case_id = c.case_id
LEFT JOIN (
  SELECT sa.case_id,
         MIN(at.scheduled_start)                    AS next_planned,
         (SELECT at2.attempt_id FROM attempts at2 JOIN serve_addresses sa2 ON sa2.serve_address_id = at2.serve_address_id
          WHERE sa2.case_id = sa.case_id AND at2.status = 'planned' AND at2.scheduled_start >= strftime('%Y-%m-%dT%H:%M', 'now', 'localtime')
          ORDER BY at2.scheduled_start LIMIT 1)     AS next_planned_attempt_id
  FROM attempts at
  JOIN serve_addresses sa ON sa.serve_address_id = at.serve_address_id
  WHERE at.status = 'planned' AND at.scheduled_start >= strftime('%Y-%m-%dT%H:%M', 'now', 'localtime')
  GROUP BY sa.case_id
) np ON np.case_id = c.case_id
WHERE c.status = 'open'
ORDER BY CASE
           WHEN c.due_by IS NULL THEN 3
           WHEN c.due_by < date('now', 'localtime') THEN 0
           WHEN julianday(c.due_by) - julianday(date('now', 'localtime')) <= 3 THEN 1
           ELSE 2
         END,
         c.due_by, c.case_id;

-- THE PRODUCT: every attempt actually made on a case, in the order it happened,
-- with everything a declaration of diligence asks for. One row per attempt.
--   seq          = 1, 2, 3 ... across the whole case (all addresses), the number you
--                  write in the affidavit; attempt_no is the number at that address
--   attempt_date, weekday, time_in / time_out = LOCAL wall clock, 12-hour, from the
--                  GPS punches when present (time_source = 'gps'), else the planned
--                  window (time_source = 'scheduled'; say so in the affidavit)
--   minutes_on_site, gps_verified, checkin_distance_m = from the punches
--   day_part     = morning / afternoon / evening / weekend (courts look for variety)
--   manner, outcome, served_person, person_description, vehicles_seen, docs_left,
--   photo_count, notes = from the Attempt Record
--   server_name, license_no = who made the attempt (license_no is local; put it on
--                  the affidavit yourself)
-- ISO offsets are stripped with substr() before formatting; SQLite would
-- otherwise convert a '-05:00' timestamp to UTC.
CREATE VIEW IF NOT EXISTS due_diligence_log AS
SELECT
  c.case_id,
  c.case_ref,
  c.case_no,
  COALESCE(c.case_no, c.case_ref)                  AS case_label,
  c.court,
  c.document_types,
  cl.client_name,
  c.client_ref,
  ROW_NUMBER() OVER (PARTITION BY c.case_id
                     ORDER BY COALESCE(substr(at.checked_in_at, 1, 19), at.scheduled_start), at.attempt_id) AS seq,
  at.attempt_id,
  at.attempt_no,
  sa.serve_address_id,
  sa.address_type,
  p.address || COALESCE(', ' || p.city, '') || COALESCE(', ' || p.state, '') || COALESCE(' ' || p.zip, '') AS street_address,
  date(COALESCE(substr(at.checked_in_at, 1, 19), at.scheduled_start))                  AS attempt_date,
  CASE strftime('%w', COALESCE(substr(at.checked_in_at, 1, 19), at.scheduled_start))
    WHEN '0' THEN 'Sunday' WHEN '1' THEN 'Monday' WHEN '2' THEN 'Tuesday' WHEN '3' THEN 'Wednesday'
    WHEN '4' THEN 'Thursday' WHEN '5' THEN 'Friday' ELSE 'Saturday' END                AS weekday,
  CASE WHEN at.checked_in_at IS NOT NULL THEN 'gps' ELSE 'scheduled' END                AS time_source,
  -- 12-hour local time in: 'h:MM am/pm'
  (CASE CAST(strftime('%H', COALESCE(substr(at.checked_in_at, 1, 19), at.scheduled_start)) AS INTEGER) % 12
     WHEN 0 THEN '12' ELSE CAST(CAST(strftime('%H', COALESCE(substr(at.checked_in_at, 1, 19), at.scheduled_start)) AS INTEGER) % 12 AS TEXT) END)
    || ':' || strftime('%M', COALESCE(substr(at.checked_in_at, 1, 19), at.scheduled_start))
    || CASE WHEN CAST(strftime('%H', COALESCE(substr(at.checked_in_at, 1, 19), at.scheduled_start)) AS INTEGER) < 12 THEN ' am' ELSE ' pm' END AS time_in,
  CASE WHEN at.checked_out_at IS NOT NULL THEN
    (CASE CAST(strftime('%H', substr(at.checked_out_at, 1, 19)) AS INTEGER) % 12
       WHEN 0 THEN '12' ELSE CAST(CAST(strftime('%H', substr(at.checked_out_at, 1, 19)) AS INTEGER) % 12 AS TEXT) END)
      || ':' || strftime('%M', substr(at.checked_out_at, 1, 19))
      || CASE WHEN CAST(strftime('%H', substr(at.checked_out_at, 1, 19)) AS INTEGER) < 12 THEN ' am' ELSE ' pm' END
  END                                                                                   AS time_out,
  substr(COALESCE(substr(at.checked_in_at, 1, 19), at.scheduled_start), 12, 5)          AS time_in_24h,
  CASE WHEN at.checked_out_at IS NOT NULL THEN substr(at.checked_out_at, 12, 5) END       AS time_out_24h,
  CASE WHEN at.checked_in_at IS NOT NULL AND at.checked_out_at IS NOT NULL
       THEN CAST(round((julianday(at.checked_out_at) - julianday(at.checked_in_at)) * 1440.0) AS INTEGER) END AS minutes_on_site,
  CASE
    WHEN CAST(strftime('%w', COALESCE(substr(at.checked_in_at, 1, 19), at.scheduled_start)) AS INTEGER) IN (0, 6) THEN 'weekend'
    WHEN CAST(strftime('%H', COALESCE(substr(at.checked_in_at, 1, 19), at.scheduled_start)) AS INTEGER) < 12 THEN 'morning'
    WHEN CAST(strftime('%H', COALESCE(substr(at.checked_in_at, 1, 19), at.scheduled_start)) AS INTEGER) < 17 THEN 'afternoon'
    ELSE 'evening'
  END                                              AS day_part,
  at.status,
  at.manner,
  at.outcome,
  at.served_person,
  at.person_description,
  at.vehicles_seen,
  at.docs_left,
  at.photo_count,
  at.gps_verified,
  at.checkin_distance_m,
  at.is_adhoc,
  s.server_name,
  s.license_no,
  at.zensched_shift_id,
  at.record_dc_id,
  at.checked_in_at,
  at.checked_out_at,
  at.notes
FROM attempts at
JOIN serve_addresses sa ON sa.serve_address_id = at.serve_address_id
JOIN cases c ON c.case_id = sa.case_id
JOIN clients cl ON cl.client_id = c.client_id
JOIN places p ON p.place_id = sa.place_id
LEFT JOIN servers s ON s.server_id = at.server_id
WHERE at.status IN ('attempted', 'served')
ORDER BY c.case_id, COALESCE(substr(at.checked_in_at, 1, 19), at.scheduled_start), at.attempt_id;

-- FLAG ONLY. Open cases where the attempts made have reached the case's
-- included_attempts and nobody has been served. Whether that satisfies YOUR
-- state's diligence rule (days, times of day, addresses, mailing) is the
-- server's decision; this view just counts. distinct_days / distinct_day_parts
-- / addresses_tried are there so the owner can see the variety at a glance.
CREATE VIEW IF NOT EXISTS cases_ready_for_substitute AS
SELECT
  c.case_id,
  c.case_ref,
  c.case_no,
  COALESCE(c.case_no, c.case_ref)                  AS case_label,
  cl.client_name,
  c.client_ref,
  c.court,
  c.document_types,
  c.servee_name,
  c.due_by,
  c.included_attempts,
  COUNT(*)                                         AS attempts_made,
  COUNT(DISTINCT d.attempt_date)                   AS distinct_days,
  COUNT(DISTINCT d.day_part)                       AS distinct_day_parts,
  COUNT(DISTINCT d.serve_address_id)               AS addresses_tried,
  SUM(CASE WHEN d.photo_count > 0 THEN 1 ELSE 0 END) AS attempts_with_photo,
  SUM(CASE WHEN d.gps_verified = 1 THEN 1 ELSE 0 END) AS attempts_gps_verified,
  MIN(d.attempt_date)                              AS first_attempt_date,
  MAX(d.attempt_date)                              AS last_attempt_date
FROM cases c
JOIN clients cl ON cl.client_id = c.client_id
JOIN due_diligence_log d ON d.case_id = c.case_id
WHERE c.status = 'open'
GROUP BY c.case_id
HAVING COUNT(*) >= COALESCE(c.included_attempts, 3)
ORDER BY c.due_by, c.case_id;

-- SAFETY RECORD, NOT A PANIC BUTTON. Attempts whose check-in has been copied
-- locally but with no check-out, once the planned window plus 30 minutes has
-- passed. Only as fresh as the last shift_status pull; SKILL.md pairs it with a
-- live shift_list(status="checked_in") call.
CREATE VIEW IF NOT EXISTS open_attempts_now AS
SELECT
  at.attempt_id,
  at.attempt_no,
  COALESCE(c.case_no, c.case_ref)                  AS case_label,
  at.scheduled_start,
  at.duration_minutes,
  strftime('%Y-%m-%dT%H:%M', datetime(at.scheduled_start, '+' || at.duration_minutes || ' minutes')) AS scheduled_end,
  at.checked_in_at,
  CAST(round((julianday(datetime('now', 'localtime')) - julianday(substr(at.checked_in_at, 1, 19))) * 1440.0) AS INTEGER) AS minutes_since_checkin,
  p.address || COALESCE(', ' || p.city, '') || COALESCE(', ' || p.state, '') || COALESCE(' ' || p.zip, '') AS street_address,
  sa.address_type,
  s.server_id,
  s.server_name,
  s.phone                                          AS server_phone,
  at.zensched_shift_id,
  at.gps_verified,
  at.checkin_distance_m,
  at.is_adhoc
FROM attempts at
JOIN serve_addresses sa ON sa.serve_address_id = at.serve_address_id
JOIN cases c ON c.case_id = sa.case_id
JOIN places p ON p.place_id = sa.place_id
LEFT JOIN servers s ON s.server_id = at.server_id
WHERE at.checked_in_at IS NOT NULL
  AND at.checked_out_at IS NULL
  AND at.status <> 'cancelled'
  AND datetime(at.scheduled_start, '+' || at.duration_minutes || ' minutes', '+30 minutes') < datetime('now', 'localtime')
ORDER BY at.checked_in_at;

-- Uninvoiced billable work grouped by client, with the billing contact and
-- terms. Served cases bill the serve fee plus extras; non-service bills the
-- bad-address fee plus extras; cancellations bill other_fee only.
CREATE VIEW IF NOT EXISTS receivables_by_client AS
SELECT
  cl.client_id,
  cl.client_name,
  cl.client_type,
  cl.contact_name,
  cl.billing_email,
  cl.payment_terms_days,
  COUNT(b.case_id)                                 AS case_count,
  SUM(CASE WHEN b.status = 'served' THEN 1 ELSE 0 END)     AS served_count,
  SUM(CASE WHEN b.status = 'not_served' THEN 1 ELSE 0 END) AS not_served_count,
  SUM(b.attempts_made)                             AS attempts_made,
  SUM(b.extra_attempts)                            AS extra_attempts,
  SUM(b.billable_total)                            AS total_billable,
  MIN(b.received_date)                             AS first_date,
  MAX(COALESCE(b.served_date, b.received_date))    AS last_date
FROM billable_cases b
JOIN clients cl ON cl.client_id = b.client_id
WHERE b.invoiced = 0
  AND b.status IN ('served', 'not_served', 'cancelled')
  AND b.billable_total > 0
GROUP BY cl.client_id
ORDER BY total_billable DESC;

-- Unpaid invoices with aging. days_past_due is negative while not yet due.
--   current : not yet due
--   30      : 1-30 days past due
--   60      : 31-60 days past due
--   90+     : more than 60 days past due (chase now; stop taking their work?)
CREATE VIEW IF NOT EXISTS invoices_outstanding AS
SELECT
  i.invoice_id,
  i.invoice_number,
  cl.client_id,
  cl.client_name,
  cl.client_type,
  cl.contact_name,
  cl.billing_email,
  cl.payment_terms_days,
  i.invoice_date,
  i.due_date,
  i.sent_date,
  i.total_amount,
  CAST(julianday(date('now', 'localtime')) - julianday(i.due_date) AS INTEGER) AS days_past_due,
  CASE
    WHEN julianday(date('now', 'localtime')) - julianday(i.due_date) <= 0  THEN 'current'
    WHEN julianday(date('now', 'localtime')) - julianday(i.due_date) <= 30 THEN '30'
    WHEN julianday(date('now', 'localtime')) - julianday(i.due_date) <= 60 THEN '60'
    ELSE '90+'
  END                                              AS aging_bucket,
  CASE WHEN i.due_date < date('now', 'localtime') THEN 1 ELSE 0 END AS overdue
FROM invoices i
JOIN clients cl ON cl.client_id = i.client_id
WHERE i.paid = 0
ORDER BY i.due_date;

-- Mileage by calendar month: trips, miles, and the deduction at the snapshot rate.
CREATE VIEW IF NOT EXISTS mileage_by_month AS
SELECT
  strftime('%Y-%m', m.trip_date)                   AS month,
  COUNT(m.trip_id)                                 AS trips,
  SUM(m.miles)                                     AS miles,
  SUM(m.deduction)                                 AS deduction,
  SUM(CASE WHEN m.attempt_id IS NULL THEN m.miles ELSE 0 END) AS non_attempt_miles
FROM mileage m
GROUP BY strftime('%Y-%m', m.trip_date)
ORDER BY month DESC;

-- Agency mode: unpaid sub payouts, one row per payout (a case for per_serve /
-- percent subs, an attempt for per_attempt subs), with a running total per
-- server (server_total_due). Owner rows never appear.
-- needs_amount = 1 means the server has no payout_type (or the row's key did
-- not match it); ask the owner.
CREATE VIEW IF NOT EXISTS payouts_due AS
SELECT
  p.payout_id,
  s.server_id,
  s.server_name,
  s.email,
  s.payout_type,
  s.payout_value,
  p.case_id,
  p.attempt_id,
  COALESCE(c.case_no, c.case_ref)                  AS case_label,
  c.status                                         AS case_status,
  CASE WHEN p.attempt_id IS NOT NULL
       THEN date(COALESCE(substr(at.checked_in_at, 1, 19), at.scheduled_start))
       ELSE date(c.served_at) END                  AS work_date,
  at.attempt_no,
  at.outcome,
  b.billable_total,
  p.amount,
  CASE WHEN p.amount IS NULL THEN 1 ELSE 0 END     AS needs_amount,
  SUM(p.amount) OVER (PARTITION BY s.server_id)    AS server_total_due,
  c.invoiced                                       AS client_invoiced
FROM payouts p
JOIN servers s ON s.server_id = p.server_id
LEFT JOIN attempts at ON at.attempt_id = p.attempt_id
LEFT JOIN serve_addresses sa ON sa.serve_address_id = at.serve_address_id
JOIN cases c ON c.case_id = COALESCE(p.case_id, sa.case_id)
JOIN billable_cases b ON b.case_id = c.case_id
WHERE p.paid = 0
  AND s.is_owner = 0
ORDER BY s.server_name, work_date;

-- Agency mode: work done by a sub that has no payouts row yet. The agent
-- inserts one per row when recording results.
--   per_attempt subs: every attempted / served attempt of theirs without a payout
--   per_serve / percent subs: every served / not_served case whose serving attempt
--     (or, for non-service, most recent attempt) is theirs, without a payout
-- key_type tells the agent which column to fill on the INSERT.
CREATE VIEW IF NOT EXISTS payouts_missing AS
SELECT
  'attempt'                                        AS key_type,
  s.server_id,
  s.server_name,
  s.payout_type,
  s.payout_value,
  sa.case_id,
  COALESCE(c.case_no, c.case_ref)                  AS case_label,
  at.attempt_id,
  at.attempt_no,
  date(COALESCE(substr(at.checked_in_at, 1, 19), at.scheduled_start)) AS work_date,
  at.outcome,
  b.billable_total
FROM attempts at
JOIN servers s ON s.server_id = at.server_id AND s.is_owner = 0 AND s.payout_type = 'per_attempt'
JOIN serve_addresses sa ON sa.serve_address_id = at.serve_address_id
JOIN cases c ON c.case_id = sa.case_id
JOIN billable_cases b ON b.case_id = c.case_id
WHERE at.status IN ('attempted', 'served')
  AND NOT EXISTS (SELECT 1 FROM payouts p WHERE p.attempt_id = at.attempt_id)
UNION ALL
SELECT
  'case'                                           AS key_type,
  s.server_id,
  s.server_name,
  s.payout_type,
  s.payout_value,
  c.case_id,
  COALESCE(c.case_no, c.case_ref)                  AS case_label,
  NULL                                             AS attempt_id,
  NULL                                             AS attempt_no,
  date(COALESCE(c.served_at, substr(last.checked_in_at, 1, 19), last.scheduled_start)) AS work_date,
  last.outcome,
  b.billable_total
FROM cases c
JOIN billable_cases b ON b.case_id = c.case_id
JOIN attempts last ON last.attempt_id = COALESCE(
  c.served_attempt_id,
  (SELECT at2.attempt_id FROM attempts at2 JOIN serve_addresses sa2 ON sa2.serve_address_id = at2.serve_address_id
   WHERE sa2.case_id = c.case_id AND at2.status IN ('attempted', 'served')
   ORDER BY COALESCE(at2.checked_in_at, at2.scheduled_start) DESC LIMIT 1))
JOIN servers s ON s.server_id = last.server_id AND s.is_owner = 0 AND s.payout_type IN ('per_serve', 'percent')
WHERE c.status IN ('served', 'not_served')
  AND NOT EXISTS (SELECT 1 FROM payouts p WHERE p.case_id = c.case_id)
ORDER BY work_date;

-- Per server, last 30 days: attempts made, serves effected, ad hoc share, and
-- the share of attempts whose check-in was GPS-verified. "Did Luis actually go"
-- in aggregate. Owner included so the solo server sees their own numbers.
CREATE VIEW IF NOT EXISTS server_activity AS
SELECT
  s.server_id,
  s.server_name,
  s.is_owner,
  s.is_active,
  COUNT(at.attempt_id)                             AS attempts_30d,
  SUM(CASE WHEN at.status = 'served' THEN 1 ELSE 0 END)            AS served_30d,
  SUM(CASE WHEN at.is_adhoc = 1 THEN 1 ELSE 0 END)                 AS adhoc_30d,
  SUM(CASE WHEN at.gps_verified = 1 THEN 1 ELSE 0 END)             AS gps_verified_30d,
  CASE WHEN COUNT(at.attempt_id) > 0
       THEN round(100.0 * SUM(CASE WHEN at.gps_verified = 1 THEN 1 ELSE 0 END) / COUNT(at.attempt_id), 1) END AS gps_verified_pct,
  SUM(CASE WHEN at.photo_count > 0 THEN 1 ELSE 0 END)              AS with_photo_30d,
  MAX(COALESCE(substr(at.checked_in_at, 1, 16), at.scheduled_start)) AS last_attempt_at,
  (SELECT COUNT(*) FROM attempts a2 WHERE a2.server_id = s.server_id AND a2.status = 'planned'
     AND a2.scheduled_start >= strftime('%Y-%m-%dT%H:%M', 'now', 'localtime'))                    AS planned_ahead
FROM servers s
LEFT JOIN attempts at ON at.server_id = s.server_id
  AND at.status IN ('attempted', 'served')
  AND date(COALESCE(substr(at.checked_in_at, 1, 19), at.scheduled_start)) >= date('now', 'localtime', '-30 days')
GROUP BY s.server_id
ORDER BY attempts_30d DESC, s.server_name;
