# Example Workflow: What the AI Does Behind Each Request

This shows the exact tool calls the agent makes for a first week of operation, following `SKILL.md`. The owner only types the quoted lines; everything else is the agent's work. Assumes setup from `QUICKSTART.md` is complete (both MCP servers configured, `schema.sql` loaded, `SKILL.md` given as instructions).

The business is **Northstar Legal Process**, a solo server (Dana Whitfield) in Minneapolis, Minnesota, Central time (`-05:00` in September), with one 1099 sub (Luis Ortega) who works evenings. IDs and responses are illustrative. ZenSched IDs are integers. Watch what does **not** cross to ZenSched: the defendants' names, the plaintiff, the firm's paralegal, the documents, the tenant's phone number, Dana's registration number. ZenSched sees `Serve 27-CV-26-11870 - Bryant Ave S`, a street address, an event with the same title, 20-minute shifts, GPS punches, and Attempt Records with physical descriptions and door photos.

## Session start (every session)

```
sqlite_execute: PRAGMA foreign_keys = ON;
sqlite_query:   SELECT key, value FROM settings;
  → business_name = My Process Service, timezone_offset = -05:00, state = NULL,
    default_server_id = NULL, default_attempt_minutes = 20, default_included_attempts = 3,
    invoice_due_days = 30, invoice_prefix = INV, attempt_form_id = NULL, irs_mileage_rate = 0.70
sqlite_query:   SELECT * FROM cases_open;          → (none)
sqlite_query:   SELECT * FROM attempts_upcoming WHERE date(scheduled_start) = date('now', 'localtime');   → (none)
sqlite_query:   SELECT * FROM open_attempts_now;   → (none)
```

## Monday: "We're Northstar Legal Process in Minneapolis, Central time. I'm Dana Whitfield, dana@northstarlegal.example, 612-555-0100, Hennepin County registration 4471. I've got one sub, Luis Ortega, luis@northstarlegal.example, I pay him $20 an attempt. Set us up."

```
sqlite_execute: UPDATE settings SET value = 'Northstar Legal Process' WHERE key = 'business_name';
sqlite_execute: UPDATE settings SET value = '-05:00' WHERE key = 'timezone_offset';
sqlite_execute: UPDATE settings SET value = 'MN' WHERE key = 'state';
```

Agent (first metered call this session, rule 11):

> Saved. Since you're also a server on the phone, I need to invite you to ZenSched as a worker so your attempts show up in the app, and Luis too; that's $0.25 each, one time. If the account isn't funded yet you'll get a prompt for the $5 activation deposit. Go ahead?

Owner: *"yes"*

```
worker_invite:
  email: "dana@northstarlegal.example"
  first_name: "Dana"
  last_name: "Whitfield"
  idempotency_key: "worker-dana@northstarlegal.example"
  → worker_id: 601, status: "invited", invitation_sent: true
    billing: { meter: "worker_invite", units: 1, price: 0.25 }

sqlite_execute:
  INSERT INTO servers (server_name, email, phone, zensched_worker_id, is_owner, license_no)
  VALUES ('Dana Whitfield', 'dana@northstarlegal.example', '612-555-0100', 601, 1, 'Hennepin 4471');
  → lastInsertRowid = 1

sqlite_execute: UPDATE settings SET value = '1' WHERE key = 'default_server_id';

worker_invite:
  email: "luis@northstarlegal.example"
  first_name: "Luis"
  last_name: "Ortega"
  idempotency_key: "worker-luis@northstarlegal.example"
  → worker_id: 602, status: "invited"      ($0.25)

sqlite_execute:
  INSERT INTO servers (server_name, email, zensched_worker_id, is_owner, payout_type, payout_value)
  VALUES ('Luis Ortega', 'luis@northstarlegal.example', 602, 0, 'per_attempt', 20);
  → lastInsertRowid = 2
```

The registration number stays in `servers.license_no`; ZenSched got two names and two emails.

> You're both invited; install the app from the email. Next, the Attempt Record: it's free to create and every attempt comes back with the outcome, who accepted, a physical description, vehicles or lights, a door photo, and whether documents were left. No signature pad on it, on purpose. Want me to set it up now?

Owner: *"yes"*

```
form_create:
  title: "Attempt Record"
  idempotency_key: "form-attempt-record"
  fields_json: (the JSON below, passed as one string)
```

```json
[
  {"type": "section", "label": "Attempt record", "text": "Fill in before you drive off. Operational facts only: no names of anyone you spoke to, no case documents, no notes about the client here. Describe people physically; the affidavit is where names go."},
  {"type": "select", "label": "Outcome", "identifier": "outcome", "required": true,
   "options": ["Served - personal", "Served - substituted", "Posted / affixed", "No answer", "Not at address / moved", "Bad address", "Evasive - refused door", "Refused to accept", "Other"]},
  {"type": "select", "label": "Who accepted (if substituted)", "identifier": "served_person",
   "options": ["Servee", "Co-resident adult", "Person in charge at workplace", "Other adult", "Not applicable"]},
  {"type": "textarea", "label": "Physical description of person contacted (no names)", "identifier": "person_description",
   "show_if": {"field": "outcome", "op": "not_equals", "value": "no_answer", "action": "show"}},
  {"type": "text", "label": "Vehicles / signs of occupancy", "identifier": "vehicles_seen", "placeholder": "e.g. blue Civic in drive, lights on"},
  {"type": "photo", "label": "Photo of door / posted notice / address marker", "identifier": "door_photo", "max_images": 3, "required": true},
  {"type": "select", "label": "Documents left", "identifier": "docs_left", "options": ["Yes", "No"]},
  {"type": "textarea", "label": "Notes for the file", "identifier": "notes"}
]
```

```
  → form_id: 401, fields: [ ...8 fields echoed with identifiers... ]

sqlite_execute: UPDATE settings SET value = '401' WHERE key = 'attempt_form_id';
```

> Attempt Record created; I'll attach it to every serve address automatically. One thing to tell Luis: the description field is physical only ("male, 40s, 5'10", grey hoodie"), never a name. Now the check-in policy: I'd like a 100 m radius, a 30-minute early/late window so you can punch when you actually get there (and so an "I'm here now" window I open while you're parking still takes the punch), and a check-out reminder 15 minutes after a window ends. OK?

Owner: *"yes"*

```
policy_update:
  policy_id: 0
  settings_json: "{\"checkin_radius_m\": 100, \"checkin_slack_min\": 30, \"checkout_reminder_min_after\": 15}"
  → policy_id: 0, updated: [ "checkin_radius_m", "checkin_slack_min", "checkout_reminder_min_after" ]
```

## Monday: "Hollis & Marquez sent this. Take it."

> *From: Karen Doyle, Hollis & Marquez LLP — Please serve Summons & Complaint, Hennepin County District Court, Court File No. 27-CV-26-11870, Northfield Credit Union v. Daniel Reyes. Defendant: Daniel Reyes, DOB 03/14/1984, cell 612-555-0177. Home: 4415 Bryant Ave S, Minneapolis MN 55419 (duplex, he's the lower unit). Employer: Acme Logistics, 2200 Industrial Blvd, Eagan MN 55121, day shift. Routine service, please complete by 9/25. Our file HM-2231. Fee $85 per our schedule. Thanks, Karen.*

The agent parses: client Hollis & Marquez (law firm), file `HM-2231`, court and case number, documents, servee + DOB + phone (all local only), two addresses (home preferred, work as fallback), routine, due 2026-09-25, $85.

```
sqlite_query: SELECT client_id, payment_terms_days FROM clients WHERE client_name LIKE 'Hollis%';   → (none)

sqlite_execute:
  INSERT INTO clients (client_name, client_type, contact_name, billing_email, payment_terms_days,
                       default_serve_fee, default_included_attempts, default_extra_attempt_fee, default_rush_fee, default_bad_address_fee)
  VALUES ('Hollis & Marquez LLP', 'law_firm', 'Karen Doyle', 'ap@hollismarquez.example', 30, 85, 3, 25, 75, 45);
  → lastInsertRowid = 1
```

> I don't have Hollis & Marquez as a client yet. I've added them as a law firm at $85 routine with 3 attempts included; I've assumed net 30, $25 per extra attempt, $75 rush, and $45 for a bad address. Tell me if their schedule differs.

```
sqlite_execute:
  INSERT INTO cases (client_id, client_ref, case_no, court, plaintiff, servee_name, servee_phone, servee_dob, servee_notes,
                     document_types, is_rush, received_date, due_by, serve_fee)
  VALUES (1, 'HM-2231', '27-CV-26-11870', 'Hennepin County District Court', 'Northfield Credit Union', 'Daniel Reyes',
          '612-555-0177', '1984-03-14', 'Lower unit of duplex. Day shift at Acme.', 'Summons & Complaint', 0, '2026-09-07', '2026-09-25', 85);
  → lastInsertRowid = 1
  (triggers fill: case_ref C-2026-0001, included_attempts 3, extra_attempt_fee 25, rush_fee 75, bad_address_fee 45, mileage_fee 0, other_fee 0)

sqlite_query: SELECT place_id, zensched_location_id, place_label FROM places
              WHERE normalized_address = '4415 bryant ave s minneapolis mn 55419';   → (none)
sqlite_execute:
  INSERT INTO places (normalized_address, address, city, state, zip, street_name, place_label, access_notes, is_repeat_site)
  VALUES ('4415 bryant ave s minneapolis mn 55419', '4415 Bryant Ave S', 'Minneapolis', 'MN', '55419', 'Bryant Ave S',
          'Serve 27-CV-26-11870 - Bryant Ave S', 'Duplex; lower unit, side door on the south.', 0);
  → lastInsertRowid = 1
sqlite_execute: INSERT INTO serve_addresses (case_id, place_id, address_type, notes) VALUES (1, 1, 'home', 'Preferred. Evenings and early mornings.');   → 1

sqlite_query: SELECT place_id, zensched_location_id, place_label FROM places
              WHERE normalized_address = '2200 industrial blvd eagan mn 55121';   → (none)
sqlite_execute:
  INSERT INTO places (normalized_address, address, city, state, zip, street_name, place_label, is_repeat_site)
  VALUES ('2200 industrial blvd eagan mn 55121', '2200 Industrial Blvd', 'Eagan', 'MN', '55121', 'Industrial Blvd', 'Acme Logistics - Eagan', 1);
  → lastInsertRowid = 2
sqlite_execute: INSERT INTO serve_addresses (case_id, place_id, address_type, notes) VALUES (1, 2, 'work', 'Day shift. Ask at the dispatch window.');   → 2
```

> Case is in as **C-2026-0001** (27-CV-26-11870). For the first attempts I'd suggest three windows at the home on different days and times of day: Tuesday 7:15 am, Thursday 6:30 pm, Saturday 10:00 am. Want those, or decide day by day?

Owner: *"Those three."*

```
sqlite_execute: INSERT INTO attempts (serve_address_id, scheduled_start) VALUES (1, '2026-09-08T07:15');   → 1  (attempt_no 1, 20 min, server 1)
sqlite_execute: INSERT INTO attempts (serve_address_id, scheduled_start) VALUES (1, '2026-09-10T18:30');   → 2  (attempt_no 2)
sqlite_execute: INSERT INTO attempts (serve_address_id, scheduled_start) VALUES (1, '2026-09-12T10:00');   → 3  (attempt_no 3)

sqlite_query: SELECT * FROM serve_addresses_sync WHERE case_id = 1;
  → sa 1 | home | needs_location 1 | needs_event 1 | event 2026-09-07 .. 2026-09-25
         | Serve 27-CV-26-11870 - Bryant Ave S | 4415 Bryant Ave S, Minneapolis, MN 55419 | loc-place-1 | event-sa-1-20260907
    sa 2 | work | needs_location 1 | needs_event 1 | event 2026-09-07 .. 2026-09-25
         | Acme Logistics - Eagan (location) / Serve 27-CV-26-11870 - Industrial Blvd (event) | loc-place-2 | event-sa-2-20260907
```

> Putting this on ZenSched costs $0.03 per address to geocode (two here); each attempt then costs about $0.35 in GPS check-in/out and reading the Attempt Record with its photo. OK to proceed for this and future cases?

Owner: *"yes"*

```
location_create:
  name: "Serve 27-CV-26-11870 - Bryant Ave S"
  street_address: "4415 Bryant Ave S, Minneapolis, MN 55419"
  checkin_radius_m: 100
  idempotency_key: "loc-place-1"
  → location_id: 9101, lat: 44.9226, lng: -93.2913, pin_quality: "street",
    radius_note: "Check-in radius is enforced by the talent policy ...",
    billing: { meter: "geocode", units: 1, price: 0.03 }
sqlite_execute: UPDATE places SET zensched_location_id = 9101 WHERE place_id = 1;

location_create:
  name: "Acme Logistics - Eagan"
  street_address: "2200 Industrial Blvd, Eagan, MN 55121"
  checkin_radius_m: 100
  idempotency_key: "loc-place-2"
  → location_id: 9102, pin_quality: "place"          ($0.03)
sqlite_execute: UPDATE places SET zensched_location_id = 9102 WHERE place_id = 2;

event_create:
  location_id: 9101
  title: "Serve 27-CV-26-11870 - Bryant Ave S"
  start_date: "2026-09-07"
  end_date:   "2026-09-25"
  idempotency_key: "event-sa-1-20260907"
  → event_id: 7101
form_assign:
  form_id: 401
  event_id: 7101
  idempotency_key: "assign-attempt-7101"
  → status: "assigned", form_id: 401, event_id: 7101, policy_id: 0
sqlite_execute: UPDATE serve_addresses SET zensched_event_id = 7101, event_valid_until = '2026-09-25' WHERE serve_address_id = 1;

event_create:   location_id 9102, title "Serve 27-CV-26-11870 - Industrial Blvd", start_date "2026-09-07", end_date "2026-09-25", idempotency_key "event-sa-2-20260907"   → 7102
form_assign:    form_id 401, event_id 7102, idempotency_key "assign-attempt-7102"
sqlite_execute: UPDATE serve_addresses SET zensched_event_id = 7102, event_valid_until = '2026-09-25' WHERE serve_address_id = 2;

sqlite_query: SELECT * FROM attempts_planned WHERE case_id = 1 AND needs_shift = 1 ORDER BY scheduled_start;
  → 1 | 2026-09-08T07:15:00-05:00 .. 2026-09-08T07:35:00-05:00 | morning | event 7101 | worker 601 | shift-attempt-1
    2 | 2026-09-10T18:30:00-05:00 .. 2026-09-10T18:50:00-05:00 | evening | event 7101 | worker 601 | shift-attempt-2
    3 | 2026-09-12T10:00:00-05:00 .. 2026-09-12T10:20:00-05:00 | weekend | event 7101 | worker 601 | shift-attempt-3

shift_create:
  event_id: 7101
  worker_id: 601
  start: "2026-09-08T07:15:00-05:00"
  end:   "2026-09-08T07:35:00-05:00"
  idempotency_key: "shift-attempt-1"
  → shift_id: 88101, status: "scheduled", forms_installed: [401]
shift_create: event 7101, worker 601, "2026-09-10T18:30:00-05:00" .. "2026-09-10T18:50:00-05:00", idempotency_key "shift-attempt-2"   → 88102
shift_create: event 7101, worker 601, "2026-09-12T10:00:00-05:00" .. "2026-09-12T10:20:00-05:00", idempotency_key "shift-attempt-3"   → 88103

sqlite_execute: UPDATE attempts SET zensched_shift_id = 88101 WHERE attempt_id = 1;
sqlite_execute: UPDATE attempts SET zensched_shift_id = 88102 WHERE attempt_id = 2;
sqlite_execute: UPDATE attempts SET zensched_shift_id = 88103 WHERE attempt_id = 3;
```

Nothing about Daniel Reyes, his DOB or phone, Northfield Credit Union, or Karen is in `name`, `title`, or `notes`. The work address has a location and an event but no shift yet; "I'm at Acme now" later is one call.

> Intaken **27-CV-26-11870** (C-2026-0001) for Hollis & Marquez: summons & complaint, due Fri Sep 25, $85 routine with 3 attempts included. Home on Bryant Ave S and Acme Logistics in Eagan are both pinned. Attempts on your phone: Tue 7:15 am, Thu 6:30 pm, Sat 10:00 am, all at the home. Daniel Reyes' details and Karen's contact are only on your computer; ZenSched sees "Serve 27-CV-26-11870 - Bryant Ave S". Want me to draft the acknowledgment to Karen?

## Monday: "Lakeshore Property Management, rush eviction. Eviction Summons & Complaint, Hennepin Housing Court 27-CV-HC-26-4410, tenant Marisol Garcia, 810 Oak St Unit B Minneapolis 55407, her cell 612-555-0141. Hearing is the 14th so they need it served by Friday the 11th. Their file LPM-EV-0912. They pay $65 plus $60 rush, net 15. I'll do tomorrow at 7:45 and Luis can take evenings as he passes."

Same pattern; the owner already approved geocoding this session.

```
sqlite_execute: INSERT INTO clients (client_name, client_type, billing_email, payment_terms_days, default_serve_fee, default_included_attempts, default_extra_attempt_fee, default_rush_fee, default_bad_address_fee)
                VALUES ('Lakeshore Property Management', 'property_manager', 'ap@lakeshorepm.example', 15, 65, 3, 20, 60, 40);   → 2
sqlite_execute: INSERT INTO cases (client_id, client_ref, case_no, court, servee_name, servee_phone, document_types, is_rush, received_date, due_by)
                VALUES (2, 'LPM-EV-0912', '27-CV-HC-26-4410', 'Hennepin County Housing Court', 'Marisol Garcia', '612-555-0141',
                        'Eviction Summons & Complaint', 1, '2026-09-07', '2026-09-11');   → 2
                (trigger: C-2026-0002, serve_fee 65, included 3, extra 20, rush_fee 60, bad_address_fee 40)
sqlite_query:   SELECT ... FROM places WHERE normalized_address = '810 oak st unit b minneapolis mn 55407';   → (none)
sqlite_execute: INSERT INTO places (normalized_address, address, city, state, zip, street_name, place_label, is_repeat_site)
                VALUES ('810 oak st unit b minneapolis mn 55407', '810 Oak St Unit B', 'Minneapolis', 'MN', '55407', 'Oak St', 'Serve 27-CV-HC-26-4410 - Oak St', 0);   → 3
sqlite_execute: INSERT INTO serve_addresses (case_id, place_id, address_type) VALUES (2, 3, 'home');   → 3
sqlite_execute: INSERT INTO attempts (serve_address_id, scheduled_start) VALUES (3, '2026-09-08T07:45');   → 4  (attempt_no 1, server 1)

sqlite_query:   SELECT * FROM serve_addresses_sync WHERE case_id = 2;
  → sa 3 | needs_location 1 | needs_event 1 | event 2026-09-07 .. 2026-09-11 (capped at due_by) | loc-place-3 | event-sa-3-20260907

location_create: name "Serve 27-CV-HC-26-4410 - Oak St", street_address "810 Oak St Unit B, Minneapolis, MN 55407", checkin_radius_m 100, idempotency_key "loc-place-3"   → 9103   ($0.03)
sqlite_execute:  UPDATE places SET zensched_location_id = 9103 WHERE place_id = 3;
event_create:    location_id 9103, title "Serve 27-CV-HC-26-4410 - Oak St", start_date "2026-09-07", end_date "2026-09-11", idempotency_key "event-sa-3-20260907"   → 7103
form_assign:     form_id 401, event_id 7103, idempotency_key "assign-attempt-7103"
sqlite_execute:  UPDATE serve_addresses SET zensched_event_id = 7103, event_valid_until = '2026-09-11' WHERE serve_address_id = 3;
shift_create:    event 7103, worker 601, "2026-09-08T07:45:00-05:00" .. "2026-09-08T08:05:00-05:00", idempotency_key "shift-attempt-4"   → 88104
sqlite_execute:  UPDATE attempts SET zensched_shift_id = 88104 WHERE attempt_id = 4;
```

> Intaken **27-CV-HC-26-4410** (C-2026-0002) for Lakeshore, rush eviction summons, due Fri Sep 11. Oak St is pinned and the event runs through Friday. Your Tue 7:45 am window is on your phone; when Luis is passing, text me "Luis at Garcia now" and I'll open a window for him. $65 + $60 rush, net 15. Ms. Garcia's name and number are only on your computer.

## Tuesday morning: two planned attempts

7:14, outside 4415 Bryant Ave S, in the ZenSched app: Dana taps **Check in** (GPS: 8 m from the pin, verified, $0.10). Knocks the lower unit's side door. Nothing. Truck in the drive, TV audible. Photographs the door and the house number. Opens **Attempt Record**: Outcome = No answer; Vehicles = "Blue Ford F-150 in drive, TV on inside"; Photo = 2 images; Documents left = No. Submits. **Check out** 7:22 ($0.10).

7:46 at 810 Oak St Unit B: Check in (11 m, verified). No answer, no vehicle, blinds shut. One door photo. Attempt Record: No answer; Vehicles = "No vehicle, blinds closed, mail in box"; Documents left = No. Check out 7:52.

## Tuesday, 8:31 pm: "Luis at Garcia now."

The server is standing at the door; speed matters.

```
sqlite_query:
  SELECT sa.serve_address_id, sa.zensched_event_id, sa.event_valid_until, p.zensched_location_id, s.server_id, s.zensched_worker_id
  FROM serve_addresses sa JOIN cases c ON c.case_id = sa.case_id JOIN places p ON p.place_id = sa.place_id
  JOIN servers s ON s.server_name LIKE 'Luis%'
  WHERE c.servee_name LIKE '%Garcia%' AND c.status = 'open' AND sa.is_active = 1;
  → sa 3 | event 7103 | valid until 2026-09-11 | location 9103 | server 2 | worker 602

sqlite_execute: INSERT INTO attempts (serve_address_id, scheduled_start, duration_minutes, server_id, is_adhoc)
                VALUES (3, '2026-09-08T20:31', 20, 2, 1);   → 5  (attempt_no 2)
sqlite_query:   SELECT start_iso, end_iso, needs_location, needs_event, zensched_event_id, zensched_worker_id, shift_idempotency_key
                FROM attempts_planned WHERE attempt_id = 5;
  → 2026-09-08T20:31:00-05:00 | 2026-09-08T20:51:00-05:00 | 0 | 0 | 7103 | 602 | shift-attempt-5

shift_create:
  event_id: 7103
  worker_id: 602
  start: "2026-09-08T20:31:00-05:00"
  end:   "2026-09-08T20:51:00-05:00"
  idempotency_key: "shift-attempt-5"
  → shift_id: 88105, status: "scheduled", forms_installed: [401]
sqlite_execute: UPDATE attempts SET zensched_shift_id = 88105 WHERE attempt_id = 5;
```

> Window's on Luis's phone: 8:31–8:51 pm at Oak St. He can check in now.

Luis checks in at 8:33 pm (9 m, verified; two minutes after the window opened, inside the 30-minute slack). Lights on, a woman's voice says "she's not here" through the door and does not open it. Two door photos. Attempt Record: Outcome = Evasive - refused door; Description = "Female voice, adult, did not open"; Vehicles = "Lights on, grey Corolla at curb"; Documents left = No. Check out 8:39.

## Tuesday night: "Log today's attempts."

```
shift_list: date_from "2026-09-08", date_to "2026-09-08", status "checked_out"
  → [ { shift_id: 88101, worker_id: 601, event_id: 7101, actual_in: "2026-09-08T07:14:20-05:00", actual_out: "2026-09-08T07:22:05-05:00" },
      { shift_id: 88104, worker_id: 601, event_id: 7103, actual_in: "2026-09-08T07:46:10-05:00", actual_out: "2026-09-08T07:52:30-05:00" },
      { shift_id: 88105, worker_id: 602, event_id: 7103, actual_in: "2026-09-08T20:33:15-05:00", actual_out: "2026-09-08T20:39:40-05:00" } ]
(free)

shift_status: 88101 → punches: [ { type: "in", gps_verified: true, distance_from_site_m: 8 }, { type: "out", gps_verified: true, distance_from_site_m: 10 } ]
shift_status: 88104 → in verified 11 m, out verified 9 m
shift_status: 88105 → in verified 9 m, out verified 12 m
(free)
```

> Reading the three Attempt Records with their door photos is about $0.45. Each bills once; after this I answer from the local record. OK?

Owner: *"go"*

```
form_submissions:
  form_id: 401
  event_id: 7101
  limit: 20
  → submissions: [
      { submission_id: 3401, worker_id: 601, event_id: 7101, submitted_at: "2026-09-08 07:21:10",
        data: { outcome: "no_answer", vehicles_seen: "Blue Ford F-150 in drive, TV on inside", docs_left: "no" },
        media: [ { field: "door_photo", cdn_url: "https://cdn.zensched.com/m/.../door1.jpg" }, { field: "door_photo", cdn_url: ".../number1.jpg" } ] }
    ], count: 1, billing: { meter: "form_media", units: 1, price: 0.15 }

form_submissions: form_id 401, event_id 7103, limit 20      ($0.30: two submissions with photos)
  → [ { submission_id: 3402, worker_id: 601, submitted_at: "2026-09-08 07:51:40",
        data: { outcome: "no_answer", vehicles_seen: "No vehicle, blinds closed, mail in box", docs_left: "no" }, media: [ 1 photo ] },
      { submission_id: 3403, worker_id: 602, submitted_at: "2026-09-08 20:38:50",
        data: { outcome: "evasive___refused_door", person_description: "Female voice, adult, did not open",
                vehicles_seen: "Lights on, grey Corolla at curb", docs_left: "no" }, media: [ 2 photos ] } ]

sqlite_execute:
  UPDATE attempts SET status = 'attempted', outcome = 'no_answer', manner = 'not_served',
         vehicles_seen = 'Blue Ford F-150 in drive, TV on inside', docs_left = 0, photo_count = 2, record_dc_id = 3401,
         checked_in_at = '2026-09-08T07:14:20-05:00', checked_out_at = '2026-09-08T07:22:05-05:00', gps_verified = 1, checkin_distance_m = 8
  WHERE attempt_id = 1;
sqlite_execute:
  UPDATE attempts SET status = 'attempted', outcome = 'no_answer', manner = 'not_served',
         vehicles_seen = 'No vehicle, blinds closed, mail in box', docs_left = 0, photo_count = 1, record_dc_id = 3402,
         checked_in_at = '2026-09-08T07:46:10-05:00', checked_out_at = '2026-09-08T07:52:30-05:00', gps_verified = 1, checkin_distance_m = 11
  WHERE attempt_id = 4;
sqlite_execute:
  UPDATE attempts SET status = 'attempted', outcome = 'evasive___refused_door', manner = 'not_served',
         person_description = 'Female voice, adult, did not open', vehicles_seen = 'Lights on, grey Corolla at curb', docs_left = 0, photo_count = 2, record_dc_id = 3403,
         checked_in_at = '2026-09-08T20:33:15-05:00', checked_out_at = '2026-09-08T20:39:40-05:00', gps_verified = 1, checkin_distance_m = 9
  WHERE attempt_id = 5;

sqlite_query:   SELECT * FROM payouts_missing;
  → attempt | Luis Ortega | per_attempt 20 | case 27-CV-HC-26-4410 | attempt_id 5 | attempt_no 2 | 2026-09-08 | evasive___refused_door
sqlite_execute: INSERT INTO payouts (server_id, attempt_id) VALUES (2, 5);      (trigger: amount 20)
```

The photos stay on ZenSched; locally there is a count and the submission id. Luis's description has no name in it, as briefed.

> Logged three attempts.
> - **27-CV-26-11870** (Reyes) attempt 1: Tue 7:14–7:22 am at Bryant Ave S, GPS-verified 8 m. No answer; blue F-150 in the drive, TV on; 2 photos. Thu 6:30 pm and Sat 10 am still planned.
> - **27-CV-HC-26-4410** (Garcia) attempt 1: Tue 7:46–7:52 am, verified 11 m. No answer; no vehicle, blinds shut, mail in the box; 1 photo.
> - **27-CV-HC-26-4410** attempt 2 (Luis, ad hoc): Tue 8:33–8:39 pm, verified 9 m. Evasive: an adult woman answered through the door, said she's not there, wouldn't open; lights on, grey Corolla; 2 photos. That's 2 of 3 included on Garcia with the deadline Friday. Luis is owed $20 for it.
>
> Want a Thursday midday window on Garcia so the three attempts cover morning, evening, and midday?

Owner: *"Yes, Luis, Thursday 12:15."*

```
sqlite_execute: INSERT INTO attempts (serve_address_id, scheduled_start, server_id) VALUES (3, '2026-09-10T12:15', 2);   → 6  (attempt_no 3)
sqlite_query:   SELECT start_iso, end_iso, zensched_event_id, zensched_worker_id, needs_event, shift_idempotency_key FROM attempts_planned WHERE attempt_id = 6;
  → 2026-09-10T12:15:00-05:00 | 2026-09-10T12:35:00-05:00 | 7103 | 602 | 0 | shift-attempt-6
shift_create:   event 7103, worker 602, "2026-09-10T12:15:00-05:00" .. "2026-09-10T12:35:00-05:00", idempotency_key "shift-attempt-6"   → 88106
sqlite_execute: UPDATE attempts SET zensched_shift_id = 88106 WHERE attempt_id = 6;
```

## Wednesday, 6:52 pm: "I'm at Reyes' house now, truck's here."

An unplanned evening attempt a day before the planned one. Same "I'm here now" flow, for the owner this time.

```
sqlite_execute: INSERT INTO attempts (serve_address_id, scheduled_start, duration_minutes, is_adhoc) VALUES (1, '2026-09-09T18:52', 20, 1);   → 7  (attempt_no 4 at this address, server 1)
sqlite_query:   SELECT ... FROM attempts_planned WHERE attempt_id = 7;  → 2026-09-09T18:52:00-05:00 .. 2026-09-09T19:12:00-05:00 | event 7101 | worker 601 | shift-attempt-7
shift_create:   event 7101, worker 601, "2026-09-09T18:52:00-05:00" .. "2026-09-09T19:12:00-05:00", idempotency_key "shift-attempt-7"   → 88107
sqlite_execute: UPDATE attempts SET zensched_shift_id = 88107 WHERE attempt_id = 7;
```

> On your phone: 6:52–7:12 pm at Bryant Ave S. Go.

Dana checks in 6:53 pm (7 m, verified). A man answers the side door, confirms his name when asked, takes the papers. Photo of the door. Attempt Record: Outcome = Served - personal; Who accepted = Servee; Description = "Male, 40s, approx 5'10\", medium build, dark hair, beard, grey t-shirt; confirmed identity verbally"; Vehicles = "Blue F-150 in drive"; Documents left = Yes. Check out 6:58.

## Wednesday night: "Reyes is served. Log it and close it."

```
shift_status: 88107 → status "checked_out", actual_in "2026-09-09T18:53:05-05:00", actual_out "2026-09-09T18:58:30-05:00",
                     punches: [ { type: "in", gps_verified: true, distance_from_site_m: 7 }, { type: "out", gps_verified: true, distance_from_site_m: 9 } ]
form_submissions: form_id 401, event_id 7101, limit 20     ($0.15; submission 3401 is skipped, already stored)
  → [ ..., { submission_id: 3404, worker_id: 601, submitted_at: "2026-09-09 18:57:50",
             data: { outcome: "served___personal", served_person: "servee",
                     person_description: "Male, 40s, approx 5'10\", medium build, dark hair, beard, grey t-shirt; confirmed identity verbally",
                     vehicles_seen: "Blue F-150 in drive", docs_left: "yes" }, media: [ 1 photo ] } ]

sqlite_execute:
  UPDATE attempts SET status = 'served', outcome = 'served___personal', manner = 'personal', served_person = 'servee',
         person_description = 'Male, 40s, approx 5''10", medium build, dark hair, beard, grey t-shirt; confirmed identity verbally',
         vehicles_seen = 'Blue F-150 in drive', docs_left = 1, photo_count = 1, record_dc_id = 3404,
         checked_in_at = '2026-09-09T18:53:05-05:00', checked_out_at = '2026-09-09T18:58:30-05:00', gps_verified = 1, checkin_distance_m = 7
  WHERE attempt_id = 7;
```

> Attempt 2 on Reyes: Wed 6:53–6:58 pm, GPS-verified 7 m, served personally on a male, 40s, 5'10", beard, who confirmed his name; documents left; door photographed. Close **27-CV-26-11870** as served and cancel Thursday and Saturday?

Owner: *"yes"*

```
sqlite_execute: UPDATE cases SET status = 'served', served_at = '2026-09-09T18:53', served_manner = 'personal', served_attempt_id = 7 WHERE case_id = 1;
shift_cancel:   shift_id 88102, reason "cancelled", idempotency_key "cancel-shift-88102"
shift_cancel:   shift_id 88103, reason "cancelled", idempotency_key "cancel-shift-88103"
sqlite_execute: UPDATE attempts SET status = 'cancelled' WHERE attempt_id IN (2, 3);
sqlite_execute: INSERT INTO mileage (attempt_id, trip_date, miles, from_label, to_label, purpose)
                VALUES (7, '2026-09-09', 9, 'Home', 'Serve 27-CV-26-11870 - Bryant Ave S', 'C-2026-0001 attempt 2 round trip');   (trigger: 0.70, 6.30)
```

> **27-CV-26-11870** closed: served personally Wed Sep 9, 6:53 pm, after 2 attempts (3 included, so no extras). $85 is now receivable from Hollis & Marquez, net 30. The Thursday and Saturday windows are off your phone. Say "diligence log for Reyes" when you write the affidavit.

## Thursday, 12:15 pm: Luis posts the eviction

Luis checks in at Oak St 12:16 pm (10 m, verified). No answer again; he can hear a TV. Following the owner's instruction for this case, he affixes the summons to the door and photographs the posted notice, the door, and the unit letter. Attempt Record: Outcome = Posted / affixed; Who accepted = Not applicable; Description = (blank); Vehicles = "TV audible, grey Corolla at curb"; Photos = 3; Documents left = Yes; Notes = "Posted to door at eye level, taped all four sides." Check out 12:24.

## Thursday afternoon: "Log Garcia. Luis posted it. I'll mail today."

```
shift_status: 88106 → actual_in "2026-09-10T12:16:00-05:00", actual_out "2026-09-10T12:24:10-05:00", in verified 10 m
form_submissions: form_id 401, event_id 7103, limit 20     ($0.15; 3402 and 3403 skipped)
  → [ ..., { submission_id: 3405, worker_id: 602, submitted_at: "2026-09-10 12:23:30",
             data: { outcome: "posted___affixed", served_person: "not_applicable", vehicles_seen: "TV audible, grey Corolla at curb",
                     docs_left: "yes", notes: "Posted to door at eye level, taped all four sides." }, media: [ 3 photos ] } ]

sqlite_execute:
  UPDATE attempts SET status = 'served', outcome = 'posted___affixed', manner = 'posted', served_person = 'not_applicable',
         vehicles_seen = 'TV audible, grey Corolla at curb', docs_left = 1, photo_count = 3, record_dc_id = 3405,
         checked_in_at = '2026-09-10T12:16:00-05:00', checked_out_at = '2026-09-10T12:24:10-05:00', gps_verified = 1, checkin_distance_m = 10,
         notes = 'Posted to door at eye level, taped all four sides.'
  WHERE attempt_id = 6;
```

> Attempt 3 on Garcia: Thu 12:16–12:24 pm, GPS-verified 10 m, posted to the door with 3 photos (notice, door, unit letter). That's three attempts on two days at morning, evening, and midday. Whether posting completes service for this eviction is your call under the housing court's rules; you said you're mailing today. Close **27-CV-HC-26-4410** as served by posting, with mailing today?

Owner: *"yes"*

```
sqlite_execute: UPDATE cases SET status = 'served', served_at = '2026-09-10T12:16', served_manner = 'posted', served_attempt_id = 6, mailed_at = '2026-09-10' WHERE case_id = 2;
sqlite_execute: INSERT INTO payouts (server_id, attempt_id) VALUES (2, 6);      (trigger: amount 20)
```

> Closed. Luis is owed $40 for two attempts. $125 ($65 + $60 rush) is receivable from Lakeshore, net 15.

## Friday: "Diligence log for Garcia, for the affidavit."

```
sqlite_query: SELECT * FROM due_diligence_log WHERE case_no = '27-CV-HC-26-4410' ORDER BY seq;
  → seq 1 | attempt 4 | attempt_no 1 | home | 810 Oak St Unit B, Minneapolis, MN 55407 | 2026-09-08 | Tuesday  | gps | 7:46 am | 7:52 am  | 6 min  | morning | not_served | no_answer               | photos 1 | gps 1 | 11 m | Dana Whitfield | Hennepin 4471
    seq 2 | attempt 5 | attempt_no 2 | home | same                                     | 2026-09-08 | Tuesday  | gps | 8:33 pm | 8:39 pm  | 6 min  | evening | not_served | evasive___refused_door  | photos 2 | gps 1 | 9 m  | Luis Ortega    | NULL
    seq 3 | attempt 6 | attempt_no 3 | home | same                                     | 2026-09-10 | Thursday | gps | 12:16 pm| 12:24 pm | 8 min  | afternoon | posted   | posted___affixed        | photos 3 | gps 1 | 10 m | Luis Ortega    | NULL
```

> Here it is in declaration order. Paste into your affidavit form and add your own paragraph on the mailing:
>
> ```
> Attempts to serve — Hennepin County Housing Court No. 27-CV-HC-26-4410, Eviction Summons & Complaint
>
> 1. Tuesday, September 8, 2026, 7:46 am – 7:52 am, at 810 Oak St Unit B, Minneapolis, MN 55407 (residence).
>    No answer. No vehicle present; blinds closed; mail in the box. Door photographed (1).
>    GPS-verified on site, 11 m from the address. Server: Dana Whitfield.
> 2. Tuesday, September 8, 2026, 8:33 pm – 8:39 pm, at the same address.
>    An adult female answered through the closed door, stated the occupant was not there, and did not open.
>    Lights on; grey Toyota Corolla at the curb. Door photographed (2). GPS-verified, 9 m. Server: Luis Ortega.
> 3. Thursday, September 10, 2026, 12:16 pm – 12:24 pm, at the same address.
>    No answer; television audible. Documents affixed to the door at eye level; posted notice, door, and unit
>    letter photographed (3). GPS-verified, 10 m. Server: Luis Ortega.
> ```
>
> Facts for your diligence paragraph: 3 attempts on 2 different days (Tue, Thu) at 3 times of day (morning, evening, midday), 1 address, 3 of 3 photographed, 3 of 3 GPS-verified. Whether that satisfies the court's rule is your judgment. Photo references: submissions 3402, 3403, 3405 on ZenSched (already read; re-listing is free). If you were in California this would matter more: the photos are not stamped with date/time/GPS by ZenSched, so from 2027 you'd shoot with the camera's stamp overlay on.

"Diligence log for Reyes" produces the same for 27-CV-26-11870: attempt 1 Tue 7:14 am no answer (F-150, TV on, 2 photos, 8 m), attempt 2 Wed 6:53 pm served personally with the description (1 photo, 7 m). Both by Dana Whitfield, registration Hennepin 4471 shown for the affidavit.

## Friday: "What do I owe Luis, and invoice both firms."

```
sqlite_query: SELECT * FROM payouts_missing;   → (none)
sqlite_query: SELECT * FROM payouts_due;
  → Luis Ortega | per_attempt 20 | 27-CV-HC-26-4410 | attempt 2 | 2026-09-08 | evasive___refused_door | 20.00 | server_total_due 40.00
    Luis Ortega | per_attempt 20 | 27-CV-HC-26-4410 | attempt 3 | 2026-09-10 | posted___affixed       | 20.00 | server_total_due 40.00
```

> Luis: 2 attempts on the Garcia eviction, $20 each, **$40** due. Say "paid Luis" and I'll mark it.

```
sqlite_query: SELECT * FROM receivables_by_client;
  → Hollis & Marquez LLP          | law_firm         | ap@hollismarquez.example | net 30 | 1 case (1 served) | 2 attempts | 0 extra |  85.00
    Lakeshore Property Management | property_manager | ap@lakeshorepm.example   | net 15 | 1 case (1 served) | 3 attempts | 0 extra | 125.00

sqlite_execute:
  INSERT INTO invoices (client_id, invoice_date, due_date, total_amount, line_items)
  SELECT b.client_id, date('now', 'localtime'),
         date('now', 'localtime', '+' || (SELECT payment_terms_days FROM clients WHERE client_id = 1) || ' days'),
         SUM(b.billable_total),
         json_group_array(json_object('case_ref', b.case_ref, 'case_no', b.case_no, 'client_ref', b.client_ref, 'court', b.court, 'documents', b.document_types,
                                      'status', b.status, 'served_date', b.served_date, 'manner', b.served_manner, 'attempts', b.attempts_made, 'included', b.included_attempts,
                                      'serve_fee', b.serve_fee, 'extra_attempts', b.extra_attempts, 'extra_attempt_total', b.extra_attempt_total, 'rush_fee', b.rush_fee_billed,
                                      'mileage_fee', b.mileage_fee, 'bad_address_fee', b.bad_address_fee, 'other_fee', b.other_fee, 'billable', b.billable_total))
  FROM billable_cases b WHERE b.invoiced = 0 AND b.client_id = 1 AND b.billable_total > 0 GROUP BY b.client_id;
sqlite_execute: UPDATE cases SET invoiced = 1 WHERE invoiced = 0 AND client_id = 1 AND status IN ('served', 'not_served', 'cancelled');
sqlite_query:   SELECT invoice_number, invoice_date, due_date, total_amount FROM invoices WHERE invoice_id = last_insert_rowid();
  → INV-2026-0001 | 2026-09-11 | 2026-10-11 | 85.00

(same three statements for client 2 → INV-2026-0002 | 2026-09-11 | 2026-09-26 | 125.00)
```

> Here's the Hollis & Marquez invoice, ready to paste:
>
> ```
> Northstar Legal Process
> Invoice INV-2026-0001
> To: Hollis & Marquez LLP (ap@hollismarquez.example)
> Date: Sep 11, 2026    Due: Oct 11, 2026 (net 30)
>
>   C-2026-0001  Your file HM-2231   Hennepin County District Court 27-CV-26-11870, Summons & Complaint
>                Served personally Sep 9, 2026 after 2 attempts (3 included)     Routine service     $85.00
>
> Total due: $85.00
> ```
>
> And Lakeshore, INV-2026-0002, $125 (C-2026-0002, your file LPM-EV-0912, 27-CV-HC-26-4410, eviction summons, served by posting Sep 10 after 3 attempts; $65 routine + $60 rush), due Sep 26. No tenant or defendant names on either; the court numbers and their file numbers identify the matters. Say "sent" when they're out.

## Friday: "Who owes me money?"

```
sqlite_query: SELECT * FROM invoices_outstanding;
  → INV-2026-0002 | Lakeshore Property Management | due 2026-09-26 | 125.00 | days_past_due -15 | current
    INV-2026-0001 | Hollis & Marquez LLP          | due 2026-10-11 |  85.00 | days_past_due -30 | current
```

> Outstanding: $210, all current. Nothing overdue. I'll flag Lakeshore after Sep 26 and Hollis & Marquez after Oct 11 if they haven't paid.

## Summary of who stored what

| Thing | Where | Why |
|---|---|---|
| Daniel Reyes and Marisol Garcia: names, phone numbers, DOB, "lower unit", "day shift at Acme" | SQLite **only** (`cases.servee_*`, `serve_addresses.notes`, `places.access_notes`) | Servee PII never reaches ZenSched |
| Plaintiff (Northfield Credit Union), Karen at the firm, the summons itself | SQLite (`cases.plaintiff`, `clients.contact_name`) / **not stored** (documents) | Case parties and documents stay with the server and the firm |
| Dana's Hennepin County registration number | SQLite (`servers.license_no`) | Local roster; surfaces in `due_diligence_log` for the affidavit |
| Hollis & Marquez, Lakeshore: terms, billing email, fee schedule | SQLite (`clients`) | Billing; ZenSched does not model clients or fees |
| Each serve address, normalized, with its ZenSched location id | SQLite (`places`) | De-dup cache; a repeat complex or workplace skips the $0.03 geocode and keeps its pin |
| `Serve 27-CV-26-11870 - Bryant Ave S`, `Acme Logistics - Eagan`, `Serve 27-CV-HC-26-4410 - Oak St` and their street addresses and GPS pins | ZenSched (ID in `places`) | Needed for geofenced check-in; labels carry the public case number and street, no names |
| One event per serve address, windowed to the case deadline (`event_valid_until`) | ZenSched (ID in `serve_addresses`) | Shifts hang off events; events cap at 60 days, so the kit rolls them if a case runs long |
| One shift per attempt (20-minute window), planned or ad hoc | ZenSched (ID in `attempts`) | The thing a GPS punch attaches to; never copied |
| Dana and Luis as ZenSched workers | ZenSched (IDs in `servers`) | Solo owner is also a server; sub gets the same app |
| GPS punches, arrival time, distance from pin | ZenSched (originals); stamps copied once to `attempts.checked_in_at` / `checked_out_at` / `gps_verified` / `checkin_distance_m` | Proof each attempt happened where and when, answered from SQLite afterwards for free |
| The Attempt Record form | ZenSched (ID in `settings`) | Installed on the phone per shift; no signature field |
| Five Attempt Record submissions, 9 door photos | ZenSched (originals); outcome, manner, physical description, vehicles, docs left, photo count, `record_dc_id` in `attempts` | Read once (metered), then the due-diligence log is built locally; images stay on ZenSched |
| Check-in policy (100 m radius, 30 min slack, 15 min check-out reminder) | ZenSched (policy 0) | Radius and slack are enforced by the policy, not per location |
| Fees per case, billable totals, two invoices, aging | SQLite (`cases`, `billable_cases`, `invoices`, `invoices_outstanding`) | Receivables from firms |
| Luis's two $20 payouts | SQLite (`payouts`) | Per attempt, not hourly; owner's own attempts never generate payouts |
| Mileage and deduction | SQLite (`mileage`) | Tax record at the snapshot rate |
