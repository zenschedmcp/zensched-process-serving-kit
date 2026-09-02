# Quickstart

Setup is about 15 minutes, once. After that everything is plain English to your AI. Each step below tells you what to do and, where relevant, exactly what to type to the AI.

You need: Claude Desktop (or Cursor) and [Node.js LTS](https://nodejs.org/) installed. Nothing else.

Before you start, read the "This is not an affidavit generator" section of `README.md`. Short version: this kit puts every attempt on your phone, GPS-stamps it at the door, and hands you the diligence log; it does not write the affidavit, does not know your state's rules, does not watermark photos (California servers: camera timestamp overlay on from 2027), and is not a panic button. Defendant names, phones, and documents stay on your computer; ZenSched only ever sees a serve address, a label with the court case number, and the Attempt Record.

## 1. Make a data folder

Create a folder such as `C:\Users\YourName\serve-ops` (Windows) or `/Users/yourname/serve-ops` (Mac). Note the full path. It will hold defendants' names and phone numbers, so keep it on an encrypted, backed-up disk, not a shared folder.

## 2. Add the two tools to your AI's config

Open the config file:

- **Claude Desktop, Windows:** `%APPDATA%\Claude\claude_desktop_config.json`
- **Claude Desktop, Mac:** `~/Library/Application Support/Claude/claude_desktop_config.json`
- **Cursor:** Settings → MCP → Add new global MCP server

Paste this in and fix only the `SQLITE_PATH` line to match your folder from step 1:

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

- On Windows, double every backslash: `"C:\\Users\\YourName\\serve-ops\\serve-ops.db"`.
- Leave `zsc_your_key_here` as it is. You get the real key in the next step.

Save, then **fully quit and reopen** the AI app.

## 3. Create your ZenSched account

Type to the AI:

> Call zensched_guide, then account_create with org_name "My Process Service". Show me the zsc_ key.

Copy the key into the config file in place of `zsc_your_key_here`. Save. Quit and reopen the app once more. (You can also ask the AI to call `account_use_key` with the key to continue right away, but update the file anyway so it sticks.)

## 4. Create the database tables

Copy the full contents of `schema.sql` and paste it into the chat with this line above it:

> Create these tables in my serve-ops database. Run each statement one at a time with the SQLite tool, then list the tables to confirm.

## 5. Give the AI its instructions

Paste `SKILL.md` into the AI as standing instructions (Claude Desktop: a Project's instructions; Cursor: a rule). Then:

> We're Northstar Legal Process in Minneapolis, Central time. It's me, Dana Whitfield, dana@example.com, Hennepin County registration 4471. Set me up.

The AI saves your settings, invites **you** to ZenSched as a worker ($0.25, once; you are the server on the phone), calls `form_create` once (free) to build the Attempt Record you fill in at every door (outcome, who accepted, a physical description with no names, vehicles and lights, a door photo, documents left, notes; no signature pad), stores the form id so every serve address gets it, and sets the check-in policy: 100 m radius, **30 minutes of slack** so an early, late, or on-the-spot punch is accepted, and a check-out reminder 15 minutes after the window. Install the app from the invitation email ([Android](https://play.google.com/store/apps/details?id=com.zensched.app) / [iOS TestFlight](https://testflight.apple.com/join/Wp51m5Yq)).

If you work apartment complexes and gated communities: "Set the check-in radius to 200 m."

Agency mode: "Add my sub Luis Ortega, luis@example.com, I pay him $20 an attempt" (or "$45 a serve", or "60%") for each server you dispatch. Brief every sub once: the description field on the Attempt Record is **physical only, no names**. Names go on the affidavit.

## 6. Intake your first case

Paste the firm's service request email, then:

> Take it.

Behind the scenes the AI extracts the client, their file number, the court and case number, the documents, the defendant and any hints, the addresses (home, work), the rush flag, the deadline, and the fee; adds the client if new (asks for their terms and fee schedule); checks whether you have been to each address before, and if not calls `location_create` (geocode, $0.03 each, may trigger the $5 activation deposit the first time); saves the case as `C-2026-0001` with the defendant's name kept local; opens one `event_create` per address titled `Serve 24-CV-1187 - Marconi Ave` (court number and street, never a name), attaches the Attempt Record with `form_assign`, and puts the **first attempt window** on your phone with `shift_create`. It offers two more windows on different days and times of day (a morning, an evening, a weekend), which is the variety a declaration of diligence wants. Say yes, or "just the first one."

> Take it, first attempt tomorrow evening.

Same, with the first window where you said.

## 7. The attempt

Your phone shows the window with the address. At the door, **Check in** (GPS-verified). Knock. Open the **Attempt Record** on the shift: outcome, who accepted if substituted, physical description, vehicles / lights, door photo (California: camera timestamp overlay on), documents left, notes. Submit. **Check out**.

## 8. "I'm here now"

You decide to try again at 8:40 pm on the way home:

> I'm at Reyes' house now.

The AI opens a 20-minute window on your phone starting now (one `shift_create` on the address's existing event; a few seconds) and replies in one line. Check in, knock, record, check out. For a sub: "Luis at Garcia now."

## 9. Log the results

> Log today's attempts.

The AI pulls the GPS-verified check-in and check-out for each window (free), reads each Attempt Record once (metered, so it tells you the cost first, $0.15 each with the door photo), updates every attempt with outcome, manner, description, photo count, and times, and asks before marking a case **served**. If a sub is paid per attempt, the payout row is created now. It tells you what is now receivable.

> Did Luis actually attempt Garcia last night?

Answered from ZenSched's punch record: checked in 8:41 pm, 14 m from the pin, out 8:52, one door photo. Or: no check-in.

> Is anyone still checked in?

Anyone checked in past their window with no check-out, with their phone number. A record, not an alarm.

## 10. The diligence log

> Diligence log for 24-CV-1187.

Every attempt on the case in time order: date, day, time in and out (GPS-verified or scheduled), address, outcome and manner, physical description, photo count, server, registration number, formatted as the numbered paragraphs you paste into **your** declaration. Add the sworn parts and sign it yourself.

> What's at risk this week?

Open cases by deadline, attempts made against included, next planned window.

> Which cases are past three attempts?

Cases at or past the attempts your fee includes and not yet served, with how many days and times of day were tried. A count, not a rule: what to do next is yours.

> Garcia's a bad address; the firm has nothing else. Close it.

Non-service closeout: bad-address fee billable, remaining windows cancelled.

## 11. Money

> Invoice Hollis & Marquez.

A plain-text invoice under their terms with one line per case (your ref, their file number, the court case number, documents, served date and manner or non-service, attempts made, serve fee, extra attempts, rush, mileage). Nothing about defendants on it.

> Who owes me money?

Open invoices aged current / 30 / 60 / 90+ days past due.

> Hollis paid INV-2026-0002.

Marks it paid.

> Mileage for September?

Trips, miles, and the deduction at the IRS rate.

Agency: "What do I owe Luis?" lists his unpaid attempts or serves and the total; "paid Luis" marks them.

## What next

- `README.md` for the full explanation, the affidavit / rules / photo-stamp / privacy boundaries, troubleshooting table, and developer notes
- `example-workflow.md` to see the exact tool calls behind each step above
