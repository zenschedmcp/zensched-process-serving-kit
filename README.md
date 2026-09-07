# ZenSched Process-Serving Reference Kit

A copy-pasteable setup for a solo process server, or a 2–8 server agency that dispatches subcontracted (1099) servers, that wants an AI assistant to run case intake, serve-attempt scheduling, GPS/time-stamped attempt records with door photos, a due-diligence attempt log ready to paste into the affidavit, receivables from law firms, and sub payouts. ZenSched handles the phone app, the GPS check-in at each serve address, the per-address event and per-attempt shift, and the Attempt Record. A small local database on your computer holds your clients, the addresses you have been to, your cases (with the defendants' names and the firm's contacts), every attempt with its GPS stamps, mileage, invoices, and payouts.

**You do not need to know how to program or write SQL to use this.** You paste the firm's service request into your AI assistant ("Hollis & Marquez sent this, take it"), text it "Luis at Garcia now", ask "log tonight's attempts", "diligence log for Reyes", "what's at risk this week", "did Luis actually go last night", "invoice Hollis", "who owes me money", and the AI does the work using two tools you set up once. Setup takes about 15 minutes and is the only technical part.

If you *are* a developer, skip to [For developers](#for-developers).

## This is not an affidavit generator, e-filing tool, or rules engine — read this first

**What this kit is:** a way for a process server to get every attempt window onto their phone (planned ahead, or opened on the spot when they decide to knock on the way home), prove with a GPS-verified check-in that each attempt happened at the address at that time, record what happened (outcome, who accepted, a physical description, vehicles and lights, a door photo, documents left), and turn those records into a due-diligence log in declaration order, invoices, receivables follow-up, mileage totals, and sub payouts, with an AI assistant doing the clerical work.

**What it is not:**

- **It does not generate affidavits or proofs of service, and it does not e-file.** The `due_diligence_log` view lists every attempt on a case with GPS-verified times, outcome, description, photo count, and server, and the AI formats it as the numbered paragraphs a declaration of diligence wants. You paste that into *your* form (Judicial Council form, the firm's template, your Word document), add the sworn parts, sign it, and file it as you do now.
- **It does not know your state's rules.** How many attempts, on how many days, at which times of day, at which addresses, whether posting or substituted service is allowed, whether a mailing must follow, what the court wants in the declaration: those are yours. `cases_ready_for_substitute` is a **count** (attempts made against the number your fee includes, with the variety facts alongside); it is not a legal opinion, and `SKILL.md` forbids the AI from telling you service was sufficient.
- **It does not watermark photos.** ZenSched records the GPS punch coordinates and the upload time server-side, and the Attempt Record's door photo is stored with the submission, but the exported image is **not** stamped with the date, time, and coordinates. **California servers:** from January 1, 2027, CCP 417.10 as amended by AB 747 requires the proof of service to include a door photo for each attempt with a *readable* date, time, and GPS stamp on the photo itself. Until the platform adds a burned-in stamp, shoot the door photo with your phone camera's timestamp / GPS overlay turned on (or a GPS-stamp camera app) and upload *that* image to the Attempt Record. The punch record is still your corroboration; the stamp on the image is the statutory requirement.
- **It is not a panic button.** Servers work alone, at night, on evictions and family-law papers. Check-in and check-out per attempt plus a check-out reminder mean there is a *record* of where a server was and when they left, and `open_attempts_now` lists anyone checked in past their window; nothing alerts anyone automatically, and nobody is watching.
- **It does not skip trace, does not run a client portal, and does not store the summons.** A located address becomes a new serve address; the AI drafts the status email to the paralegal from the attempt records; the documents stay with you.

If any of that is a deal-breaker, this kit is not for you. If you want every attempt GPS-stamped at the door, a diligence log you can paste instead of reconstruct from your camera roll, and receivables you can actually chase, read on.

## What lives where

**ZenSched (source of truth for where the server was and when):**

- Locations (one per serve address, cached locally so a repeat complex or workplace is created once; the check-in radius is a policy setting)
- Workers (you, in solo mode; you plus your subs in agency mode, each with the mobile app)
- Events (one per serve address, windowed to the case deadline, at most 60 days, rolled if the case runs long)
- Shifts (one per attempt: a 20-minute window, planned ahead or opened on the spot, with a push notification to the server)
- GPS punches (check-in / check-out with distance-from-the-pin verification)
- The Attempt Record form (outcome, who accepted, physical description, vehicles / signs of occupancy, door photo, documents left, notes) and every submission with its photos

**Local SQLite database (`serve-ops.db`, on your computer):**

- Clients: law firms, collection agencies, property managers, courts, other servers, with payment terms and a fee schedule (serve fee, included attempts, extra-attempt fee, rush fee, bad-address fee)
- Places: every address you have been sent to, normalized, with its ZenSched location id and access notes (gate code, "unit 12 is the rear building", "dog") — **access notes never leave your computer**
- Servers: you (and your subs), registration / certification number — **never leaves your computer**; payout split per sub (per serve, per attempt, or percent)
- Cases: the firm's file number, court and case number, documents, the defendant's name / phone / DOB / hints (**never leave your computer**), rush flag, due date, fee snapshot, status, served-by-which-attempt, mailing and proof-sent dates
- Serve addresses: each case's home / work / other address, active or exhausted, with the current ZenSched event and its expiry
- Attempts: one row per attempt window, numbered per address, planned or ad hoc, the ZenSched shift id, the Attempt Record's outcome / manner / description / photo count / submission id, and the GPS stamps copied once
- Mileage with the IRS rate snapshot and deduction
- Invoices per client with aging; payouts per sub per serve or per attempt
- Your settings (timezone, state, default server, attempt length, included attempts, invoice terms and prefix, mileage rate, Attempt Record form id)

**Never duplicated:** the live schedule, punches, and photos stay in ZenSched. The local database stores *references* to them plus the few facts you need to answer "did Luis go", "give me the log", and "who owes me" without paying to re-read records.

### Privacy note

Everything that identifies a servee or a case party lives only in the local database: `cases.servee_name`, `servee_phone`, `servee_dob`, `servee_notes`, `plaintiff`, `serve_addresses.notes`, `places.access_notes`, `clients.contact_name`, and `servers.license_no`. `SKILL.md` forbids the AI from putting any of them into any ZenSched field, including location names, event titles, notes, and cancellation reasons (subs see those). ZenSched receives, per serve address, the street address (it has to, for the geofence), a location label and event title made of the court case number and the street (`Serve 24-CV-1187 - Marconi Ave`; case numbers are public record), and the Attempt Record. The record's "Physical description of person contacted" field **does** go to ZenSched because it is operational and the sub fills it in on the spot; it is labelled "(no names)", the form's header says so again, and `SKILL.md` tells the AI to brief every server that it is sex / age / height / build / hair / clothing / stated relationship only. The summons itself is never stored anywhere in this kit. Do not photograph people.

## How it works day to day

Your AI assistant has two sets of tools:

1. **ZenSched tools** (`location_create`, `event_create`, `shift_create`, `shift_status`, `form_submissions`, ...) that talk to ZenSched over the internet.
2. **A SQLite tool** (`sqlite_query`, `sqlite_execute`) that reads and writes `serve-ops.db` on your computer.

When you paste a service request, the AI extracts the client, their file number, the court and case number, the documents, the defendant and any hints, the addresses, the rush flag, the due date, and the fee; adds the client if new; looks each address up in your `places` cache (a complex or workplace you have been to before is reused, a new address is geocoded once); saves the case as `C-2026-0001`; pins every address on ZenSched and opens an event for each so an unplanned attempt later is one call; and puts the first attempt window on your phone, plus two more on different days and times of day if you want them. You see the window in the app, check in at the door (GPS-verified), knock, fill in the Attempt Record with the door photo, check out. When you decide to try again at 8:40 pm on the way home, you text the AI "I'm at Reyes' now" and a window is on your phone before you are out of the car. In the evening you say "log today's attempts" and the AI pulls the verified times and the records, updates each attempt, asks before closing a case as served, and tells you what is now receivable. "Diligence log for Reyes" gives you the numbered attempt paragraphs for the affidavit. "What's at risk" lists open cases by deadline. "Did Luis actually go" answers from the punches. "Invoice Hollis" produces a plain-text invoice under their terms; "who owes me money" ages what is open; "what do I owe Luis" lists his attempts. You never run SQL yourself. `SKILL.md` in this repo is the instruction sheet that teaches the AI how to do all of this; you paste it into your AI tool once.

## Setup

### 0. What you need

- **An AI tool that supports MCP.** These instructions use Claude Desktop (Windows or Mac). Cursor works too.
- **Node.js 20 or newer.** The SQLite tool runs on it. Download the LTS installer from [nodejs.org](https://nodejs.org/) and run it with the defaults. This is the only software install.
- You do **not** need the `sqlite3` command-line program, Python, or Git.

### 1. Make a folder for your data

Create a folder where the database will live and write down its full path. Examples:

- Windows: `C:\Users\YourName\serve-ops`
- Mac: `/Users/yourname/serve-ops`

The database file will be created automatically inside this folder the first time the AI uses it. This folder will contain defendants' names and phone numbers; keep it on an encrypted, backed-up disk, not in a shared folder.

### 2. Add both tools to your AI's config file

Open the MCP configuration file for your AI tool:

- **Claude Desktop, Windows:** `%APPDATA%\Claude\claude_desktop_config.json` (paste that into the File Explorer address bar)
- **Claude Desktop, Mac:** `~/Library/Application Support/Claude/claude_desktop_config.json` (in Claude Desktop: Settings → Developer → Edit Config)
- **Cursor:** Settings → MCP → Add new global MCP server

Paste in the contents of `mcp.json.example` from this repo, then change one line, the `SQLITE_PATH`, to point at your folder from step 1 plus `\serve-ops.db` (Windows) or `/serve-ops.db` (Mac):

```json
{
  "mcpServers": {
    "zensched": {
      "url": "https://mcp.zensched.com/mcp",
      "headers": { "Authorization": "Bearer zsc_your_key_here" }
    },
    "serve-ops-db": {
      "command": "npx",
      "args": ["-y", "easy-sqlite-mcp"],
      "env": { "SQLITE_PATH": "/Users/yourname/serve-ops/serve-ops.db" }
    }
  }
}
```

**Windows path gotcha:** inside a JSON file every backslash must be doubled. Write `"C:\\Users\\YourName\\serve-ops\\serve-ops.db"`, not `"C:\Users\..."`. A single backslash will silently break the config.

**Leave `zsc_your_key_here` exactly as it is for now.** You do not have a key yet. The ZenSched tools that create your account work without one, and you will fill this in during step 3.

Save the file and **fully quit and reopen** your AI tool (on Mac, Cmd-Q; on Windows, right-click the tray icon → Quit). It only reads this file on startup.

### 3. Create your ZenSched account

In a new chat, type:

> Call `zensched_guide`, then call `account_create` with org_name "My Process Service" (use my real business name if I told you one). Show me the `zsc_` key it returns.

Copy the `zsc_` key. Go back to the config file from step 2, replace `zsc_your_key_here` with your real key, save, and fully quit and reopen the AI tool again.

Some clients can adopt the key mid-session with `account_use_key`; you can ask the AI to try that to keep going immediately, but still update the config file so the key survives restarts. Keep the key private; it is the password to your account.

### 4. Create the database tables

Open `schema.sql` from this repo in any text editor, copy the whole thing, and paste it into the chat with this message in front of it:

> Create these tables in my serve-ops database. Run each statement one at a time using the SQLite tool, then list the tables to confirm.

The AI will run 67 statements and confirm the tables exist. The `serve-ops.db` file now exists in your folder with default settings (20-minute attempt windows, 3 attempts included in a routine fee, net 30, $0.70/mile) you can change.

If you happen to have the `sqlite3` command-line tool, `sqlite3 serve-ops.db < schema.sql` does the same thing, but it is not required.

### 5. Teach the AI the workflow

Paste the contents of `SKILL.md` into your AI tool as standing instructions. In Claude Desktop, create a Project and put it in the project instructions; in Cursor, save it as a rule. Then tell it your basics once:

> We're Northstar Legal Process in Minneapolis, Central time. It's me, Dana Whitfield, dana@example.com, Hennepin County registration 4471. Set me up.

It writes those to the `settings` table, **invites you to ZenSched as a worker** (you are the server on the phone; $0.25, one time), creates the Attempt Record form on ZenSched (free), saves the form id so every serve address gets it automatically, and sets the check-in policy. In agency mode you then say "add my sub Luis Ortega, luis@example.com, I pay him $20 an attempt" (or "$45 a serve", or "60%") for each server you dispatch.

**Check-in radius and slack.** ZenSched enforces the radius through the account's policy, not per address, and with geofencing on it raises anything under 100 m to about 91 m (300 ft), so a house and its driveway are covered as is. For apartment complexes and gated communities where you park a long way from the unit, ask the AI to "set the check-in radius to 150 m" or 250 m (`policy_update`), or to move the pin onto the right building for a repeat complex (`location_update`, free; the `places` cache keeps it). The kit sets `checkin_slack_min` to **30**: that is the early/late tolerance around a shift, so you can punch at 6:05 for a 6:30 window, and an "I'm here now" window the AI opened a minute after you parked still accepts the punch. `remote_checkin` turns GPS verification off for every attempt and should be a last resort, because it also turns off the proof.

**Forgotten check-outs.** The kit sets a check-out reminder 15 minutes after the window ends (`checkout_reminder_min_after`).

### 6. Funding (only when asked)

The first 200 ZenSched tool calls per day are free. Some things are metered: creating a location (geocoding, $0.03; skipped for a cached repeat address), inviting a worker ($0.25, including yourself), each GPS-verified check-in or check-out ($0.10), and reading an Attempt Record ($0.15 with the door photo, which the form requires; each record is billed once, ever). When a metered call happens without funds, the AI will get a `payment_required` response and tell you how to add the $5 activation deposit, which is credited to your balance. You will not be charged without seeing this first.

An attempt at a new address costs $0.03 + $0.20 + $0.15 = **$0.38**; every further attempt at that address costs $0.35. A serve at 2.2 attempts is about $0.80; thirty serves a month is about $24. The AI states the cost before it spends.

## Using it

Everything after setup is plain English. Examples:

- (paste the firm's service request) "Take it." / "Take it, first attempt tomorrow evening."
- "I'm at Reyes' house now." / "Luis at Garcia now."
- "Log today's attempts." / "What happened on Reyes?"
- "Diligence log for 24-CV-1187." / "I need the attempts for the Garcia affidavit."
- "What's at risk this week?" / "What's open?"
- "Which cases are past three attempts?"
- "Did Luis actually attempt Garcia last night?"
- "Is anyone still checked in?"
- "Garcia's a bad address; the firm has nothing else. Close it."
- "Move tonight's Reyes to 8." / "Cancel Saturday."
- "Invoice Hollis & Marquez." / "Invoice everyone."
- "Who owes me money?" / "Hollis paid INV-2026-0002."
- "What do I owe Luis?" / "Paid Luis."
- "Mileage for September?"

See `QUICKSTART.md` for the first-week walkthrough and `example-workflow.md` for exactly which tools the AI calls behind each of these.

### Planned windows and "I'm here now"

ZenSched only records a GPS check-in against a scheduled shift, and servers decide to attempt at 9 pm on the way home. The kit handles that two ways, and `SKILL.md` teaches both:

- **Planned windows.** When a case comes in, the AI creates the first attempt window immediately and offers two more on **different days and different times of day** (a weekday morning, a weekday evening, a weekend), which is the variety courts look for in a declaration of diligence. Each is a 20-minute shift on the address's event. Planned windows can be moved, cancelled, or handed to another server.
- **"I'm here now."** You (or a sub, through you) text the AI "attempting Garcia now". The AI inserts an attempt with `scheduled_start` = now, creates a shift from now to now + 20 minutes on the address's existing event, and replies in one line. The server punches within the minute. Because every serve address gets its location and event at intake, this is a single ZenSched call.

The `checkin_slack_min` policy setting (30 minutes in this kit) is what makes both work: early or late punches around a planned window are accepted, and an ad hoc window created a minute after the server parked accepts the punch too. This is the kit's answer to a platform gap: ZenSched has no "check in now at location X" without a shift, so the agent creates the shift. It is one round-trip, not zero.

### What "invoice" means here

"Invoice Hollis" records the invoice in your database (number, date, due date under that client's terms, total, which cases with attempt counts and the fee breakdown) and the AI writes out a plain-text invoice you can paste into an email or the firm's payables portal, with a line per case (your case ref, their file number, the court case number, documents, served date and manner or "non-service – bad address", attempts made, serve fee, extra attempts × rate, rush, mileage, other). It does **not** generate a PDF, submit it for you, or collect payment. Invoices never carry a defendant's name, phone, or address; the court case number and the firm's file number identify the matter to them. When the client pays, tell the AI ("Hollis paid INV-2026-0002") and it marks it paid. "Who owes me money" ages what is open into current / 30 / 60 / 90+ days past due.

### What "payouts" means here (agency mode)

Subs are paid per serve or per attempt, not by the hour. Each sub has a split: `$45 per serve` (one payout when a case they served or closed as non-service is finished), `$20 per attempt` (one payout per attempt they actually made), or `60%` of what the client is billed for the case. When results are logged, payout rows are created with the amount; "what do I owe Luis" lists his unpaid work and the total, and "paid Luis" marks them. Your own attempts never generate payouts. The kit does not calculate taxes, issue 1099s, or pay anyone. If you also want an hours record, ZenSched's `timesheet_export(mode="hours")` is free; `mode="raw"` (one row per punch, free) is the export to hand a court if asked for the underlying GPS record.

## Mobile app for servers

- **Android:** [Google Play](https://play.google.com/store/apps/details?id=com.zensched.app)
- **iOS:** [App Store](https://apps.apple.com/us/app/zensched/id6800081657)

In solo mode you invite yourself; the email arrives at your own address, you install the app, and your attempt windows appear as they are created. Each one shows the address and time; you check in on arrival (GPS-verified), knock, fill in the Attempt Record with the door photo, and check out. Subs get the same email when you add them.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| AI says it has no ZenSched tools | Config file not saved, or the app was not fully restarted | Check the JSON is valid (paste it into [jsonlint.com](https://jsonlint.com)), then quit and reopen the app |
| AI says it has no SQLite / `serve-ops-db` tools | Node.js not installed, or bad `SQLITE_PATH` | Install Node.js LTS; on Windows check every backslash is doubled |
| `SQLITE_PATH` points nowhere / "unable to open database" | Folder from step 1 does not exist | Create the folder; the file is created automatically but the folder is not |
| ZenSched tools return an auth error | Key still says `zsc_your_key_here`, or was pasted with a space | Re-paste the key, restart |
| `payment_required` | Metered call with no balance | Follow the instructions in the response; $5 deposit |
| AI creates shifts at the wrong hour | Timezone not set, or daylight saving changed | "Set my timezone offset to -06:00 in settings" (use your own offset; Central is -05:00 in summer, -06:00 in winter) |
| Attempt not on my phone | Planned locally but the ZenSched shift was never created (`needs_shift = 1`) | "Put this week's attempts on my phone"; the AI finishes the intake steps |
| Check-in rejected: too early / too late | Slack window too small for how you actually work | "Set the check-in slack to 45 minutes" (`checkin_slack_min`, max 240), or have the AI `shift_update` the window before you punch |
| Check-in rejected: not at the location, at a complex or gated community | You parked outside the policy radius, or the pin is on the road | "Set the check-in radius to 200 m" (`policy_update(0, {"checkin_radius_m": 200})`; never "on that location"), or "move the pin to building 12" (`location_update`, free; the cached place keeps it), or `location_refine` ($0.10) |
| "I'm here now" took too long and the punch was refused | Window opened more than `checkin_slack_min` after the server arrived | Have the AI `shift_update` the window to the real arrival time; raise the slack |
| Sub says they attempted but there is no check-in | They never punched, or the phone was elsewhere | `shift_status` says `scheduled` / `missed`, or shows a punch with a large distance; that is the answer. The log will say `time_source = scheduled` for an attempt recorded without a punch |
| Forgot to check out | Shift still `checked_in` | Tell the AI the real time; the 15-minute check-out reminder is already on |
| Attempt Record not on the phone | Form not assigned to that serve address's event before the shift was created | "Attach the Attempt Record to the Garcia address" (`form_assign`), then cancel and recreate the shift |
| A sub typed a name into the description field | Briefing slipped | The AI keeps it local and flags it; remind the sub. Names go on the affidavit, not the form |
| Same complex geocoded twice | Address typed differently ("Apt 12" vs "#12", "Ave" vs "Avenue") | Tell the AI it is the same place; it merges the `places` rows and keeps one location |
| `shift_create` fails: date outside the event | The attempt is after the address's event window (`event_valid_until`); the case ran long or the deadline moved | The AI rolls a new event for that address (free) and retries; "the deadline on Reyes moved to the 30th" first if that is why |
| Case shows in "ready for substitute" and I don't think it is | The flag counts attempts against the fee's included attempts | It is a count, not a rule. Ignore it, or change the case's `included_attempts` |
| Door photos have no date/time stamp on them | ZenSched does not watermark images | Turn on your camera's timestamp / GPS overlay before shooting (required in California from 2027) |
| Mileage deduction looks off | `irs_mileage_rate` still last year's | "Set the mileage rate to 0.72"; existing trips keep their snapshot |
| AI asks you to run SQL yourself | It does not have `SKILL.md` loaded | Re-paste `SKILL.md` as project instructions |

If something is confusing or broken in ZenSched itself, ask the AI to call `feedback_submit` with a description. It is free, needs no account, and a human reads every submission.

## For developers

**Architecture.** Two MCP servers, no application code. The agent is the integration layer; `SKILL.md` is the spec it follows. ZenSched is authoritative for operations (schedule, punches, form submissions and photos); SQLite is authoritative for clients, places, roster, cases (including all servee PII), serve addresses, attempts, mileage, billing, and payouts; each side stores only the other's IDs, plus a per-attempt summary and the GPS stamps cached locally because submission reads are metered. The PII boundary is enforced by data placement (servee columns exist only locally, and the views compute the ZenSched-safe `zensched_location_name` / `zensched_event_title` strings) and by `SKILL.md` rules 1–2; there is no technical control stopping a misbehaving agent, so review the rules if you swap models.

**Data model decisions.**

- **Case → serve address → attempts.** The notary kit's `appointments` table was one row = one event = one shift. Process serving is one job with several addresses and several attempts per address, so the driving table is `attempts`, owned by `serve_addresses`, owned by `cases`. `cases` carries the fee snapshot and the deadline; `serve_addresses` carries the ZenSched event; `attempts` carries the ZenSched shift and everything copied from the Attempt Record and the punches.
- **One event per serve address, rolled.** `event_create` is per `serve_addresses` row, `start_date` = the day it is opened (intake day), `end_date` = `min(cases.due_by, start + 59 days)`; the address stores `zensched_event_id` and `event_valid_until`. The `serve_addresses_sync` view flags `needs_event` when there is no event or it has expired and computes the window; `attempts_planned.needs_event` flags an attempt dated past `event_valid_until` so the agent rolls before `shift_create`. Same pattern as the homecare and petcare kits, with the deadline as an extra cap. Every address on a case is pinned and given an event at intake, even with no window planned there yet, so an ad hoc attempt anywhere on the case is one `shift_create`.
- **Planned windows vs ad hoc.** Both are `attempts` rows; `is_adhoc` distinguishes them for `server_activity`. A planned window has a future `scheduled_start`; an ad hoc one has `scheduled_start` = now and gets a shift immediately. The kit relies on `checkin_slack_min` (30) so both accept real-world punch times. There is no punch-without-shift path on the platform; this is the workaround, and the pitch lists the gap.
- **`attempt_no` is per address, in insertion order; `seq` is per case, in time order.** The `number_attempt` trigger numbers attempts within a `serve_address_id` as they are inserted, which is what the owner means by "third try at the house". A cancelled window keeps its number, so gaps are possible. `due_diligence_log.seq` is `ROW_NUMBER()` over all *made* attempts on the case ordered by actual check-in (else planned start), which is the number that goes in the affidavit. Use `seq` for the declaration, `attempt_no` for conversation.
- **`due_diligence_log` is the product.** One row per attempt with `status IN ('attempted','served')`, ordered by case then time. Times are local 12-hour strings built from the GPS punch (`time_source = 'gps'`) or the planned window (`'scheduled'`). ISO timestamps with an offset are `substr(…, 1, 19)`'d before formatting because SQLite's date functions convert an offset-bearing string to UTC. The view also emits `day_part` (morning / afternoon / evening / weekend), `minutes_on_site`, `gps_verified`, `checkin_distance_m`, `photo_count`, `server_name`, and the local `license_no`. `cases_ready_for_substitute` groups it and flags open cases with `COUNT(*) >= included_attempts`, with `distinct_days`, `distinct_day_parts`, and `addresses_tried` alongside; it is a count because the rule is the server's.
- **`places` is an address de-dup cache** (from the notary kit). `normalized_address` is `UNIQUE`; the agent normalizes and looks it up before any `location_create`. A hit reuses `zensched_location_id`, saving the $0.03 and preserving a hand-tuned pin on an apartment building. `street_name` (no house number) is stored so event titles read `Serve 24-CV-1187 - Marconi Ave`; `place_label` defaults to the same string for a home and to `<business> - <city>` for a workplace.
- **`case_ref` and `case_no`.** `case_ref` is the kit's own number (`C-{YYYY of received_date}-{case_id:04d}`, by trigger when NULL) so a job with no court number yet still has a handle; `case_no` is the court's number. Views expose `case_label = COALESCE(case_no, case_ref)`, which is what appears in ZenSched labels. Case numbers are public record; defendant names are not put next to them anywhere on ZenSched.
- **Solo mode is the default; agency mode is additive.** The owner is invited as a worker and stored on `servers` with `is_owner = 1`; `settings.default_server_id` points at that row and `fill_attempt_defaults` assigns it when `server_id` is NULL. Subs are further `servers` rows with `payout_type` `CHECK IN ('per_serve','per_attempt','percent')`.
- **Billing is computed in `billable_cases`, not stored.** Fee columns on `cases` (`serve_fee`, `included_attempts`, `extra_attempt_fee`, `rush_fee`, `mileage_fee`, `bad_address_fee`, `other_fee`) are snapshots filled by trigger from the client's defaults (then `settings.default_included_attempts`, then 0/3). `attempts_made` counts `attempted` + `served` rows across all of the case's addresses; `extra_attempts = max(0, attempts_made − included_attempts)`. `served` → serve + extras + rush (if `is_rush`) + mileage + other; `not_served` → bad_address + extras + rush + mileage + other; `cancelled` → `other_fee` only; `open` → 0. `receivables_by_client`, the invoice `INSERT … SELECT`, `payouts_due`, `payouts_missing`, and the `fill_payout_amount` trigger all read from that view.
- **Payouts key on a case or an attempt.** `payouts` has `case_id` and `attempt_id` with a `CHECK` that exactly one is set, and two partial `UNIQUE` indexes (`ux_payouts_case`, `ux_payouts_attempt`). `fill_payout_amount` uses `payout_value` for `per_serve` (case) and `per_attempt` (attempt), and `billable_total × payout_value / 100` for `percent` (case); a mismatch (per-attempt sub given a case key) leaves `amount` NULL and `payouts_due.needs_amount = 1`. `payouts_missing` is a `UNION ALL` of the two shapes with `key_type` telling the agent which column to fill; for per-serve / percent subs the "owning" server is the one on `served_attempt_id`, else the most recent attempt.
- **`scheduled_start` is local wall-clock time without an offset** (`2026-09-08T18:30`, `CHECK`-constrained to reject a trailing offset or `Z`). `attempts_planned` / `attempts_upcoming` emit `start_iso` and `end_iso` by appending `settings.timezone_offset`. Day-based views use `date('now', 'localtime')` because the SQLite MCP server runs on the owner's computer, whose clock is in the business's time zone.
- **`status` and `outcome` are separate.** `outcome` is the raw Attempt Record option key; `manner` is the normalized service manner (`personal | substituted | posted | mail | refused | not_served`); attempt `status` is `attempted` or `served`; `cases.status` moves to `served` only when the owner confirms. Refusal is left to the owner (drop service is a rule question).
- **No signature field on the form.** ZenSched replaces the Submit button with the signature pad when a form has a `signature` field, and the sworn signature belongs on the affidavit. `door_photo` is a required `photo` field (`max_images: 3`), so every submission bills $0.15.
- **GPS stamps are copied once.** `checked_in_at`, `checked_out_at`, `gps_verified`, `checkin_distance_m` are filled from `shift_status` when results are pulled, so the log and "did Luis go" are answered locally. ZenSched remains the original. `open_attempts_now` therefore only knows about check-ins that have been pulled; `SKILL.md` pairs it with a live `shift_list(status="checked_in")`.
- **`mileage`** snapshots `rate` from `settings.irs_mileage_rate` (seeded `0.70`, the 2025 IRS business rate; update yearly) and computes `deduction` by trigger. `attempt_id` is nullable for court runs. `cases.mileage_fee` (what the firm is billed) is separate from this (what you deduct).
- `attempts.zensched_shift_id`, `servers.zensched_worker_id`, `places.normalized_address`, `cases.case_ref`, and `invoices.invoice_number` are `UNIQUE`. `PRAGMA foreign_keys = ON` is in `schema.sql` and `SKILL.md` tells the agent to run it per session. Deleting a client cascades to cases, serve addresses, attempts, invoices, and payouts and sets `mileage.attempt_id` NULL; deleting a server sets `attempts.server_id` NULL and removes their payouts; `places` is `ON DELETE RESTRICT` while serve addresses reference it; `cases.served_attempt_id` is `ON DELETE SET NULL`.

**Names vs the pitch.** The pitch's reference-design section names `clients`, `cases`, `serve_addresses`, `attempts`, `due_diligence_log`, `invoices`, a `receivables` aging view, and `sub_payouts` with a per-sub rate table. The kit keeps `clients`, `cases`, `serve_addresses`, `attempts`, `due_diligence_log`, and `invoices` as named. `receivables` is two views, `receivables_by_client` (uninvoiced work) and `invoices_outstanding` (aging), matching the notary kit. `sub_payouts` is `payouts` plus `payouts_due` / `payouts_missing`, and the per-sub rate lives on `servers.payout_type` / `payout_value` rather than a separate table. The pitch's form had `show_if` fields for "left with" and description; the kit uses a plain `served_person` select and one conditional `person_description` textarea.

**Attempt Record form.** Created once with `form_create(title, fields_json, idempotency_key="form-attempt-record")`; the exact `fields_json` is in `SKILL.md` and `example-workflow.md` (byte-identical) and was validated against ZenSched's form validator (`_validate_fields`): 8 fields, all valid. Every field carries an explicit `identifier` so submission `data` keys are stable (`outcome`, `served_person`, `person_description`, `vehicles_seen`, `door_photo`, `docs_left`, `notes`). Option keys are derived by ZenSched from the labels (lowercase, non-alphanumerics → `_`, truncated at 30 characters); every option label here is ≤ 30 characters, so nothing truncates: `outcome` ∈ `served___personal`, `served___substituted`, `posted___affixed`, `no_answer`, `not_at_address___moved`, `bad_address`, `evasive___refused_door`, `refused_to_accept`, `other`; `served_person` ∈ `servee`, `co_resident_adult`, `person_in_charge_at_workplace` (29 characters, the longest), `other_adult`, `not_applicable`; `docs_left` ∈ `yes`, `no`. One `show_if` references `outcome` with `not_equals no_answer`; the description field stays hidden on the phone when the outcome is no answer. Attaching is `form_assign(form_id, event_id=...)` per serve-address event, once, before the first shift on that event.

**Idempotency keys.** Deterministic, derived from local IDs so a retried or re-run agent turn cannot duplicate:

- location: `loc-place-{place_id}`
- event: `event-sa-{serve_address_id}-{YYYYMMDD of the window start}`
- shift: `shift-attempt-{attempt_id}` (a server swap on the same attempt appends `-2`)
- assignment: `assign-attempt-{event_id}`
- cancel: `cancel-shift-{shift_id}`
- worker: `worker-{email}`
- form: `form-attempt-record`

ZenSched caches idempotent responses for 24 hours. The views emit `loc_idempotency_key`, `event_idempotency_key`, and `shift_idempotency_key` per row.

**Timestamps.** `shift_create` / `shift_update` take `start` and `end` in ISO 8601 with an explicit offset. Always use the business's local offset from `settings.timezone_offset` (e.g. `2026-09-08T18:30:00-05:00`), never `Z`. The views build these strings so the agent does not have to. `checked_in_at` / `checked_out_at` keep the offset ZenSched returns so `julianday` arithmetic in `minutes_on_site` is exact, and are `substr`'d to the local wall clock for display.

**Metered reads.** `form_submissions(form_id, event_id=...)` returns every submission on that serve address's event; the agent matches on `worker_id` / `submitted_at` and skips submission ids already stored, which are free to skip because each submission bills once ever. `form_export` covers a day or week in one call. `shift_list`, `shift_status`, `event_get`, and `timesheet_export(mode="hours"|"raw")` are free.

**Check-in policy.** The radius is enforced by `policy_update(0, '{"checkin_radius_m": N}')`, not by `location_create(checkin_radius_m=...)`, which is informational; with geofencing on, values under 100 m are raised to about 91 m. `checkin_slack_min` (0–240) is the early/late window around a shift and is the setting that makes planned and ad hoc attempts practical; the kit uses 100 m / 30 min / 15-minute check-out reminder.

**SQLite MCP server.** `mcp.json.example` uses [`easy-sqlite-mcp`](https://github.com/chenkumi/easy-sqlite-mcp) (Node, `better-sqlite3`, `SQLITE_PATH` env var). Its `sqlite_execute` calls `prepare()`, so it accepts **one statement per call**; `schema.sql` is written so every statement stands alone and is idempotent. `due_diligence_log` and `payouts_due` use window functions (`ROW_NUMBER() OVER`, `SUM() OVER`), which need SQLite ≥ 3.25 (2018); the 12-hour times are built with `CASE` arithmetic rather than `%I` / `%p` so they work on SQLite before 3.44 too. `better-sqlite3` bundles a current SQLite. Any SQLite MCP server with read and write tools will work; adjust the tool names in `SKILL.md`.

**Schema test.** The schema was verified by splitting the file into its 67 statements with `sqlite3.complete_statement` and executing each individually (as the MCP server does) twice for idempotency (seed rows not duplicated), then exercising: all 10 tables, 14 views, and 14 triggers present; every view on an empty database; `places.normalized_address`, `servers.zensched_worker_id`, and `attempts.zensched_shift_id` `UNIQUE`; the `number_case` trigger (`C-YYYY-0001`, explicit ref kept) and `fill_case_defaults` (fees from the client, `included_attempts` from the client then a changed setting, explicit fee kept); `serve_addresses_sync` (`needs_location` / `needs_event`, expired event flagged, current event not, window today → `due_by`, names, keys, inactive excluded); the `number_attempt` trigger incrementing independently across two addresses on the same case (1, 2, 3 / 1 / 1) with an explicit number kept; `fill_attempt_defaults` (20 minutes and the default server, following a changed setting, explicit values kept); `attempts_planned` / `attempts_upcoming` (`start_iso` / `end_iso` with offset for `HH:MM` and `HH:MM:SS` inputs and 20/30-minute durations, the three idempotency keys, `needs_location` / `needs_event` / `needs_shift` before and after ids are set, `needs_event` when the attempt is past `event_valid_until`, `event_end_date` capped at `due_by` and at start + 59 when `due_by` is NULL, `days_left`, `day_part`, titles from `case_no` or `case_ref` with no servee name, 7-day window, cancelled excluded); `updated_at` triggers on cases, clients, and attempts; `cases_open` (`attempts_made`, `active_addresses`, `next_planned`, `overdue_risk` for overdue / high / medium / no_deadline); `due_diligence_log` for a 3-attempt case across two addresses (`seq` 1–3 in time order vs `attempt_no` 1, 2, 1; 12-hour `time_in` / `time_out` from offset-bearing punches without UTC conversion, including noon and midnight; `minutes_on_site`; weekday; manner, outcome, description, photo count, GPS flag, server name, license; planned and cancelled excluded; `time_source = scheduled` fallback); `cases_ready_for_substitute` flagging only at ≥ `included_attempts` and only while open, with `distinct_days` / `addresses_tried` / `attempts_gps_verified` / `attempts_with_photo`; `open_attempts_now` (listed 88 minutes after check-in with no check-out, dropped after check-out, not listed inside the window); `billable_cases` for served with no extras (85), one extra attempt (110), rush + mileage + other (202.50), open (0), `not_served` rush (bad address 40 + rush 60 = 100, serve fee not billed), cancelled (`other_fee` 30); `receivables_by_client` totals and counts per client and the drop-off after invoicing; invoice numbering, total, due date from the client's terms, `line_items` JSON with attempt counts and fee breakdown; `invoices_outstanding` aging buckets `current` / `90+` / `60` / `30` with `days_past_due` and paid excluded; payouts for `per_attempt` (20), `per_serve` (45), `percent` (60% of 100 = 60), no split (NULL), key/type mismatch (NULL), the one-key `CHECK`, both partial `UNIQUE` indexes, owner exclusion, `needs_amount`, `server_total_due`, paid rows dropping out; `payouts_missing` for a per-attempt sub's attempt and a per-serve sub's non-service case with `key_type`; the mileage trigger (23.4 × 0.70 = 16.38, explicit rate kept, nullable attempt, recompute on update) and `mileage_by_month`; `server_activity` counts and `gps_verified_pct` (50.0) with NULL for a server without attempts; every `CHECK` (client type, payout type, address type, case status, served manner, attempt status, attempt manner accepting NULL and rejecting a bad value, `scheduled_start` format with offset / `Z` / space / prose rejected, duration range, miles ≥ 0, payouts key); foreign keys rejecting an unknown client, place, and serve address, `RESTRICT` on places, `SET NULL` / cascade on server delete, cascade from case to addresses / attempts / payouts with `mileage.attempt_id` set NULL, and the full cascade on client delete. 148 checks, all passing.

## Support

- ZenSched docs: <https://www.zensched.com/docs/>
- Tool reference: <https://www.zensched.com/docs/tools/>
- Feedback: ask your AI to call `feedback_submit` (categories: `bug`, `friction`, `missing_capability`, `docs`, `billing`, `feature`, `other`)

## License

MIT. See `LICENSE`.
