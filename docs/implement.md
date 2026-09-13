# Time zones: implementation blueprint

> **Status:** Phases 0–3 complete. Every zone-dependent calculation goes through `TimeZones`, and the zone model exists (unset preferences keep Los Angeles for work and Dhaka for local until Phase 5's UI). Every record is shown, edited, exported and searched in the zone it was filed in. Phase 4 (the zone picker) is next.
> **Baseline commit:** `9181afa` (all line numbers below refer to it and WILL drift — re-grep before editing).
> **Rule:** one phase at a time. A phase starts only when the previous phase's exit criteria are green and committed.

| Phase | Title                                                | Touches data?    | Needs live account? | Size              | State       |
| ----- | ---------------------------------------------------- | ---------------- | ------------------- | ----------------- | ----------- |
| 0     | Groundwork, probes, fixtures                         | no               | one read-only probe | S                 | **done**    |
| 1     | `TimeZones` core + behaviour-identical refactor      | no               | regression only     | L (split 1a/1b)   | **done**    |
| 2     | Data model: work / local / session / record zones    | **yes**          | regression only     | L (split 2a/2b)   | **done**    |
| 3     | Rendering and editing records in their own zone      | yes (edit paths) | no                  | M–L (split 3a/3b) | **done**    |
| 4     | The zone picker component                            | no               | no                  | M–L               | not started |
| 5     | Status bar, settings card, phone sheet, change flows | prefs            | no                  | L (split 5a/5b)   | not started |
| 6     | Sync hardening + multi-device + iPhone verification  | no               | **yes**             | M                 | not started |
| 7     | Cleanup, aliases removed, docs, guide                | no               | full sweep          | S                 | not started |

---

## 0. How to execute a phase (read this every session)

1. Read §2 (vocabulary), §3.2 (invariants) and the phase's own section. Nothing else is required context.
2. **Re-grep every call site the phase names.** Line numbers here are from `9181afa`.
3. Run the phase's regression list against the **unmodified** tree first and write the numbers down. A mutation graded against an already-red suite grades nothing.
4. Separate concerns **before** editing (git reset is blocked here; commits cannot be split afterwards).
5. Implement. `npx --no-install prettier --write index.html`, then `node nodrift-harness/mutation-anchors.js`.
6. Run the phase's new tests, then the regression list, **one suite at a time** (they share ports and the test account).
7. Run the phase's mutations with a baseline. Every new mutation must be caught by a check that was newly red.
8. Commit. Update the status table above. Do not push unless asked.
9. **Stop condition:** if an exit criterion cannot be met, stop and report. Do not start the next phase to "come back to it".

---

## 1. Goal

Make nodrift correct for anyone, anywhere:

- **Work time zone** — the zone the company operates and reports in (for this team: `America/Los_Angeles`). It decides what "today" is, when a shift rolls over at midnight, which calendar day a shift is filed under, weekly/monthly periods, and the times written on records.
- **Local time zone** — where the user physically is (for this team: `Asia/Dhaka`). Display only: the second clock and the "Est. EOD" time. It never changes a stored value.
- A full searchable picker over every IANA zone (like iOS / macOS / Windows), on desktop, tablet and phone.
- Nothing already in the logbook moves, re-dates or re-times itself because a setting changed.

---

## 2. Vocabulary (use these words in code comments and commits)

| Term                    | Meaning                                                                                                                                       | Where it lives                                                       |
| ----------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------- |
| **Instant**             | An absolute moment, epoch ms. Zone-free. The truth.                                                                                           | `loginEpochMs`, `logoutEpochMs`, `startMs`, `endMs`, session anchors |
| **Business date**       | The `MM/DD/YY` string a record is filed under, decided in _some_ zone at filing time.                                                         | `log.date`, `task.date`, leave ids, `state.activeDate`               |
| **Calendar key**        | `Date.UTC(y, m-1, d, 12)` — a sortable number for a business date. Not an instant.                                                            | `log.epochMs`, weekly cache keys                                     |
| **Work zone (pref)**    | The user's chosen work zone. Syncs across devices.                                                                                            | new pref `workTz`                                                    |
| **Session zone**        | The work zone captured when the current shift began. Travels with the session.                                                                | new `state.sessionTz`                                                |
| **Effective work zone** | `sessionTz` while a session is live, otherwise the pref. **The only zone business logic may use.**                                            | `getWorkZone()`                                                      |
| **Local zone**          | `"auto"` (follow the device) or a fixed IANA id. Syncs as a value; `"auto"` resolves per device.                                              | new pref `localTz`                                                   |
| **Record zone**         | The zone a record was filed in.                                                                                                               | new `log.tz` / `task.tz`; absent ⇒ `LEGACY_TZ`                       |
| **`LEGACY_TZ`**         | `"America/Los_Angeles"` — the zone every record and session created before this feature was filed in. A constant forever, never a preference. | replaces `APP_TZ`                                                    |

---

## 3. Design

### 3.1 What exists today (audit at `9181afa`)

**One hardcoded business zone, one hardcoded local zone, one cosmetic dropdown.**

- `APP_TZ = "America/Los_Angeles"` (index.html:17354) with a comment stating it is a business rule and that `DOM.primaryTz` is cosmetic.
- Module-level formatters (17356–17426): `pstFormatter`, `loginFormatter` (identical to it), `pstDateFormatter`, `pstDateObjFormatter`, `exportNameDateFormatter`, `bstFormatter` and `bstEtaFormatter` (both `"Asia/Dhaka"` literals), `primaryFormatter` (cosmetic, from `#primary-tz`), plus two caches `getCachedTzFormatter(tz)` / `getCachedTimeOnlyFormatter(tz)`.
- `getPSTDate()` (23993) — "what day is it", `MM/DD/YY`, server-corrected, cached per second. **~32 call sites.**
- `getPSTDateObj()` (24011) — UTC-noon `Date` of the business day, cached per minute. **~25 call sites.**
- `checkMidnightReset()` (32647–32997) builds a formatter on every run and computes midnight with a **08:00-UTC guess minus an hour offset** (32802–32813). **Measured in Phase 0** (`probe-tz-intl.js`, the block transcribed verbatim): exact in Los Angeles (both 2026 DST days), Dhaka, Kiritimati and UTC — so today's usage is safe. Wrong nearly everywhere else: +30 min in Kolkata and St John's, +45 in Kathmandu, ±60 on both London DST days, −60 on Santiago's midnight-gap day, 30–90 min on Lord Howe and St John's DST days, and **a whole day early in every zone west of UTC−8 in standard time** (Honolulu, Anchorage in winter, Pago Pago, Etc/GMT+12). Must be replaced before any other zone is allowed.
- `getEpochFromDateTimeString(date, time)` (38999) — wall time → instant, hardwired to `APP_TZ`, 5-step convergence with an "accept ±1h" hack for DST gaps. No ambiguity policy for the repeated hour. **Measured:** a time inside the spring-forward gap resolves one hour _back_ (`03/08/26 02:30 AM` → `09:30Z` = 01:30 PST); a time inside the repeated hour resolves to the _earlier_ occurrence (`11/01/26 01:30 AM` → `08:30Z`, PDT); results are identical under any device zone.
- `#primary-tz` hidden `<select>` + `.tz-presets` pills (12146–12198): PST/MST/CST/EST, cosmetic only. Persisted as `production_tz_pref` (`TZ_KEY`, 16130), synced as pref `tzPref` (18515).
- Second clock hard-labelled `BST` (12206) and `Est. EOD: … BST` (25361). Help guide says the same (9937, 10566–10569). **The first label says "PST" even in summer, while the time shown is correctly PDT.**
- Phone: `.tz-presets` is relocated into the sheet's "Time Zone" slot (`RELOCATIONS`, 41155); the bar only reads the zone (`.status-bar .tz-container { display: contents }`, 7218).

**Records store display strings baked in PST alongside instants.**

- Log (25621 / 25926): `date`, `displayDate`, `epochMs`, **`login` / `logout` as formatted PST strings**, `loginEpochMs`, `logoutEpochMs`, `workSec`, `breakSec`, `dayGoal`, `notes`, `lastModified`, `searchStr`.
- The logbook row renders the **stored strings** (`dom.meta.textContent = \`${log.login} - ${log.logout}\``, 28314) and its row key includes them (28265).
- Task (30850 / 36604): `date`, `startMs`, `endMs`, `durationSec`, `pausedSec`, `note`. Task rows **re-format instants at render** with `loginFormatter` (36828) — so logs and tasks already disagree about where display comes from.
- Day summaries, insights first-in / last-out parse the stored strings back to minutes with `parseTimeToMinutes` (26517, 28578, 29309–29341, 30437). Across zones that comparison is meaningless.
- CSV (`csvRowForLog`, 31179) exports the stored strings. Search strings embed them (20008, 25643, 27561, 31081, 31602, 31911, 40509).
- Manual `"Manual"` / `"Entry"` / `"—"` / `"--"` placeholders exist in `login`/`logout` with derived instants.

**Things that are already zone-safe and must stay that way.**

- The analytics worker (≈23700–23840) groups by business-date strings only.
- Week/month math (`getMonthlyWeeks`, weekday via `getUTCDay` on calendar keys) is calendar arithmetic.
- Durations are anchored on instants; the SYSTEM CLOCK POLICY (17428) is untouched by this work.
- **Server:** `records.payload`, `session_state.payload`, `session_state.settings` are opaque `jsonb`; the SQL functions only build return objects. **No migration is expected** — Phase 0 proves it.

### 3.2 Invariants (every phase must preserve all of them)

- **I1 — Instants are truth, zones are interpretation.** No stored instant is ever converted, rebased or re-derived because a zone changed.
- **I2 — A business date is decided once.** It is computed at filing time in the record's zone and never recomputed afterwards, by anything.
- **I3 — A record without `tz` is `LEGACY_TZ`, forever.** Never "the current preference". No backfill writes `tz` onto old records (that would restamp and re-upload the whole logbook and churn LWW).
- **I4 — A live session's day boundaries belong to `sessionTz`.** Changing, syncing or adopting a work-zone pref never moves a running shift's midnight.
- **I5 — One resolver.** Business logic asks `getWorkZone()`, display asks `getLocalZone()` / `getDisplayZone(record)`. Nothing else reads the pref keys, `LEGACY_TZ`, or `Intl…resolvedOptions()` directly.
- **I6 — Every zone string crossing a trust boundary is validated before any `Intl` call.** Storage, sync blob, session payload, record payload, import file. An invalid zone must never throw inside the tick (a `RangeError` there kills the timer). **"The formatter didn't throw" is not validation** — measured on Chrome 152, it accepts `PST` (→ Los Angeles), `BST` (→ **Asia/Dhaka**), `EST` (→ America/Panama), `PST8PDT`, `EST5EDT`, offset zones like `+06:00`, and lower-case ids. Valid means: the id canonicalises (engine-local) to a member of `Intl.supportedValuesOf("timeZone")`, or to `UTC`; the embedded list stands in where that API is missing. It rejects `""` and ids with surrounding spaces.
- **I7 — Zone ids are compared only after engine-local canonicalisation.** Measured on Chrome 152: its list and its canonical form use **legacy names** (`Asia/Kolkata`→`Asia/Calcutta`, `Europe/Kyiv`→`Europe/Kiev`, `Asia/Kathmandu`→`Asia/Katmandu`, `Asia/Ho_Chi_Minh`→`Asia/Saigon`, `Asia/Yangon`→`Asia/Rangoon`); Safari is expected to use the modern ones (measured in Phase 6). City names shown to the user come from the alias table in modern spelling, never from the engine's id.
- **I8 — Formatters are created only through the `TimeZones` cache.** No `new Intl.DateTimeFormat` with a `timeZone` anywhere else.
- **I9 — Zone arithmetic uses zoned functions.** "Next day" / "start of day" / "+1 day for a logout before login" are never `± 86400000` on an _instant_ (DST days are 23 h or 25 h). Calendar keys may keep ±86400000.
- **I10 — The local zone never influences a stored field.** Not `date`, not `tz`, not `activeDate`, not a search string.
- **I11 — Nothing the app derives as a default is uploaded.** Only explicit user choices and the clock-in pin (§3.3) are stamped as settings edits. (Phase 8 lesson: defaults written during boot must precede the prefs baseline.)
- **I12 — One invalidation funnel.** Any change to the effective work zone, local zone or display mode goes through `onZoneContextChanged()`, which bumps `TimeZones.version`, drops every date/clock/row cache and redraws.
- **I13 — Visibility of anything under `.main-ui` is toggled by class, never inline `display`** (the phone routes panes by hiding `.main-ui`'s children).
- **I14 — Zone labels and nicknames reach the DOM only through `textContent`** (or `escapeHTML` at an `innerHTML` sink). They are user- and sync-supplied strings.

### 3.3 Resolution rules

```text
getWorkZone():
  if sessionHoldsZone(state):           // shift not yet submitted (see below)
      return sanitize(state.sessionTz) ?? LEGACY_TZ     // I3/I4: an upgrade mid-shift has no sessionTz → LEGACY
  pref = sanitize(localStorage[workTz])
  if pref: return pref
  return derivedDefaultWorkZone()       // NOT written to storage (I11)

derivedDefaultWorkZone():                // deterministic from data, so devices converge
  if any log/task record lacks tz, or state.activeDate predates the feature → LEGACY_TZ
  else if any record has tz            → tz of the most recently modified record
  else                                  → deviceZone()

getLocalZone():
  v = sanitize(localStorage[localTz]) or "auto"
  return v === "auto" ? deviceZone() : v

getDisplayZone(record):                  // for In/Out times only
  mode = tzDisplay.logTimes              // "recorded" (default) | "work" | "local"
  recorded → recordZone(record) = sanitize(record.tz) ?? LEGACY_TZ
  work     → getWorkZone()
  local    → getLocalZone()
```

- **`sessionHoldsZone(state)`** = `currentMode !== null || idleLock || loginTimestamp || workAccumulated > 0 || breakAccumulated > 0`. This is the same predicate `SessionLease` uses as `hasLiveSession()` (20773, module-private today). **Extract it to top level and have `SessionLease` call the shared one** — two copies of "is a session live" would drift.
- **Clock-in pin.** When `switchMode` mints a new session (every `mintSessionId` call site; known: 24534, 26103), set `state.sessionTz = getWorkZone()` _and_, if the `workTz` pref is absent, write it and stamp it as a settings edit. This is the one derived value that becomes explicit, because a real shift now depends on it.
- **Retirement.** Everywhere `sessionIdWire` is retired (26116, 32933, `resetSession` 26168, and any others the grep finds), retire `sessionTz` in the same statement.
- **Order at session end:** clear the session (so `sessionHoldsZone` is false) **before** computing the next `activeDate`, or the new day is computed in the old zone.

### 3.4 How existing and future logs look (the history question)

| Question                                          | Answer                                                                                                                                                                                                                              |
| ------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Does a log's **date** change when I change zones? | **Never** (I2). A shift filed on 09/12 stays on 09/12.                                                                                                                                                                              |
| Do its **durations** change?                      | Never.                                                                                                                                                                                                                              |
| What **times** does a row show?                   | Default **"Recorded zone"**: the times as they were on the clock where it was filed, plus a small zone tag (e.g. `PDT`) **only when** the record zone differs from the current work zone.                                           |
| Why not convert everything to the new zone?       | Converted times can fall on a different day than the row's date (a Dhaka 02:00 logout is 13:00 _the previous day_ in LA), so the row would contradict itself.                                                                       |
| Can I see everything in one zone anyway?          | Yes: _Settings → Time zones → Show log times in_ **Work zone** or **Local zone**. Converted times that land on another day get a `+1d` / `−1d` marker.                                                                              |
| Legacy logs (before this feature)?                | Treated as Pacific (`LEGACY_TZ`) — which is exactly what they are. They look identical to today.                                                                                                                                    |
| After switching work zone, "today" and totals?    | "Today", daily goal and new records follow the new zone. Two zones' records can share a date label; the day's total is the sum of rows filed under that label. Overlap warnings use instants, so a genuine overlap is still caught. |

Stored `login` / `logout` strings are **kept and still written** (in the record's zone) for older clients, CSV compatibility and search. They become a cache; the renderer prefers instants + zone and falls back to the strings when instants are missing or the string is a placeholder (`Manual`, `Entry`, `—`, `--`).

### 3.5 Changing zones

| Change                                                       | No shift running                                                                                                                      | Shift running / paused / idle-locked / clocked out but not submitted                                                                                                                                                                                                                                                                                                                                                             |
| ------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Work zone**                                                | Confirm dialog (§4.4) → applies immediately; `activeDate` realigns synchronously through `onZoneContextChanged()`; goal re-populates. | **Deferred.** The pref is saved (and syncs) at once; `getWorkZone()` keeps returning `sessionTz`; a banner says _"Work time zone changes to Dhaka (UTC+6) when this shift ends · Undo"_. It takes effect the moment `sessionHoldsZone` turns false (EOD submit, a rollover that empties the session, reset). "Pending" is not stored anywhere — it is simply `pref ≠ sessionTz` while live. Undo = set pref back to `sessionTz`. |
| **Local zone**                                               | Immediate. Clocks and ETA only.                                                                                                       | Immediate. Clocks and ETA only.                                                                                                                                                                                                                                                                                                                                                                                                  |
| **Device moves zone** (travel, OS setting) with local = Auto | Detected on `visibilitychange` / `focus` / `pageshow` and once a minute in the tick; clocks update silently.                          | Same. No data effect (I10).                                                                                                                                                                                                                                                                                                                                                                                                      |
| **Work zone changed on another device** (sync)               | Adopted like any pref; confirm is not shown (the user already confirmed there); a toast names the new zone.                           | Adopted into the pref, deferred exactly as above, same banner.                                                                                                                                                                                                                                                                                                                                                                   |

**Race to close explicitly:** the user changes zone and clocks in within the same second. `onZoneContextChanged()` must run the `activeDate` realignment synchronously, and `switchMode` at clock-in re-derives `activeDate` from the new `sessionTz` when nothing is accumulated.

### 3.6 Day boundaries, rollover and DST

`checkMidnightReset` keeps its structure; only its zone math changes:

- "Now" date: `getWorkDate()` (was `getPSTDate`), zone = `getWorkZone()`.
- Midnight: `TimeZones.startOfDay(y, m, d+1, zone)` replaces the 08:00-guess block — correct for every offset including :30/:45, +14 and −12, and for zones whose DST transition happens **at** midnight (the day then starts at 01:00 local; the function returns the first instant whose local date is the new day).
- "Next business date": `TimeZones.addDays(dateKey, 1)` — pure calendar arithmetic on the `MM/DD/YY` key; no formatter needed.
- `idleTriggerDateStr` and the `resolveIdle` discard check use `TimeZones.dateKey(ms, getWorkZone())`.
- Mirrors still do not roll over (`sessionMirrored` gate unchanged).

**DST facts the tests must pin** (computed and frozen in Phase 0): a night shift across spring-forward is a 7-hour wall window for 8 clock hours; across fall-back the repeated hour exists twice; durations are unaffected in both because they come from instants.

### 3.7 Typed wall times → instants (manual entry, edit log, edit task)

`TimeZones.wallToInstant(y, m, d, h, mi, s, zone)` returns `{ ms, status }`:

- **Algorithm (deterministic, 4 `formatToParts` calls, no loops that can fail to converge):** `w = Date.UTC(wall)`; candidates `c1 = w − off(w − 36h)`, `c2 = w − off(w + 36h)`; keep candidates whose zoned parts equal the wall parts. For a gap, return both: `ms = c2` (the wall time read with the post-transition offset — **this is exactly what today's code returns**, 02:30 → 09:30Z) and `alt = c1`, so Phase 1 can stay behaviour-identical and Phase 3 can refuse.
  - one distinct candidate → `ok`
  - two → `ambiguous` (repeated hour): choose the **earlier**, _unless_ the other endpoint of the same form makes only the later one valid (logout must be ≥ login) — then choose the later.
  - none → `gap` (the time does not exist): **refuse the save** with _"2:30 AM doesn't exist on 03/08/26 in Pacific Time — clocks jumped forward."_ (Decision D6.)
- **Which zone:** manual entry and new tasks → `getWorkZone()`; editing an existing record → **the record's zone**, labelled beside the fields (_"Times in PDT · Los Angeles"_). A record's zone is not editable in v1.
- **"Logout before login ⇒ next day"** becomes `wallToInstant` on `addDays(date, 1)`, never `+ 86400000` (I9).
- **Round-trip guarantee:** opening an edit dialog and saving without changes must leave `loginEpochMs` / `logoutEpochMs` byte-identical — including a record whose login is inside the repeated hour. This is a Phase 3 test.

### 3.8 Cloud sync

| Surface                                        | Change                                                                                                                                                                                                     | Why it is safe                                                                                                                                                                                                                                 |
| ---------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Settings blob (`PREF_KEYS`, 18511)             | + `workTz` (`nodrift_work_tz_v1`, string), + `localTz` (`nodrift_local_tz_v1`, `"auto"` or IANA), + `tzDisplay` (`nodrift_tz_display_v1`, JSON `{ logTimes, labelStyle, nicknames: { [zoneId]: "BST" } }`) | LWW like every pref; `applyPrefs` already never deletes on absence. Add a per-pref **validator** so an invalid value is skipped, never applied (I6).                                                                                           |
| `tzPref` (old cosmetic key)                    | Dropped from `PREF_KEYS` in Phase 5; storage key left alone.                                                                                                                                               | Old clients skip absent prefs (18567), so omitting it erases nothing anywhere.                                                                                                                                                                 |
| Session payload (`SESSION_FIELDS`, 18391)      | + `sessionTz`                                                                                                                                                                                              | A string token, **not** in `SYNC_INSTANT_KEYS`. Not added to `sessionFingerprint()` (22223), so it costs **zero** extra realtime messages. `payloadIsLive` unchanged.                                                                          |
| Adoption (`adoptSession`, 21129)               | Adopts `sessionTz` with the rest. If it differs from this device's pref, show the deferred banner.                                                                                                         | A follower's midnight now agrees with the owner's even if their prefs disagree (I4).                                                                                                                                                           |
| Records                                        | + `tz` on new logs and tasks                                                                                                                                                                               | `jsonb` payload; LWW and `lastModifiedOf` untouched. `mergeRows` does no field validation, so `tz` is sanitised **at read** (`recordZone`), never trusted.                                                                                     |
| Fresh device signing in to an existing account | Resolves through `derivedDefaultWorkZone()`; pulled legacy records ⇒ `LEGACY_TZ`; the blob's `workTz` (if any) wins on adoption.                                                                           | Nothing derived is pushed (I11), so a new laptop cannot overwrite the account's zone with its own.                                                                                                                                             |
| Older cached client (pre-feature)              | Ignores `tz`/`sessionTz`. If it edits a record, instants it writes are still correct (it interprets typed times in LA, which is where it thinks it is) and display derives from instants + `tz`.           | The service worker is network-first for the document, so old clients update on next launch. Residual risk: an old client mirroring a non-LA session rolls nothing (mirrors don't roll over) but would _render_ LA dates. Accepted; documented. |
| Realtime / egress                              | +~30 bytes per record, +~25 per session payload                                                                                                                                                            | Phase 6 re-measures with `probe-beat-cost.js`: must stay 1.00 message per owner beat, ceiling unchanged.                                                                                                                                       |

**Backup / import / reset.** `buildBackupPayload` (31260) gains `workTz`, `localTz`, `tzDisplay`; import applies them only when valid; `purgeFactoryKeys` (32291) gains the three keys and the device-local `nodrift_tz_recent_v1`. Legacy backups import as `LEGACY_TZ` records.

### 3.9 Exports, email, other displays

| Output                                                                  | Zone                                                                                             | Change from today                                                     |
| ----------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------- |
| Status bar clock 1                                                      | Effective work zone                                                                              | label becomes dynamic                                                 |
| Status bar clock 2                                                      | Local zone (hidden when it equals work zone)                                                     | label becomes dynamic                                                 |
| "Est. EOD"                                                              | Local zone                                                                                       | label becomes dynamic                                                 |
| Logbook In/Out, task start/end, day summary, insights first-in/last-out | `getDisplayZone(record)`                                                                         | from instants, not strings; first-in/last-out compared by **instant** |
| Idle dialog "Last active" / "Current time"                              | **Local** (work zone as a secondary line when different) — Decision D7                           | today: PST                                                            |
| EOD email subject/body, Ctrl+S subject                                  | Business date                                                                                    | none                                                                  |
| CSV `In`/`Out`                                                          | Record zone                                                                                      | + trailing `Time_Zone` column — Decision D4                           |
| Export file names (`nodrift-logs-YYYY-MM-DD`)                           | Local date (when _you_ exported)                                                                 | today: PST date                                                       |
| Conflict wizard (import)                                                | Record zone, with tag                                                                            | escaping unchanged                                                    |
| Copy diagnostics                                                        | Adds a _Time_ block: device zone, work pref, session zone, effective, local, `TimeZones.version` | new                                                                   |

### 3.10 Security

- Zone ids from any source go through `TimeZones.sanitize(id, fallback)`: canonicalise with `new Intl.DateTimeFormat("en-US", { timeZone }).resolvedOptions().timeZone` inside `try`, then require membership of the supported list (I6), and cache the verdict per input string.
- Nicknames: max 6 characters, `[A-Za-z0-9+−:]`, rendered with `textContent`.
- Picker rows are built with DOM APIs or `escapeHTML`; the search query is never interpolated into markup.
- `harness-security.js` gains: a hostile `tz` on an imported record, a hostile `workTz` in a synced blob, a hostile nickname.
- No new hosts, no CSP change, no `vercel.json` change.

### 3.11 Performance budget

**Measured unit costs (Chrome 152, 1×, Phase 0):** creating a formatter 288 µs · `format` 4.8 µs · `formatToParts` 17 µs · `resolvedOptions()` 206 µs. **Building four labels for all 418 zones: 484 ms at 1×, 3 912 ms at 4× throttle** — ten times the budget the first draft of this plan set, which is why the picker below computes labels only for visible rows.

| Path                 | Budget                                                                             | How                                                                                                                                                                                                                      |
| -------------------- | ---------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Tick (1 Hz)          | **zero** new formatter allocations; ≤ 1 `formatToParts` per second                 | `getWorkDate()` cached per `(zone, second)`; clocks cached per `(zone, minute)` exactly as now (all modern offsets are whole minutes, so minute boundaries align). A formatter created per tick would cost 288 µs a time |
| Device-zone watch    | 1 `resolvedOptions()` per minute + on resume                                       | 206 µs a minute; compare string; emit only on change                                                                                                                                                                     |
| Logbook scroll       | format only visible rows                                                           | memo `Map` keyed on id, lastModified, zone and version; row key gains `version`                                                                                                                                          |
| Boot                 | < 5 ms added                                                                       | no zone metadata built at boot                                                                                                                                                                                           |
| Picker first paint   | < 100 ms at 4×                                                                     | static strings only (city, region, country, aliases) — no `Intl` label calls                                                                                                                                             |
| Picker labels        | < 60 ms per screenful at 4×; no long task over 50 ms                               | offset, abbreviation and local time computed for rendered rows only, at most two cached formatters per zone                                                                                                              |
| Offset / name search | results complete within ~1 s at 4×, without blocking typing                        | index of offsets, abbreviations and generic names built in idle slices of ≤ 8 ms after the picker opens, cached for the page's life, refreshed if older than an hour; a "searching all zones…" hint until it is done     |
| Formatter count      | bounded by `zones in use × styles` (≈ 20–40), plus whatever the picker has touched | single cache (I8)                                                                                                                                                                                                        |

---

## 4. UI / UX design

### 4.1 Status bar

**Desktop and tablet (≥ 768 px).** The existing clock cluster stays where it is; the pills popover goes away.

```text
 nodrift   PDT ▾ 10:23:45 AM  │  BST ▾ 11:23:45 PM                 [goal ▾] [theme]  Active
           └ work clock ┘        └ local clock ┘
```

- Order conveys role: work first, local second. Each label is a button (`.tz-clock-btn`) with a tooltip: _"Work time · Pacific Time (Los Angeles) · UTC−7"_. Clicking opens the picker for that role.
- No "WORK"/"LOCAL" words in the bar: the status bar's min-content width already constrains the right pane (measured 1.51 : 1 at 1440 px). Phase 5 measures the ratio and must not regress it by more than 2%.
- **Single-zone mode** (work zone equals local zone after canonicalisation): one clock, no divider.
- **Tablet band (768–1149 px, media query at 8823):** same markup; if the probe measures overflow, the chevrons hide first, then seconds on the local clock. Decided by measurement, not in advance.

**Phone (≤ 767 px).** Same three-column bar as today; labels become dynamic and are capped.

```text
 nodrift   PDT 10:23:45 AM · BST 11:23:45 PM   Active
```

- Labels ≤ 5 characters on the phone: an offset label compacts to `+5:30`; a nickname is already ≤ 6 and truncates with an ellipsis at 5 if needed. The probe tests the longest realistic pair at 375 px.
- The bar only reads; changing zones happens in the sheet's **Time Zone** section.

### 4.2 The zone picker (`ZonePicker`)

One component, three presentations: centred dialog on desktop/tablet, full-screen sheet on phone (the help modal's existing < 768 px treatment). It is a **`.modal-overlay`**, so the takeover prompt's `otherDialogUp()` gate and the footer popup's outside-click rule already respect it.

```text
┌ Work time zone ───────────────────────────────── ✕ ┐
│ ⌕  Search city, country, zone or UTC offset         │
├─────────────────────────────────────────────────────┤
│ SUGGESTED                                            │
│ ✓ Los Angeles · United States        PDT · UTC−7    │
│   Dhaka · Bangladesh  (this device)  UTC+6          │
│ RECENT                                               │
│   New York · United States           EDT · UTC−4    │
│ ALL TIME ZONES                                       │
│   UTC−11   Pago Pago · American Samoa    6:23 AM    │
│   UTC−10   Honolulu · United States      7:23 AM    │
│   …                                                  │
├─────────────────────────────────────────────────────┤
│ Label  [PDT   ]  Style [Abbreviation ▾]      Done   │
└─────────────────────────────────────────────────────┘
```

- **Source list:** `Intl.supportedValuesOf("timeZone")` (418 ids on Chrome 152, legacy spellings, **no `UTC` entry** — the picker adds UTC itself); embedded fallback list for engines without it. `Etc/GMT±N` hidden from the list (their sign is inverted and nobody picks them) but accepted if already stored — Decision D8. Chrome lists none today.
- **Row:** city (from the alias table in modern spelling, else the last id segment with `_` → space), country (embedded compact zone→ISO-country map ≈ 8 KB, named via `Intl.DisplayNames`), and — **for rendered rows only** — current offset, abbreviation when one exists, and current time. **Sorted alphabetically by city (iOS-style), not by offset:** ordering by offset needs an `Intl` call for every zone before the list can draw, which Phase 0 measured at seconds on a throttled CPU.
- **Local picker** adds a first row: _"Automatic — use this device's time zone (Dhaka)"_.
- **Search** (diacritic-insensitive, prefix-ranked), in two tiers. **Immediate** (static strings, no `Intl`): city, region segment, country name, aliases (`Calcutta↔Kolkata`, `Kiev↔Kyiv`, `Katmandu↔Kathmandu`, `Saigon↔Ho Chi Minh`, `Rangoon↔Yangon`, `US/Pacific`…). **As the idle index completes:** generic names (`longGeneric` → "Pacific Time", "Bangladesh Standard Time"), abbreviations (`short` → "PDT"; `shortGeneric` → "PT"), offsets (`utc+6`, `gmt+6`, `+6`, `+06:00`, `+5:30`). "bangladesh" → Dhaka at once; "pst" → Los Angeles and "5:30" → Kolkata once indexed.
- **Keyboard / a11y:** `role="listbox"`, `aria-activedescendant`, ↑ ↓ Home End Enter Esc, type-ahead focuses search. Autofocus search on desktop only (house rule: no autofocus that raises the phone keyboard).
- **Touch:** rows ≥ 44 px on the touch layouts; the list is the only scroller (no nested scroller fighting the sheet drag).
- **Label footer:** nickname per zone (stored in `tzDisplay.nicknames[zoneId]`, so a nickname never follows you to another zone) and style (Abbreviation / Generic / Offset).
- **Recents:** last 5 chosen, device-local, not synced.

### 4.3 Settings card and phone sheet

A new card in the settings popup, placed first (zones decide what "today" means for every card below it):

```text
TIME ZONES
Work time zone              PDT · Los Angeles   ›
Local time zone             Auto · Dhaka        ›
Show log times in           [Recorded zone ▾]
```

- One node, two layouts: `MobileShell.RELOCATIONS` replaces `{ slot: "tz", selector: ".tz-presets" }` with this card, exactly as the weekly goal is borrowed into the Goals slot.
- Hover-help entries for each row in `initSettingsHoverHelp`.
- Row controls respect the three size scales (26 px inside `.settings-row` on desktop, 44 px on touch); exclude by class, never override `!important` rules.

### 4.4 Flows and copy

**Change work zone, no shift running** (uses the shared confirm modal; tests assert `DOM.confirmTitle` before clicking):

> **Change work time zone?**
> From **Pacific Time (Los Angeles)** to **Bangladesh (Dhaka)**.
> Today becomes **Sat 09/13/26** (was Fri 09/12/26).
> Your existing logs keep their dates and times. New shifts, today's goal and your weekly totals follow the new zone.
> [Cancel] [Change]

**Change work zone, shift live:** no dialog; the deferred banner appears under the progress area (class-toggled, I13):

> Work time zone changes to **Dhaka (UTC+6)** when this shift ends · **Undo**

**First launch after upgrade (existing installs only, dismissible, local latch):**

> **Time zones are here.** Work: Pacific Time (Los Angeles), as before. Local: Dhaka, from this device. [Review] [OK]

### 4.5 Label policy

1. Nickname for that zone, if set.
2. Style **Abbreviation:** `Intl` en-US `short` if it is 2–5 letters (`PDT`, `EST`, `HST`, `GMT`, `UTC`); otherwise the offset.
3. Style **Generic:** `shortGeneric` if letters (`PT`); otherwise the offset.
4. Style **Offset:** `UTC−7`, `UTC+5:30` (phone: `−7`, `+5:30`).

Labels are DST-correct: Los Angeles shows **PDT** in summer and **PST** in winter (today's app shows "PST" all year). **Decision D3** covers keeping "BST" on this team's screens.

**Measured (en-US, Chrome 152):** only **111 of 418** zones get a letters-only `short` label, and most of those are the Americas or plain `GMT`. Dhaka is `GMT+6`, Kolkata `GMT+5:30`, London in summer `GMT+1` (never "BST" in en-US). `shortGeneric` is letters only for US/Canada zones (`PT`); elsewhere it is long ("Bangladesh Time", "United Kingdom Time"), so the Generic style falls back to the offset for most of the world. The offset text is rendered by the app from offset minutes (`UTC+6`), never copied from Intl's `GMT+6`, so every label style reads consistently.

### 4.6 Guide and help text

Rewrite the three passages (9871, 9937, 10566–10569) in Phase 5: two clocks, what each zone decides, what changing one does to existing logs, deferred changes during a shift, where to find the picker on each layout.

---

## 5. Edge-case catalogue

Each row becomes at least one assertion in the phase named.

| #   | Scenario                                                                                                           | Expected                                                                                     | Phase |
| --- | ------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------- | ----- |
| 1   | Existing user upgrades, no shift                                                                                   | Work LA, local Auto(Dhaka); clocks show PDT/BST (with D3); logbook identical                 | 2, 5  |
| 2   | **Upgrade mid-shift** (iOS relaunches into the new build)                                                          | `sessionTz` absent ⇒ `LEGACY_TZ`; timer, rollover, filing all unchanged                      | 2     |
| 3   | Work zone changed, no shift, same date in both zones                                                               | `activeDate` unchanged; clocks update                                                        | 2, 5  |
| 4   | Work zone changed, no shift, new zone is +1 or −1 day                                                              | `activeDate` realigns both directions; old records keep dates; goal re-populates             | 2     |
| 5   | Work zone changed during shift                                                                                     | Deferred; banner; switches at EOD; Undo restores                                             | 2, 5  |
| 6   | …while idle-locked / on break / clocked out unsubmitted                                                            | Same as 5                                                                                    | 2     |
| 7   | Clock-in in the same second as a zone change                                                                       | `activeDate` and `sessionTz` agree                                                           | 2     |
| 8   | Local zone changed / device travels                                                                                | Clocks and ETA only; no stored field differs (diff the storage)                              | 2, 5  |
| 9   | Work zone equals local zone                                                                                        | Single clock                                                                                 | 5     |
| 10  | Rollover, Dhaka (+6), shift 22:00→02:00                                                                            | Two records, dates D and D+1, split at Dhaka midnight, both `tz: Asia/Dhaka`                 | 2     |
| 11  | Rollover, Kolkata (+5:30) / Kathmandu (+5:45) / St John's (−3:30)                                                  | Split at the exact local midnight (today: 30 / 45 / 30 min late)                             | 1     |
| 12  | Rollover west of UTC−8 in standard time: Honolulu, Anchorage (winter), Pago Pago, Etc/GMT+12; and Kiritimati (+14) | Correct day (today: a whole day early in all four western zones; Kiritimati already correct) | 1     |
| 13  | Rollover on a DST day: Santiago 09/05/26 (next day starts 01:00), London 03/28 and 10/24, Lord Howe, St John's     | Split at the first instant of the new date (today: 30–90 min off)                            | 1     |
| 14  | Night shift across LA spring-forward                                                                               | Window 7 h; hours from instants; `assertShiftWindow` passes                                  | 1, 3  |
| 15  | Night shift across LA fall-back                                                                                    | Window 9 h; nothing double counted                                                           | 1, 3  |
| 16  | Manual entry with a time in the DST gap                                                                            | Refused with the specific message (D6)                                                       | 3     |
| 17  | Manual entry with a time in the repeated hour                                                                      | Earlier occurrence unless ordering forces the later                                          | 3     |
| 18  | Edit + save unchanged, record in repeated hour                                                                     | Instants byte-identical                                                                      | 3     |
| 19  | Edit a legacy (no `tz`) record                                                                                     | Interpreted in LA; saved with explicit `tz: LA`                                              | 3     |
| 20  | Edit a Dhaka record while work zone is LA                                                                          | Form shows Dhaka times, labelled                                                             | 3     |
| 21  | Two zones' records on one date label                                                                               | Day total sums both; genuine instant overlap still warns                                     | 3     |
| 22  | Display mode Work/Local converts a time across a day                                                               | `+1d` / `−1d` marker                                                                         | 3     |
| 23  | Manual placeholder times (`Manual`/`Entry`/`—`/`--`)                                                               | Shown as today                                                                               | 3     |
| 24  | Insights first-in/last-out with mixed zones                                                                        | Compared by instant                                                                          | 3     |
| 25  | CSV export                                                                                                         | In/Out in record zone; trailing `Time_Zone`; shape probe updated                             | 3     |
| 26  | Import legacy backup                                                                                               | Records read as LA; conflict wizard shows zone                                               | 3     |
| 27  | Import backup with invalid `workTz` / hostile `tz`                                                                 | Ignored / inert; no throw                                                                    | 2, 3  |
| 28  | Synced blob with invalid zone                                                                                      | Skipped, previous kept, anomaly logged                                                       | 2     |
| 29  | Other device changes work zone while this one runs a shift                                                         | Pref adopted, deferred, banner                                                               | 2, 6  |
| 30  | Handoff: B's pref differs from A's `sessionTz`                                                                     | B follows `sessionTz`; B's rollover (if it becomes owner) uses it; records it files carry it | 6     |
| 31  | Fresh device → legacy account                                                                                      | Resolves LA; pushes nothing about zones                                                      | 2, 6  |
| 32  | Fresh device → brand-new account                                                                                   | Device zone; pinned + pushed at first clock-in                                               | 2, 6  |
| 33  | Factory reset                                                                                                      | Zone keys and recents wiped; resolution back to rule 32                                      | 2     |
| 34  | Engine canonical-name mismatch between devices                                                                     | Treated as the same zone; single-clock mode still triggers                                   | 1, 6  |
| 35  | Engine without `supportedValuesOf` / `shortOffset`                                                                 | Fallback list; offset computed from parts                                                    | 4     |
| 36  | Server-offset correction (`Sync.trueNow`) near midnight                                                            | Date still from corrected time (existing test keeps passing)                                 | 1     |
| 37  | Year boundary in a + zone (12/31 → 01/01, two-digit year)                                                          | Correct `MM/DD/YY` and calendar keys                                                         | 1     |
| 38  | Longest label pair on a 375 px phone                                                                               | No wrap, no overflow, tail still visible                                                     | 5     |
| 39  | Picker raised while a takeover offer is pending                                                                    | Offer waits (`.modal-overlay` gate)                                                          | 4     |
| 40  | Suspend iPhone across midnight in work zone Dhaka                                                                  | Idle prompt and filing identical to today's LA behaviour                                     | 6     |

---

## 6. Test strategy

**Tools** (all existing, see the harness memory):

- `Emulation.setTimezoneOverride({ timezoneId })` — sets the **device** zone per page. Every zone test runs under at least two device zones to prove device-zone independence.
- `Page.addScriptToEvaluateOnNewDocument` `Date.now` shim — pins the **instant**. Never depend on the hour a test runs at; arm rollovers by backdating `state.activeDate`.
- `preload-supabase-stub.js` / the in-process fake server for sync semantics without the live account.

**Zone matrix** (Phase 0 pins the 2026 transition instants for each by bisection over the engine, then cross-checks the offset delta):

| Zone                                      | Why                                            |
| ----------------------------------------- | ---------------------------------------------- |
| `America/Los_Angeles`                     | legacy; DST Mar 8 / Nov 1 2026                 |
| `Asia/Dhaka`                              | this team's local; +6, no DST                  |
| `Europe/London`                           | the other "BST"; DST Mar 29 / Oct 25 2026      |
| `Asia/Kolkata`, `Asia/Kathmandu`          | +5:30, +5:45                                   |
| `America/St_Johns`                        | −3:30 with DST                                 |
| `Australia/Lord_Howe`                     | 30-minute DST                                  |
| `America/Santiago`                        | DST transition at local midnight               |
| `Pacific/Kiritimati`, `Pacific/Pago_Pago` | +14, −11                                       |
| `Pacific/Honolulu`, `America/Anchorage`   | west of UTC−8: today's rollover is a day early |
| `UTC`                                     | identity                                       |

**Device zones:** `Asia/Dhaka`, `America/Los_Angeles`, `Pacific/Kiritimati`, `Pacific/Pago_Pago`.

**New suites** (git-ignored `nodrift-harness/`). **Ports:** the time zone suites own HTTP 8871–8879 and CDP 9471–9479 (`probe-tz-intl.js` holds 8871/9471); everything else in the harness sits at or below 8864 / 9464.

| Suite                                                                                                                                                                     | Account            | Phase |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------ | ----- |
| `probe-tz-intl.js`                                                                                                                                                        | none               | 0     |
| `harness-tz-core.js`                                                                                                                                                      | none               | 1     |
| `harness-tz-model.js`                                                                                                                                                     | stub / fake server | 2     |
| `harness-tz-display.js`                                                                                                                                                   | none               | 3     |
| `probe-tz-picker.js`                                                                                                                                                      | none               | 4     |
| `probe-tz-ui.js`                                                                                                                                                          | none               | 5     |
| extensions to `harness-phase8.js`, `harness-handoff.js`, `harness-signin-render.js`, `harness-wipe.js`, `harness-security.js`, `probe-csv-shape.js`, `probe-beat-cost.js` | live / none        | 3, 6  |

**House rules that apply here in particular:** assert the precondition (seed, read back, carry the count); poll a window rather than sleep once; assert `getComputedStyle(...).display` for anything a media query can hide; open panels through their real trigger; pair every assertion with a negative control; never run two suites at once.

---

## 7. Phases

### Phase 0 — Groundwork, probes, fixtures

**Goal:** turn every assumption in this document into a measurement before code changes.

- `probe-tz-intl.js` (headless Chrome, no account): `supportedValuesOf` count and presence of `UTC`; canonical outputs for alias pairs; `short` / `shortGeneric` / `longGeneric` / `shortOffset` for the matrix; cost of one formatter, of `formatToParts`, and of building metadata for all zones at 1× and 4× CPU throttle.
- Transition fixture: compute and freeze the 2026 transition instants and offsets for the matrix (`nodrift-harness/fixtures/tz-transitions-2026.json`).
- **Server check:** a node probe (test account, full teardown) pushes a `records` row whose payload carries `tz`, and a `sync_session` payload carrying `sessionTz`, then reads both back byte-for-byte. Confirms "no migration".
- Read `0008_one_write_per_beat.sql` end-to-end to confirm no payload key is referenced.
- Record the green baseline of every suite in the Phase 1 regression list.
- **iPhone question for the user** (cannot be automated): after Phase 2 ships the diagnostics block, does an installed PWA see a changed OS time zone on resume, or only after relaunch? Noted for Phase 6.

**Exit:** probe output saved; fixture committed to the harness folder; server round trip proven; baseline numbers written into this section. **No `index.html` change.**

#### Phase 0 results (2026-09-13, Chrome 152, `index.html` at `9181afa`)

**`probe-tz-server.js` — 12 checks, all pass.** `tz` on a log and a task record, `sessionTz` in the session payload, and `workTz` / `localTz` / nested `tzDisplay` in the settings blob all round-trip byte-identical through `push_records` and `sync_session`; teardown was read back empty. **No migration is needed.** Note for Phase 2 tests: 0008's insert path does not write settings on a brand-new `session_state` row, so a test that seeds settings must beat twice.

**`probe-tz-intl.js` — all checks pass, 0 warnings.** Wrote `nodrift-harness/fixtures/tz-transitions-2026.json` (support, canonical names, labels, 2026 transitions, midnight-guess errors, `getEpochFromDateTimeString` results, costs). What it changed in this document:

| Finding                                                                                                                                          | Where it is now reflected                       |
| ------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------- |
| The midnight guess is exact in LA, Dhaka, Kiritimati and UTC, but wrong in most other zones, including **a whole day early west of UTC−8**       | §3.1, §5 rows 11–13, §6 matrix                  |
| A gap time currently resolves one hour **back**; a repeated-hour time resolves to the **earlier** occurrence                                     | §3.1, §3.7, Phase 1b, D6                        |
| Chrome's formatter accepts `PST`, `BST` (→ Dhaka), `EST` (→ Panama), `PST8PDT`, `+06:00` and lower-case ids, so "didn't throw" is not validation | I6, §3.10                                       |
| Chrome uses legacy canonical names (`Asia/Calcutta`, `Europe/Kiev`, `Asia/Katmandu`) and does not list `UTC`                                     | I7, §4.2                                        |
| Only 111 of 418 zones have a letters-only en-US abbreviation; `shortGeneric` is letters only for US/Canada                                       | §4.5                                            |
| Eager labels for every zone cost 484 ms at 1× and **3 912 ms at 4×**                                                                             | §3.11, §4.2, risk table                         |
| `Emulation.setTimezoneOverride` changes the device zone live, without a reload; the app's boot-time `_cachedResolvedTz` goes stale when it does  | §6; Phase 1 must not rely on that sampled value |

**Transition instants pinned (UTC):** Los Angeles 2026-03-08 10:00 and 2026-11-01 09:00 · London 03-29 01:00 and 10-25 01:00 · St John's 03-08 05:30 and 11-01 04:30 · Lord Howe 04-04 15:00 and 10-03 15:30 (30-minute steps) · Santiago 04-05 03:00 (local 23:59:59 → 23:00, repeated hour at the end of 04-04) and 09-06 04:00 (local 23:59:59 → 01:00, a day with no midnight) · Dhaka, Kolkata, Kathmandu, Kiritimati, Pago Pago, UTC: none.

**Regression baseline, unmodified tree, run one at a time — all green:**

| Suite                       | Result                   |
| --------------------------- | ------------------------ |
| `harness-progress.js`       | 25 pass                  |
| `harness-motion.js`         | 43 pass                  |
| `harness-cloud-panel.js`    | 27 pass                  |
| `harness-security.js`       | 15 pass                  |
| `probe-leave-rows.js`       | 12 pass                  |
| `probe-csv-shape.js`        | 14 pass                  |
| `probe-backup-and-leave.js` | 25 pass                  |
| `probe-lease-endshift.js`   | 30 pass                  |
| `probe-shift-rewind.js`     | ALL PASS (177 s)         |
| `harness.js`                | ALL PASS (80 PASS lines) |
| `harness-handoff.js`        | 22 checks, ALL PASS      |

**Still open for Phase 6:** whether an installed iPhone PWA sees a changed OS time zone on resume or only after a relaunch, and what Safari's canonical names and labels are. Neither can be measured from this machine.

### Phase 1 — `TimeZones` core + behaviour-identical refactor

**Goal:** every zone-dependent line goes through one module, while the only zones in play remain `LEGACY_TZ` and `"Asia/Dhaka"`. The app must behave **identically** to `9181afa`, except for the three midnight-math defects, which cannot occur in LA.

**1a — the module** (new section beside "DATE-TIME FORMATTING CONFIGURATORS", 17307):

```js
const LEGACY_TZ = "America/Los_Angeles";
const TimeZones = {
  isValid(id), sanitize(id, fallback), canonical(id), same(a, b),
  deviceZone(),                    // re-read on demand; cached
  version,                         // bumped by onZoneContextChanged()
  formatter(zone, style),          // the only formatter factory (I8)
  parts(ms, zone),                 // {y, m, d, h, mi, s}
  offsetMinutes(ms, zone),
  dateKey(ms, zone),               // "MM/DD/YY"
  dayNoonUtc(ms, zone),            // Date at UTC noon of the zoned day
  startOfDay(y, m, d, zone),       // first instant of that local date
  wallToInstant(y, m, d, h, mi, s, zone),   // {ms, status: ok|ambiguous|gap, alt}
  addDays(dateKey, n),             // calendar arithmetic
  formatTime(ms, zone, { seconds, ampm }),
  label(zone, ms, style, nickname),
};
function getWorkZone()  { return LEGACY_TZ; }     // widened in Phase 2
function getLocalZone() { return "Asia/Dhaka"; }  // widened in Phase 2
function getWorkDate()     /* was getPSTDate */
function getWorkDateObj()  /* was getPSTDateObj */
```

`harness-tz-core.js`: every function across the zone matrix × device zones, gap/ambiguity cases, rows 11–15, 34, 36, 37 of §5, and a property check: for 10 000 random instants per zone, `wallToInstant(parts(ms)) === ms` except inside a repeated hour, where it must be one of the two.

**1b — the call-site migration** (mechanical, one concern):

- Replace `pstFormatter`, `loginFormatter`, `pstDateFormatter`, `pstDateObjFormatter`, `exportNameDateFormatter`, `bstFormatter`, `bstEtaFormatter`, `rolloverFormatter`, `getCachedTimeOnlyFormatter(APP_TZ)`, `APP_TZ` literals (37210, 39025) with `TimeZones` calls against `getWorkZone()` / `getLocalZone()`.
- Replace the midnight guess (32802–32813) with `startOfDay`; the next-day objects (32763, 32830, 32890, 32963) with `addDays`.
- `getEpochFromDateTimeString` delegates to `wallToInstant` (keeps its signature). Behaviour stays exactly as Phase 0 measured it, and `harness-tz-core.js` pins it against `fixtures/tz-transitions-2026.json`'s `getEpochFromDateTimeString` block: a gap time returns `ms` (02:30 → 09:30Z, i.e. 01:30 PST), a repeated-hour time returns the earlier occurrence (01:30 → 08:30Z). The refusal lands in Phase 3.
- Rename `getPSTDate` → `getWorkDate`, `getPSTDateObj` → `getWorkDateObj`; keep `getPSTDate` / `getPSTDateObj` as **aliases** until Phase 7 (harness files and mutation anchors use them by name).
- Leave `#primary-tz`, pills, `BST` label and `TZ_KEY` untouched (Phase 5 owns the UI).

**Regression:** `harness.js` (includes `tests-phase5.js`'s corrected-date check), `harness-progress.js`, `harness-motion.js`, `harness-cloud-panel.js`, `harness-security.js`, `probe-leave-rows.js`, `probe-csv-shape.js`, `probe-backup-and-leave.js`, `probe-shift-rewind.js`, `probe-lease-endshift.js`, `harness-handoff.js` (its rollover section).

**Mutations:** `startOfDay` ignores offset minutes; `wallToInstant` prefers the later occurrence; `dateKey` formats in the device zone; the 08:00 guess restored; formatter cache keyed without the zone; `getWorkDate` reads the raw local clock (existing mutation re-anchored).

**Exit:** all of the above green; `grep "new Intl.DateTimeFormat"` shows no `timeZone` outside `TimeZones`; `grep "Asia/Dhaka\|APP_TZ"` shows only `LEGACY_TZ` and the temporary `getLocalZone` literal; anchors 0 misses.

**Commits:** `refactor(time): one module for every zone-dependent calculation` (1a) and `refactor(time): route every call site through TimeZones` (1b).

#### Phase 1 results (2026-09-13)

**Committed:** 1a as `7e5ccad`, 1b as `e641ae0`. `index.html` only; the harness is git-ignored.

**Where it lands, and how it differs from the sketch above:**

- `TimeZones`, `LEGACY_TZ`, `getWorkZone()` and `getLocalZone()` live in section **3b. TIME ZONES**, directly after `updatePrimaryFormatter`. The two resolvers arrived in 1a rather than 1b so the module's tests could name them.
- Validation is **shape plus membership**: an `Area/Location` id (or `UTC`), canonicalised by the engine, and then found in `supportedValuesOf`. `Etc/GMT±N` is let through for already-stored values (D8). The verdict cache is capped at 64 entries, because ids also arrive from sync and import.
- `wallToInstant` returns `{ ms, status, alt }`; a gap's `ms` is the post-transition reading, which is what the old loop returned, so `getEpochFromDateTimeString` is unchanged to the millisecond.
- The four "next business date" computations formatted **noon UTC in the zone**. That is correct from UTC−11 to UTC+11 and a day off beyond, so they became `TimeZones.keyFromYMD(y, m, d + 1)`, pure calendar arithmetic, rather than the `addDays` call the sketch named.
- `checkMidnightReset`'s one-minute date cache is keyed on the zone as well, like `getWorkDate`'s and `getWorkDateObj`'s.
- Removed as dead once nothing used them: `getPSTClock`, `_cachedResolvedTz`, `_sharedDateForPST`, `getCachedTzFormatter`, `getCachedTimeOnlyFormatter`.
- `getPSTDate` / `getPSTDateObj` remain as two one-line aliases for the harness (Phase 7 removes them).
- Untouched on purpose (Phase 5): `#primary-tz`, the PST/MST/CST/EST pills, the `BST` label, `TZ_KEY`.

**Tests — `nodrift-harness/harness-tz-core.js`, 80 checks, all pass:**

- 59 on the module, run under four device zones (Los Angeles, Dhaka, Kiritimati, Pago Pago) with identical results required, against the Phase 0 fixture: validation (and a negative control proving the raw formatter accepts the junk), offsets at every pinned transition, the true start of 38 days in 14 zones, calendar keys, byte-identity with every legacy formatter it replaced, gap / ambiguous / ok cases in three DST shapes, and a property check inverting 10 000 random instants plus a minute-by-minute sweep across every transition in 13 zones.
- 16 wiring checks under two device zones, moving the work zone by replacing `window.getWorkZone`: the date helpers follow a zone change in the same second, typed times are read in the work zone, and a real `checkMidnightReset` files a three-hour shift ending exactly at **Honolulu's** and **Kolkata's** midnight. Los Angeles cannot show any of this, because the old guess was exact there.
- 5 source checks that keep the exit criteria true in later phases: no zoned `Intl.DateTimeFormat` outside the module, no zone spelled out except `LEGACY_TZ` and `getLocalZone`, none of the old formatter names, and no call to the old date names beyond the two aliases.

**Mutations:** 11 new, all caught. Eight are on the module (hour-rounded offsets, the later occurrence, a gap's other reading, a device-zone date key, a zone-less formatter cache, sanitize trusting the formatter, an unchecked zone handed to Intl, `startOfDay` skipping the bisection). Three are on the wiring (the 08:00 guess restored, `getWorkDate` caching without the zone, typed times hardwired to Los Angeles). The existing "use this device's clock" mutation, renamed to `getWorkDate`, was re-graded and is still caught by `harness.js`. One wiring mutation first reported BAD with an empty failure list: the harness had failed to launch straight after the previous run. Applied by hand and re-run alone, it is caught. Two mutations are deliberately absent, and `mutation-test.js` says why beside the others: the noon-UTC next date (no wiring zone reaches UTC+12) and the minute cache's zone key (it would pass or fail by time of day). Anchors: 162, 0 misses.

**Regression, one suite at a time — identical to the Phase 0 baseline:** `harness-progress` 25, `harness-motion` 43, `harness-cloud-panel` 27, `harness-security` 15, `probe-leave-rows` 12, `probe-csv-shape` 14, `probe-backup-and-leave` 25, `probe-lease-endshift` 30, `probe-shift-rewind` ALL PASS, `harness.js` ALL PASS (80 PASS lines), `harness-handoff` 22 checks ALL PASS.

**Harness edits made alongside:** `tests-phase5.js` compares against `TimeZones.dateKey(Date.now(), getWorkZone())` instead of the deleted `pstDateFormatter`; one `mutation-test.js` anchor now names `getWorkDate`.

**Carried into Phase 2:** `TimeZones.version` / `bumpVersion()` exist but nothing bumps them yet (the `onZoneContextChanged()` funnel does). `getWorkZone()` and `getLocalZone()` still return constants, and those two function bodies are the only lines Phase 2 has to widen for every call site to follow.

### Phase 2 — Data model: work, local, session and record zones

**Goal:** the semantics in §3.3–§3.8 exist and are proven, with no new UI. Zones can be set from the console or a test; the existing user's app is unchanged.

- Pref keys, validators, `PREF_KEYS` entries, backup/import, `purgeFactoryKeys`, device-local recents key.
- `getWorkZone()` / `getLocalZone()` / `getDisplayZone()` / `derivedDefaultWorkZone()` as specified; `sessionHoldsZone` extracted and shared with `SessionLease`.
- `state.sessionTz`: `SESSION_FIELDS`, minted at every `mintSessionId` site, retired at every `sessionIdWire` retirement, legacy fallback.
- `tz` written on every new log (`createShiftLogEntry`, `executeSubmit`, manual save) and task (timer stop, manual task) — the zone is the one that decided the record's `date`.
- `onZoneContextChanged()` funnel: bump version; clear `_cachedPSTDateStr/Sec`, `_cachedPSTDateObj/Min`, `_cachedCurrentDatePST`, `cachedTodayDate`, `domWriteCache` clock/ETA entries, `window._cachedPrimaryBase/_cachedBstBase`; `invalidateDerivedCaches()`; synchronous `activeDate` realignment; `autoPopulateDailyGoal` when the date moved; redraw.
- Device-zone watcher (resume events + per-minute check in the tick).
- Deferred-change detection exposed as `TimeZones.pendingWorkZone()` (for Phase 5's banner).
- Diagnostics _Time_ block.
- Seed (D3) and first-launch latch (unstamped, before the prefs baseline).

**Tests — `harness-tz-model.js`:** rows 1–8, 10, 27–28, 31–33 of §5, each with a negative control. Includes a storage diff proving local-zone changes touch no stored field (I10), and a boot-order check proving no derived value is stamped (I11).

**Regression:** Phase 1 list + `harness-phase8.js` (preferences parity), `harness-import.js`, `harness-wipe.js`, `probe-beat-cost.js` (must stay 1.00).

**Mutations:** `sessionTz` not minted; not retired; `getWorkZone` ignores the session; legacy record read as the pref; validator removed; derived default written to storage; realignment deferred to the tick; `sessionTz` added to `SYNC_INSTANT_KEYS`.

**Exit:** all green; with no zone keys set, a full `harness.js` run and a manual boot render byte-identical screens to Phase 1.

**Commit:** `feat(time): work, local, session and record zones`.

#### Phase 2a results (2026-09-13)

**Split.** Phase 2 became **2a** (the zone model, committed as `feat(time): work, local, session and record zones`) and **2b**: the D3 "BST" nickname seed, the diagnostics _Time_ block, and the live-account suites (`harness-phase8.js`, `harness-import.js`, `harness-wipe.js`, `probe-beat-cost.js`).

**A deliberate change to this plan, for deploy safety.** Every commit on `main` can reach production (Vercel deploys `main`, and an accidental sync pushed Phases 0–1 live). Until Phase 5 gives users a picker, **an unset preference keeps today's zones**: work is `LEGACY_TZ` (Los Angeles), and local is the new `LEGACY_LOCAL_TZ` (Dhaka). So three things move to **Phase 5**, where the user can see what they choose:

- D5's device-zone default for brand-new users;
- the clock-in pin;
- `derivedDefaultWorkZone()`.

A default nobody can see would silently move a teammate's day.

**What exists now** (section 3b of `index.html`, beside `TimeZones`):

- **Preferences:** `nodrift_work_tz_v1`, `nodrift_local_tz_v1` (`"auto"` or a zone) and `nodrift_tz_display_v1`, all three in `PREF_KEYS` with a `validate` function. `applyPrefs` skips a value that fails it and calls the funnel when a zone preference changed. The backup payload carries them, import applies them through the setters, and `purgeFactoryKeys` erases them.
- **Resolvers:** `getPreferredWorkZone`, `getWorkZone` (the live session's `sessionTz`, else the preference), `getLocalZone`, `recordZone`, `getDisplayZone`, `pendingWorkZone`. Setters: `setWorkZonePref`, `setLocalZonePref`, `setZoneDisplayPref`. Plus `isZoneDisplayPref`, the `onZoneContextChanged` funnel, and `checkDeviceZone` / `maybeCheckDeviceZone` (called from the tick once a minute).
- **`sessionIsLive(s)`** is the session half of `SessionLease.hasLiveSession()`, which now calls it, so the two can never disagree about when a shift is live. Lease behaviour is unchanged.
- **`sessionTz`** is in `SESSION_FIELDS` and not in `SYNC_INSTANT_KEYS`. It is minted from the _preferred_ zone at both mint sites, because the session already reads as live when they run. It is retired at the resolve-idle discard, at the rollover that ends a shift, and in `resetSession`. `resetSession` computes the next `activeDate` in the preferred zone explicitly, since its literal is built while the finished shift's state is still current.
- **`tz`** is written by `createShiftLogEntry`, `executeSubmit`, manual shift save, manual task add and the task timer. Imported records keep whatever they carried.

**Tests.** `nodrift-harness/harness-tz-model.js`, 27 checks, no account, on a device emulating Kiritimati so the device zone can never pass for a default. It covers rows 1–8, 27, 28 and 33 of §5, the deferred change and its hand-over at submit, record stamping, backup and reset, the device-zone watcher, and a source check that the realtime fingerprint does not read `sessionTz`. The first run had four failures, and all four were the _test_ comparing `"Asia/Kolkata"` with `===` where the app correctly stores Chrome's `"Asia/Calcutta"` (I7). **Rule for every later test: compare zone ids with `TimeZones.same`, never `===`.**

**Mutations:** 6 new, all caught (the running shift's zone ignored, clock-in without `sessionTz`, a synced zone adopted unvalidated, a submitted shift without `tz`, realignment left to the tick, `sessionTz` treated as a wire instant). One is deliberately absent, with the reason in `mutation-test.js`: `resetSession` computing the day in the finished shift's zone, which only a tick landing inside `executeSubmit`'s awaits could expose. Anchors: 168, 0 misses.

**Regression, one suite at a time — green:** `harness-tz-core` 80, `harness-tz-model` 27, `harness-progress` 25, `harness-motion` 43, `harness-cloud-panel` 27, `harness-security` 15, `probe-leave-rows` 12, `probe-csv-shape` 14, `probe-backup-and-leave` **26**, `probe-lease-endshift` 30, `probe-shift-rewind` ALL PASS, `harness.js` ALL PASS, `harness-handoff` 22. `probe-backup-and-leave.js` failed once on "the payload still carries every field it used to", because it compared the key list exactly and 2a adds three keys by design. It now asserts that no field was lost, plus a new check that the three zone preferences are present.

#### Phase 2b results (2026-09-13)

**Committed:** 2a as `7b63e65`, 2b as `db7fe3b`.

- **Copy diagnostics** gains a `work` line (the zone in effect, the preferred zone, the running shift's zone, and any change waiting for the shift to end) and a `local` line (the zone in effect, the setting behind it, the device's zone and `TimeZones.version`). Keys stay at most nine characters so no existing line's padding moves. `harness-tz-model.js` checks both lines, and is now 28 checks.
- **The D3 "BST" nickname seed moved to Phase 5.** Nothing reads a nickname until Phase 5's labels, and Phase 5 is also where the local default becomes `"auto"`, which is the moment the seed matters. Writing it now would put a stored, and eventually synced, value in place that nothing uses.
- **Live account, one suite at a time — all at their baselines:** `harness-phase7` 21 (it reads the diagnostics text), `harness-phase8` 13 (preference parity across three devices), `harness-import` 9, `harness-wipe` 18 (the zone keys are erased with the rest), and `probe-beat-cost` 9.
- **`sessionTz` costs nothing in realtime messages:** idle 0.00 events per beat, owner 1.00, 120 owner messages an hour, ceiling about 94 concurrent owners. All unchanged.

**Carried into Phase 3:** `getDisplayZone()` and `recordZone()` exist and nothing renders with them yet. The display preference's `logTimes` defaults to `"recorded"` (D1).

**Carried into Phase 5:** the device-zone default for new users (D5) with its clock-in pin, the "BST" nickname seed (D3), the first-launch notice, and the local default of `"auto"`.

### Phase 3 — Rendering and editing records in their own zone

**Goal:** §3.4, §3.7 and §3.9's record rows are true.

- Logbook row times from instants in `getDisplayZone(log)`; zone tag rule; `±1d` markers; row key gains `TimeZones.version` and display mode; memo map.
- Task rows, day summary (26495+), insights first-in/last-out (29309–29341, 30437, 28578) by instant.
- Edit log / edit task / manual entry / manual task: interpret and label in the record's zone (new: work zone); `wallToInstant` gap refusal and ambiguity rule; next-day via `addDays`.
- Stored `login`/`logout` strings written in the record's zone; `searchStr` includes the zone label.
- CSV trailing `Time_Zone` (D4); conflict wizard zone tag; idle dialog (D7); export filenames in local date.
- Audit and decide the three device-local displays (`toLocaleDateString` 20577, 34885; `toLocaleTimeString` 35758).

**Tests — `harness-tz-display.js`:** rows 14–26 of §5; records in LA, Dhaka and Kolkata rendered under all three display modes and two device zones; unchanged-save round trip; placeholder rows. Extend `harness-security.js` and `probe-csv-shape.js`.

**Regression:** Phase 2 list + `probe-field-sweep.js`, `harness-signin-render.js`.

**Mutations:** row renders stored strings; edit interprets in work zone; first-in by string; row key without version; gap accepted silently; ambiguity picks later; CSV column dropped; nickname via `innerHTML`.

**Commit:** `feat(time): show and edit every record in the zone it was filed in`.

#### Phase 3a results (2026-09-13)

**Split.** Phase 3 became **3a**, the read paths (this block, committed as `feat(time): show every record in the zone it was filed in`), and **3b**, the edit paths and outputs. 3b covers:

- edit log, edit task, manual entry and manual task in the record's zone;
- the gap refusal (D6), the ambiguity rule, and next day via `addDays`;
- the CSV `Time_Zone` column (D4), the idle dialog (D7), export file names in local date, the conflict wizard tag, and the zone label in `searchStr`;
- the device-local display audit and the `harness-security.js` extensions.

**What exists now** (section 3b of `index.html`, after the resolvers):

- **`recordEndpoint(record, "in" | "out")`** returns the end's instant (log or task field), its stored string, and whether that string is a **placeholder** (non-empty, but not a clock time: `Manual`, `Entry`, `—`). A legacy log with a time and no instant gets one, read from the string in the record's zone, with a logout earlier than its login put on the next day.
- **`recordEndpointView(record, end)`** returns `{ text, tag }`:
  - A placeholder is shown as it is.
  - Shown in the record's own zone, a stored string that agrees with its instant (same minute of the day) is shown **verbatim**, so every existing record looks exactly as before, including times typed by hand like `9:00 am`. A string that disagrees loses to the instant (I1).
  - Shown in any other zone, the instant is formatted there, with a `+1d` / `−1d` marker when it lands on a different calendar day from the row's date.
  - The tag is `TimeZones.label` (DST-correct: `PST` / `PDT`, else the offset, e.g. `UTC+6`), present only when the zone shown differs from the work zone.
- **`formatTimeRange(a, b)`** writes one tag at the end when both ends share it, and one beside each end when they differ: a night across a DST change, or a day's first in and last out from two zones.
- **`firstInLastOut(records, { placeholders })`** orders a day's ends by **instant**. Placeholders never win; they stand in only where a view already did that (the weekly breakdown).
- **Also new:** `liveLoginView()` / `liveStatusView()` for the running shift, and `zoneRenderKey()` (version, display mode, work zone). The work zone is spelled out because a shift that ends hands over to a pending zone without passing through the funnel. `formatTime` results are memoised in a bounded map.

**Switched over:**

- the logbook row (text, and a row key that now includes `tz`, both instants and `zoneKey`);
- the task row (key and text);
- `buildProgressTooltipHTML`;
- the weekly insights breakdown (it collects records per date instead of minutes);
- `updateLiveTodayRow`'s cache, which also keys on `zoneKey`;
- the insights cache key.

`showHeatmapTooltip` computed a second first-in/last-out that nothing displayed; it's deleted.

**A defect the new suite found, fixed at the root.** The logbook and task scrollers return before comparing any row key when their visible range hasn't moved. So a display-mode or work-zone change bumped the version and still left the rows on screen showing old times. `onZoneContextChanged()` now also calls `renderLogbook`, `renderTaskLogbook` and `renderInsights`.

**A refinement of §3.4.** Day markers appear only on times shown in a zone other than the record's own. A legacy overnight manual entry (`10:00 PM - 02:00 AM`) therefore keeps its exact look in the default mode, as row 1 of §5 requires.

**Tests.** `nodrift-harness/harness-tz-display.js` (ports 8874/9474, no account) runs 32 checks under two device zones, Dhaka and Pago Pago, plus a page-exception check: 65 in total.

- **Fixed 2026 records.** The records are:
  - Los Angeles in summer and winter;
  - a hand-typed record, a stale string, and Dhaka;
  - Kolkata overnight;
  - placeholders, and a legacy record without instants;
  - nights across both LA DST changes: 7 h and 9 h, tagged `PST`→`PDT` and `PDT`→`PST`.

  Each is rendered in recorded, work and local modes, with the work zone set to both LA and Dhaka.

- **Ordering.** Mixed-zone first in / last out is ordered by instant, a shift past midnight counts as the last out, and there are placeholder rules.
- **Real renderers on today's date:** the day tooltip, a logbook row, the redraw after `setZoneDisplayPref`, a task row and its tag after `setWorkZonePref`, the week's today row, a hostile `tz`, a junk display preference, and the memo bound.

**Regression, one suite at a time — all at baseline.**

- **Time zone suites:** `harness-tz-core` 80, `harness-tz-model` 28.
- **No-account suites:**
  - `harness-progress` 25, `harness-motion` 43, `harness-cloud-panel` 27, `harness-security` 15;
  - `probe-leave-rows` 12, `probe-csv-shape` 14, `probe-backup-and-leave` 26, `probe-lease-endshift` 30;
  - `probe-field-sweep` unchanged (19 suspicious on desktop, 0 on phone);
  - `harness.js` ALL PASS.
- **Live account and the long suites:**
  - `harness-handoff` 22, `harness-signin-render` 12, `probe-shift-rewind` ALL PASS;
  - `harness-phase7` 21, `harness-phase8` 13, `harness-import` 9, `harness-wipe` 18;
  - `probe-beat-cost` 9: owner 120 messages an hour, idle 0, ceiling about 94.

**Mutations:** 10 new, all caught, and every one failed on the check written for it:

- the row shows the stored strings;
- the row key without `zoneKey`;
- the task row in the work zone;
- first in by clock reading;
- placeholders competing;
- a disagreeing string trusted;
- the display mode ignored;
- the day marker dropped;
- a tag on work-zone times;
- the funnel skipping the record redraw.

Anchors: 178, 0 misses. `index.html` was restored byte-identical.

**Carried into 3b:** everything under the split above. The plan's "gap accepted silently", "ambiguity picks later", "CSV column dropped" and "edit interprets in work zone" mutations belong there. "Nickname via `innerHTML`" waits for Phase 5's labels.

#### Phase 3b1 results (2026-09-14)

**Split again.** 3b became **3b1**, typed times in the dialogs (this block, committed as `feat(time): edit every record in the zone it was filed in`), and **3b2**, the outputs:

- the CSV `Time_Zone` column (D4);
- the zone label in `searchStr`;
- the idle dialog in local time (D7);
- export file names in local date;
- the conflict wizard tag;
- the device-local display audit;
- the `harness-security.js` extensions.

**What exists now:**

- **`typedTimeInZone(date, time, zone, dayOffset)`** reads a typed clock time on a date in a zone. It returns `wallToInstant`'s result plus the date key it read. The day offset goes on the wall date, never on the instant, so "the next day" is right on a 23- or 25-hour day (I9). `getEpochFromDateTimeString` is now a work-zone wrapper around it, kept for the harness.
- **`resolveTypedWindow(date, login, logout, zone, sameMeansNextDay, knownLoginMs)`** is the one rule every dialog now uses:
  - **A time in a spring-forward gap is refused (D6)**, with a sentence built from the engine's long zone name: _"2:30 AM doesn't exist on 03/08/26 in Pacific Time — clocks jumped forward."_ (`TimeZones.longName`, new).
  - **In the repeated hour** the login takes the earlier reading. The logout takes the earlier reading that isn't before the login, else the later one, instead of jumping a day.
  - **A logout still before the login** is read on the next calendar day in the zone. All eight `+ 86400000` next-day additions in the four save paths and the live preview are gone.
  - Each dialog keeps its own long-standing rule for a logout equal to the login, passed in as `sameMeansNextDay`.
- **Which zone.** Edit shift and edit task read typed times in the **record's zone**, and save `tz` explicitly, so a legacy record is stamped Los Angeles when edited (row 19). Manual entry and manual task read them in the **work zone** they file into. The live duration preview asks `typedFormZone(prefix)`.
- **The dialogs fill in the record's own clock.** `recordEndpointText` gives the stored string when it agrees with its instant, else the instant in the record's zone. A hint under the title (_"Times are in UTC+6, the zone this was recorded in."_) appears only when that zone isn't the work zone, so a single-zone logbook's dialogs look as they always have.
- **The round trip (row 18).** Each dialog remembers the times it opened with. Every save first normalises the fields (`9:00 am` → `09:00:00 AM`), so the comparison is done in that form. A time saved untouched on the same date keeps its instant byte for byte: it isn't re-read, which would move a repeated-hour login to its earlier reading, and it isn't re-floored to the second, which would drop a tracked shift's milliseconds.

**Tests.** `harness-tz-display.js` gains a typed-times part, run under the same two device zones: 103 checks in total. The part covers:

- the gap sentence;
- both ambiguity rules;
- the calendar next day across spring-forward;
- the edit dialog's fill and hint;
- a Dhaka edit read in Dhaka;
- a legacy edit stamped Los Angeles with its instants unchanged;
- a repeated-hour shift with milliseconds saved untouched, byte-identical;
- the `PST` hint when Dhaka is the work zone;
- the edit task fill, hint, untouched save and changed start;
- manual entry and manual task refusing gap times;
- a manual night across spring-forward ending at 14:00Z.

Two first-run failures were the test's own. A later login shrank a window below the 8 hours it held, which the app rightly refused as "will not fit". And the harness saved again while `isEditSubmitting` was still true, so the app turned that save away.

**Regression, one suite at a time — at baseline.** Numbers below are checks.

- **Time zone suites:** `harness-tz-core` 80, `harness-tz-model` 28.
- **No-account suites:**
  - `harness-progress` 25, `harness-motion` 43, `harness-cloud-panel` 27, `harness-security` 15;
  - `probe-leave-rows` 12, `probe-csv-shape` 14, `probe-backup-and-leave` 26, `probe-lease-endshift` 30;
  - `probe-field-sweep` unchanged, and `harness.js` ALL PASS.
- **Live account and the long suites:**
  - `harness-handoff` 22, `harness-signin-render` 12, `probe-shift-rewind` ALL PASS;
  - `harness-phase7` 21, `harness-phase8` 13, `harness-import` 9, `harness-wipe` 18;
  - `probe-beat-cost` 9: owner 120 messages an hour, idle 0, ceiling about 94.

`harness-signin-render` failed once inside the chain, on "signing in to an empty account uploads nothing" (1 pushed). It passed 12/12 re-run alone. Each launch uses a fresh browser profile, so the stray record came from the shared test account: leftover data from the live suite before it, pulled at sign-in. **Rule:** a live suite that fails straight after another live suite is re-run alone before the failure is believed.

**Mutations:** 10 new, all caught, each on the check written for it:

- a gap login accepted;
- the later reading for an ambiguous login;
- an ambiguous logout skipping its later reading;
- the next day as +24 h;
- the edit dialog reading in the work zone;
- an untouched time read again;
- a legacy edit saved without its zone;
- the edit task dialog in the work zone;
- the edit dialog filled in the work zone;
- the hint never shown.

The mutation run exposed a blind test on its first attempt. "An untouched time read again" survived the round-trip check, because the suite had saved its seed objects themselves. A save edits the stored record in place, so the check compared each instant with itself. The app was right: the same mutation did move the instant, which a later label check caught.

The seeds are now saved as copies, and that mutation is caught on the round trip. **Rule for every suite:** never compare a saved record with the object that was saved; capture the values or save copies.

Mutation 161 was re-pointed at the new work-zone wrapper. Anchors: 188, 0 misses. `index.html` was restored byte-identical.

#### Phase 3b2 results (2026-09-14)

**Committed as** `feat(time): export and search records with the zone they were filed in`. With it, Phase 3 is complete.

**What leaves the logbook now:**

- **CSV (D4).** In and Out are on each shift's own clock (`recordEndpointText`), never the display mode. A legacy shift exports exactly the strings it stores. `Time_Zone` is a new last column (a record with no zone exports `America/Los_Angeles`), so every existing column keeps its place. The task CSV does the same with its own `Time_Zone` column, and copying a task (one or all) reads as the task row does.
- **Search.** `zoneSearchTerms(record)` adds the zone id, its city and its plain abbreviation or offset (`asia/dhaka dhaka utc+6`) to the search index. That covers all eight places the index is built, including the search's own fallback.
  - It adds nothing to a record without a zone, so a legacy record's index is byte-identical (I3).
  - It never uses a nickname, which is a display preference (I10).
  - The index is local only: it is dropped from the storage mirror and stripped from every upload.
- **Idle dialog (D7).** "Last Active" and "Current Time" are on the local clock. When the work zone differs, one more line gives both moments on the work clock, labelled (e.g. `Work time (PDT): 9:05:03 AM → 9:07:10 AM`), because that is the clock the shift is filed on. It hides by a class rule (`.idle-work-row[hidden]`): an inline `display` would beat the `hidden` attribute and the line could never hide. On the tick it adds one formatter lookup per second and a label memoised per minute.
- **Export file names** carry the local date (when you exported).
- **The restore conflict list** shows each side on its own clock, with the zone tag when it isn't the work zone, escaped at the sink.
- **Device-local displays, audited.** Three sites read the browser's own zone directly: the sync card's "unreachable since" date, the "ago" fallback date, and the snapshot list's time. They now go through `getLocalZone()`. New en-US styles `dateNumeric` and `hm` print exactly what they printed before on an en-US device. The day-tooltip weekday (`toLocaleDateString` on a date built from its own parts) is zone-safe and unchanged.
- **Unchanged:** the login/logout strings written at submit and at rollover were already in the work zone the record is stamped with. The copy and EOD email reports print durations only.

**Tests.**

- **`harness-tz-display.js` gains an outputs part**, 129 checks in total over two device zones. It covers:
  - both CSVs, with work-zone display on as a negative control;
  - file names, with work Pago Pago and local Kiritimati (25 hours apart, so the dates always differ);
  - an old device event's date;
  - the search index through a real manual entry;
  - the conflict list's tag;
  - the idle dialog through the real `triggerIdleLock`, including the tick and the work line hiding when both zones match.
- **`probe-csv-shape.js`** now expects ten columns ending in `Time_Zone`, and a zone-less record exported as Los Angeles: 15 checks.
- **`harness-security.js`** expects ten cells, plus two new tests: a hostile `tz` reaches neither the conflict list nor the CSV (it reads as Los Angeles), and a nickname carrying markup is refused by both `setZoneDisplayPref` and a synced blob. 17 checks.

**Regression, one suite at a time — at baseline.** Numbers below are checks.

- **Time zone suites:** `harness-tz-core` 80, `harness-tz-model` 28.
- **No-account suites:**
  - `harness-progress` 25, `harness-motion` 43, `harness-cloud-panel` 27, `harness-security` 17;
  - `probe-leave-rows` 12, `probe-csv-shape` 15, `probe-backup-and-leave` 26, `probe-lease-endshift` 30;
  - `probe-field-sweep` unchanged, and `harness.js` ALL PASS.
- **Live account and the long suites:**
  - `harness-handoff` 22, `harness-signin-render` 12, `probe-shift-rewind` ALL PASS;
  - `harness-phase7` 21, `harness-phase8` 13, `harness-import` 9, `harness-wipe` 18;
  - `probe-beat-cost` 9: owner 120 messages an hour, idle 0, ceiling about 94.

`harness-handoff` failed once inside the chain, on "a follower refuses a corrupt anchor rather than showing days" (A's refusal read back as `null`). It passed 22/22 re-run alone, and also passed in the 3a and 3b1 chains.

That check waits on a realtime delivery, and nothing 3b2 changes touches sync or the lease. It is a timing flake of that one check, not leftover account data: no live suite ran before it in this chain.

**Mutations:** 11 new, all caught, each on the check written for it:

- the CSV's `Time_Zone` column dropped;
- CSV times following the display mode;
- the file named on the work clock;
- task CSV times on the work clock;
- zone terms left out of the search index;
- the idle dialog's last active time on the work clock;
- its work line never shown;
- its ticking time on the work clock;
- the conflict list's tag dropped;
- the "ago" date read in the browser's zone;
- `recordZone` trusting an unsanitised `tz`, caught by `harness-security.js`.

Anchors: 199, 0 misses. `index.html` was restored byte-identical.

**Phase 3 is complete.** Carried forward:

- **Phase 4:** the city names in search terms and edit hints use the engine's canonical spelling (Chrome's `Asia/Calcutta`). The picker's alias table is where the modern spelling comes from.
- **Phase 5:**
  - "nickname via `innerHTML`" waits for the clock labels, the first place a nickname is rendered.
  - `getLocalZone()` with `"auto"` reads the device zone (`resolvedOptions`, about 206 µs) on every call, and the idle tick and clocks call it every second. Cache it per minute before `"auto"` becomes the default.

### Phase 4 — The zone picker

**Goal:** `ZonePicker.open({ role, current, onPick })` exists, finished and measured, reachable only from tests.

- Metadata builder (lazy, chunked, cached), fallback zone list, zone→country map, alias table, search index and ranking.
- Dialog / sheet markup and CSS on the house tokens; 44 px touch rows; one scroller; reduced motion; all four themes.
- Keyboard and ARIA; desktop-only autofocus.

**Tests — `probe-tz-picker.js`:** search cases from §4.2; keyboard selection; `Etc/*` hidden but accepted; Automatic row only for the local role; row height at 390 px; no horizontal overflow at 375 px; first open timing under 4× throttle; takeover offer waits while it is open (row 39); fallback path with `supportedValuesOf` deleted (row 35).

**Regression:** `harness-motion.js`, `probe-field-sweep.js`, `harness-lease-prompt.js` (gate), `harness-security.js`.

**Mutations:** country not indexed; aliases missing; Enter does nothing; not a `.modal-overlay`; metadata built at boot; rows below 44 px.

**Commit:** `feat(time): a searchable picker over every time zone`.

### Phase 5 — Status bar, settings card, phone sheet, change flows

**5a — chrome:** remove `#primary-tz`, `.tz-presets`, the static `BST` label and `updatePrimaryFormatter`/`selectPresetTZ`/`updateTZLabel`; add the two clock buttons, single-zone mode, label policy, ETA label; update the POINTER-DRIVEN POPOVERS `FAMILIES` (41081) and the CSS blocks at 1012–1024, 1385, 1505–1524, 1717, 1775–1897, 5219–5227, 6132, 7170–7230, 7315–7493, 8863–8933; drop `tzPref` from `PREF_KEYS`.

**5b — flows:** settings card, `RELOCATIONS` swap, hover help, work-zone confirm, deferred banner with Undo, local-zone immediate apply, sync toast, first-launch notice, guide rewrite (§4.6).

**Tests — `probe-tz-ui.js`:** geometry at 1440 / 1280 / 1149 / 1024 / 820 / 768 / 430 / 390 / 375 px × 4 themes; pane ratio vs baseline; single-zone collapse; longest labels (row 38); banner uses a class (computed display off the timer pane on the phone); confirm asserts title before clicking; clicking a clock opens the picker for that role. Update `harness-phase8.js`'s parity case from `tzPref` to `workTz`/`localTz`/`tzDisplay`; update `harness-progress.js` if it reads the ETA text.

**Regression:** every no-account suite + `harness-phase8.js`.

**Mutations:** inline `display` on the banner; single-zone never collapses; phone label cap removed; ETA formatted in work zone; confirm skipped; `RELOCATIONS` still points at `.tz-presets`.

**Commits:** `feat(time): two live clocks for work and local time` (5a) and `feat(time): choose zones from settings and the phone sheet` (5b), plus `docs(guide): …` separately.

### Phase 6 — Sync hardening, multi-device, iPhone

**Goal:** prove §3.8 against the live database and the real device.

- Live suites, one at a time: `harness-phase8.js` (three devices: zone prefs parity), `harness-handoff.js` (+ row 30), `harness-signin-render.js` (+ rows 31–32), `harness-wipe.js` (zone keys wiped), `harness-realtime.js`, `harness-lease.js`, `harness-lease-prompt.js`, `harness-devices.js`, `harness-import.js`, `probe-beat-cost.js` (1.00 per owner beat, ceiling unchanged), `probe-live-gate.js`, `probe-shift-rewind.js`.
- Old-client check: serve `git show 9181afa:index.html` as device B beside the new build as device A on the same account; B must not throw, must keep `tz` on records it edits, and A must render B's edits correctly.
- **iPhone checklist for the user** (home-screen PWA, signed in): upgrade mid-shift; change local zone; change work zone during a shift and watch it apply at EOD; lock across midnight in a non-LA work zone (row 40); change the OS time zone and resume; read Copy diagnostics.

**Exit:** all live suites green; user confirms the checklist.

**Commit:** test-only changes live in the ignored harness; commit any app fixes found as `fix(time): …`.

### Phase 7 — Cleanup, docs, release

- Remove `getPSTDate`/`getPSTDateObj` aliases; update every harness reference (`harness-handoff.js:198`, `harness-phase6.js:299–305`, `harness-progress.js:95`, `probe-backup-and-leave.js`, `probe-leave-rows.js`, `tests-auth.js`, `tests-phase5.js`) and the mutation anchors.
- `docs/SYNC-BLUEPRINT.md`: a section on `sessionTz`, record `tz`, zone prefs and I3/I4/I11.
- README feature list; memory update.
- Full no-account + live sweep and the full mutation run.

**Commit:** `chore(time): retire the PST names` and `docs: time zones`.

---

## 8. Decisions for you

**Confirmed on 2026-09-13: all eight as recommended.** The plan above is written with exactly these options.

| #   | Question                                             | Recommended                                                                                                                                                    | Alternative                                                                                    |
| --- | ---------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| D1  | What times does a log row show by default?           | **The zone it was recorded in**, with a tag when it differs from today's work zone                                                                             | Always convert to the current work zone                                                        |
| D2  | Changing the work zone while a shift is running      | **Allowed, but it applies when the shift ends** (banner + Undo)                                                                                                | Block the change until the shift is submitted                                                  |
| D3  | Clock labels                                         | **DST-correct abbreviations (PDT/PST), offset where none exists; seed the nickname "BST" for `Asia/Dhaka` on existing installs** so your screen looks the same | Show `UTC+6` for Dhaka (avoids the clash with British Summer Time)                             |
| D4  | CSV export                                           | **Add a `Time_Zone` column at the end** (existing columns keep their positions)                                                                                | Leave the CSV exactly as it is                                                                 |
| D5  | Default work zone for a brand-new user               | **Their device's zone, locked in at their first clock-in**                                                                                                     | Ask on first launch                                                                            |
| D6  | A typed time that doesn't exist (spring-forward gap) | **Refuse, with a message saying why**                                                                                                                          | Keep today's behaviour, measured in Phase 0: silently read it an hour back (02:30 → 01:30 PST) |
| D7  | Idle dialog "Last active" / "Current time"           | **Local time** (work time underneath when different)                                                                                                           | Keep work time                                                                                 |
| D8  | `Etc/GMT±N` pseudo-zones in the picker               | **Hidden** (still accepted if already stored)                                                                                                                  | Listed                                                                                         |

---

## 9. Out of scope (candidate follow-ups)

- 24-hour clock preference.
- Date display order (DD/MM) — storage stays `MM/DD/YY` regardless.
- **Work-week definition** — `WEEKLY_GOAL_WORKDAYS`, `WEEKEND_GOAL_RATIO` and Saturday/Sunday weekends are hardcoded. A company with a Friday/Saturday weekend needs this, and it's the natural next step after zones.
- More than two clocks; per-client zones inside one account.
- Editing a record's zone after it was filed.

---

## 10. Risks and rollback

| Risk                                                          | Mitigation                                                                                                                                                              |
| ------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Regressing the one real deployment (LA work zone, iPhone PWA) | Phase 1 is behaviour-identical and gated on the existing suites before any semantics change; Phase 6 ends on the iPhone checklist                                       |
| Upgrade lands mid-shift                                       | Legacy session ⇒ `LEGACY_TZ` (row 2), tested in Phase 2                                                                                                                 |
| A new device overwrites the account's zone                    | Derived values never stamped (I11); three-device parity test                                                                                                            |
| Engine differences (Safari vs Chrome names/labels)            | Canonical comparison (I7); label derivation tolerant of missing styles; iPhone check                                                                                    |
| Invalid zone from sync/import crashes the tick                | Sanitise at every boundary (I6); hostile-input tests                                                                                                                    |
| Phone status bar overflow                                     | Label caps; geometry probe at 375 px with the longest pair                                                                                                              |
| Picker jank on open                                           | Eager labels for every zone measured at 3.9 s under 4× throttle, so: static-string first paint, labels for rendered rows only, offset/name index in idle slices (§3.11) |
| Mutation anchors detach during renames                        | Aliases kept until Phase 7; `mutation-anchors.js` after every format                                                                                                    |

**Rollback:** every phase is its own commit(s) and reverts cleanly. Data written by later phases is forward-compatible with earlier builds: unknown `tz` / `sessionTz` / pref keys are ignored. The one visible artefact of reverting after Phase 3 is that records filed in a non-LA zone show their stored strings (correct times, no zone tag) under an LA date semantics they were not filed in. That's acceptable because nobody but this team uses a non-LA zone until Phase 5 ships the UI.

---

## Appendix A — call-site inventory at `9181afa`

**Formatters and constants:** 17310–17426 (`_cachedLocaleDayFirst`, `_cachedResolvedTz`, `getCachedTzFormatter`, `getCachedTimeOnlyFormatter`, `APP_TZ`, `pstFormatter`, `pstDateFormatter`, `exportNameDateFormatter`, `pstDateObjFormatter`, `bstFormatter`, `loginFormatter`, `bstEtaFormatter`, `primaryFormatter`, `updatePrimaryFormatter`).

**`getPSTDate()`:** 16643, 23963, 24048, 25174, 25701, 25879, 25969, 26110, 26199, 26528, 26729, 27435, 28597, 28810, 29243, 30417, 30781, 30811, 32461, 32677, 33661, 34597, 35957, 36049, 36609, 40217, 40219, 40467.

**`getPSTDateObj()`:** 24922, 25144, 25250, 27433, 28817, 29138, 29345, 29945, 30385, 37617, 38001, 38412, 38730, 39820, 40409, 40835, 40840, 40858, 40903, 40955, 41037.

**Formatter uses:** `pstFormatter` 23982, 25604, 25911 · `loginFormatter` 25602, 25909, 26530, 28604, 29488, 29579, 30504, 30658, 30662, 36828, 37128, 37165 · `pstDateFormatter` 23998, 26111, 32721, 32773, 32842, 32900, 32973 · `pstDateObjFormatter` 24019 · `bstFormatter` 24855 · `primaryFormatter` 24848–24854 · `bstEtaFormatter` 25359 · `getCachedTimeOnlyFormatter(APP_TZ)` 26078, 33079–33081 · `rolloverFormatter` 32724–32813 · `exportNameDateFormatter` 31237, 31343, 37242 · `APP_TZ` 37210, 39025.

**Stored-string readers:** 20008, 25643, 26517–26525, 27561, 28265, 28314, 28578–28592, 29309–29341, 29483–29484, 29574–29575, 30437–30448, 30596–30597, 31067–31081, 31191–31192, 31381, 31602, 31911, 39128–39150, 40509.

**Wall-time → instant:** `getEpochFromDateTimeString` 38999 (callers: manual 36144–36151, edit log ≈30950–31004, edit/manual task, `resolveTimeConstraints` 39128).

**Session / sync:** `SYNC_INSTANT_KEYS` 17543 · `mintSessionId` 17579 (calls 24534, 26103) · `RECORD_KINDS` 18185 · `SESSION_FIELDS` 18391 · `SETTINGS_FIELDS` 18421 · `PREF_KEYS` 18511 · `readPrefs` 18531 · `applyPrefs` 18563 · `hasLiveSession` 20773 · `adoptSession` 21129 · `adoptSettings` 21212 · `sessionFingerprint` 22223 · `resetSession` 26168 · `checkMidnightReset` 32647 · `recoverSessionOnBoot` 40149.

**Prefs / UI / CSS / guide:** `TZ_KEY` 16130, 32237–32245, 32298, 39375–39378 · markup 12146–12211, 12454, 15316 · `selectPresetTZ` 23408 · `updateTZLabel` 23419 · popover `FAMILIES` 41081 · `RELOCATIONS` 41155 · CSS 1012–1024, 1385, 1505–1524, 1717, 1775–1897, 5219–5227, 6132, 7170–7230, 7315–7493, 8863–8933 · guide 9871, 9937, 10566–10569.

**Device-local displays to audit (Phase 3):** 20577, 34885, 35758.

**Harness references to the old names:** `harness-handoff.js:198`, `harness-phase6.js:299–305`, `harness-phase8.js:429` (`tzPref`), `harness-progress.js:95`, `mutation-test.js:381, 1472`, `probe-backup-and-leave.js:68, 131, 149, 198, 312`, `probe-leave-rows.js:37–40`, `tests-auth.js:143`, `tests-phase5.js:165–192`.
