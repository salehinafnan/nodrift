# Time zones: implementation blueprint

> **Status:** Phases 0–4 complete. Every zone-dependent calculation goes through `TimeZones`, and the zone model exists (an unset work zone is Los Angeles on a device with data from before zones and the device's own zone for a new user; an unset local zone follows the device). Every record is shown, edited, exported and searched in the zone it was filed in. A searchable picker over every time zone opens from the clocks and the settings card. Phase 5a is done: the status bar shows live work and local clocks. Phase 5b1 is done: zones are changed from the clock labels, a settings card and the phone sheet, with a confirmation for the work zone, a banner with Undo during a shift, and a toast for a zone synced from another device. Phase 5b2a is done: a new user's work zone starts as the device's own and is pinned at the first clock-in, and an unset local zone follows the device. Phase 5b2b is done: clock labels (a style, and a nickname per zone) from the Time zones card, a one-time notice on devices that used nodrift before zones, and a rewritten guide section. Phase 5 is complete. Phase 6a is done: the live suites found that a new device signing in could replace the account's settings with its own defaults when its day moved, fixed by never uploading a goal the app works out for itself; an old-client check runs the build from before zones beside this one. Phase 6b is done: rows 29, 30, 34 and 40 and the wipe of the zone preferences hold against the live database with no app change. Phase 6 is complete: the user ran the iPhone checklist on the live build, and a fresh sign-in on the phone uploaded nothing. A pause answered after midnight, found in 6b and older than zones, is fixed: the answer is applied to the new day, and after Discard today's shift starts at the answer. Phase 7 is done: the PST names are gone from the app (the two aliases and seven local names), the README and `SYNC-BLUEPRINT.md` describe time zones, and the first full mutation run since zones began found five test gaps older than zones, now fixed. All phases are complete.
> **Baseline commit:** `9181afa` (all line numbers below refer to it and WILL drift — re-grep before editing).
> **Rule:** one phase at a time. A phase starts only when the previous phase's exit criteria are green and committed.

| Phase | Title                                                | Touches data?    | Needs live account? | Size                 | State    |
| ----- | ---------------------------------------------------- | ---------------- | ------------------- | -------------------- | -------- |
| 0     | Groundwork, probes, fixtures                         | no               | one read-only probe | S                    | **done** |
| 1     | `TimeZones` core + behaviour-identical refactor      | no               | regression only     | L (split 1a/1b)      | **done** |
| 2     | Data model: work / local / session / record zones    | **yes**          | regression only     | L (split 2a/2b)      | **done** |
| 3     | Rendering and editing records in their own zone      | yes (edit paths) | no                  | M–L (split 3a/3b)    | **done** |
| 4     | The zone picker component                            | no               | no                  | M–L (split 4a/4b)    | **done** |
| 5     | Status bar, settings card, phone sheet, change flows | prefs            | no                  | L (split 5a/5b1/5b2) | **done** |
| 6     | Sync hardening + multi-device + iPhone verification  | no               | **yes**             | M                    | **done** |
| 7     | Cleanup, aliases removed, docs, guide                | no               | full sweep          | S                    | **done** |

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
  - **Narrowed (decided 2026-09-14, Phase 5b2):**
    - The pin applies only when the default came from the device's own zone. A zone read from the logbook is the same on every device holding that logbook, so it stays derived.
    - It never applies on a signed-in device before its first sync has finished, because that sync may bring the account's own choice or its legacy logs.
    - "`state.activeDate` predates the feature" is the device's install verdict (`nodrift_tz_install_v1` = `"upgrade"`, recorded in Phase 5a).
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

| Change                                                       | No shift running                                                                                                                                                                                                                  | Shift running / paused / idle-locked / clocked out but not submitted                                                                                                                                                                                                                                                                                                                                                             |
| ------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Work zone**                                                | Confirm dialog (§4.4) → applies immediately; `activeDate` realigns synchronously through `onZoneContextChanged()`; goal re-populates.                                                                                             | **Deferred.** The pref is saved (and syncs) at once; `getWorkZone()` keeps returning `sessionTz`; a banner says _"Work time zone changes to Dhaka (UTC+6) when this shift ends · Undo"_. It takes effect the moment `sessionHoldsZone` turns false (EOD submit, a rollover that empties the session, reset). "Pending" is not stored anywhere — it is simply `pref ≠ sessionTz` while live. Undo = set pref back to `sessionTz`. |
| **Local zone**                                               | Immediate. Clocks and ETA only.                                                                                                                                                                                                   | Immediate. Clocks and ETA only.                                                                                                                                                                                                                                                                                                                                                                                                  |
| **Device moves zone** (travel, OS setting) with local = Auto | Detected on `visibilitychange` / `focus` / `pageshow` and once a minute in the tick; clocks update silently. On iPhone the first return after an OS zone change can still read the old zone until the app is reopened (Phase 6c). | Same. No data effect (I10).                                                                                                                                                                                                                                                                                                                                                                                                      |
| **Work zone changed on another device** (sync)               | Adopted like any pref; confirm is not shown (the user already confirmed there); a toast names the new zone.                                                                                                                       | Adopted into the pref, deferred exactly as above, same banner.                                                                                                                                                                                                                                                                                                                                                                   |

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
- **Label footer — moved to Phase 5 (decided 2026-09-14):** nickname per zone (stored in `tzDisplay.nicknames[zoneId]`, so a nickname never follows you to another zone) and style (Abbreviation / Generic / Offset). Nothing shows either until Phase 5's clocks, so it arrives with them and is tested against a real label. The picker ships without it: tapping a row, or Enter on the highlighted one, picks and closes.
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

Split in two so each commit is safe to deploy on its own: **4a** is the catalog and its search, which nothing calls yet; **4b** is the dialog, still reachable only from tests.

#### Phase 4a results (2026-09-14)

**Committed as** `feat(time): a searchable catalog of every time zone`. No screen changes: nothing calls the catalog until 4b.

**What exists now:**

- **`ZoneCatalog`** (section "3c. ZONE CATALOG", built on first use, never at boot):
  - `entries()` — every zone the engine lists, `Etc/*` hidden (D8), `UTC` added. Each has a city, a country (code and English name) and a region, sorted alphabetically by city with accents and punctuation folded away, so São Paulo sits among the S's.
  - `entry(id)` — also accepts a hidden or differently spelled zone (a stored `Etc/GMT+5`, `Asia/Kolkata` on Chrome); `null` for anything invalid.
  - `search(query)` — ranked, in two tiers:
    - **At once, from strings:** city, other spellings, country, region and id. Accents and punctuation are ignored, and several words must all match.
    - **As the index arrives:** abbreviations in January, July and now (`pst` finds Los Angeles in September), offsets (`utc+6`, `+06:00`, `5:30` matching both signs; today's offset outranks a seasonal one), and generic names (`pacific time`).
    - It returns `pending` until the index is done.
  - `buildIndex()` — offsets, abbreviations and generic names for every zone, one throwaway formatter at a time. It yields whenever a slice has run 8 ms, is cached for the page's life and is rebuilt once an hour old.
  - `describe(id, ms)` — what a row shows: `12:00 PM`, `UTC−7`, `PDT`. It uses at most two cached formatters per zone.
  - `recents()` / `remember(id)` — the last five choices, device-local (`nodrift_tz_recent_v1`), validated on read and wiped by a factory reset.
- **Three generated tables** (`nodrift-harness/gen-zone-data.js`, from Node's ICU, which lists the same 418 zones as Chrome 152):
  - the zone list (3.9 KB), the fallback for engines without `supportedValuesOf`;
  - one CLDR country per zone (0.8 KB), choosing the live code where retired ones (SU, UK) also map;
  - 123 other spellings the engine itself resolves (3.5 KB): renamed cities, merged zones, `US/Pacific`-style links.
- **`TimeZones` gains:**
  - `city(zone)`: today's spelling (Kolkata, Kyiv, Ho Chi Minh City, Nuuk…) and accents (São Paulo, Reykjavík, St. John’s);
  - `zoneFacts` (the index's uncached formatters, so I8 holds);
  - `clockFacts` (row labels, with a parts fallback where `shortOffset` is missing);
  - a `clock` style;
  - a verdict shortcut: an id in the engine's own list is its own canonical form (checked for all 418).
- **Phase 3 carry-over:** a record's search terms carry both spellings (`kolkata calcutta`).

**Measured under 4× CPU throttle, and what it changed:**

| What                                 | First version                                         | Shipped                                                                                              |
| ------------------------------------ | ----------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| Full index                           | 14.3 s — `requestIdleCallback` waited out its timeout | **1.14 s** — background-priority tasks (`scheduler.postTask`)                                        |
| First search (builds the list)       | 107.7 ms, itself a long task                          | **36 ms** — ASCII skips normalising, one lookup per country, no `Collator`, word lists on demand     |
| Longest index slice                  | —                                                     | 13.5 ms: one zone's three formatters can take 15 ms, so the deadline is checked after each formatter |
| A screenful of row labels (14 zones) | —                                                     | 18 ms (budget 60)                                                                                    |

One formatter per zone per kind costs 150–260 ms across all 418 zones at 4×. A cold first build in a fresh process cost 90 ms before the changes and about 21 ms warm, profiled with the CDP sampling profiler.

**Tests — `probe-tz-picker.js`, 135 checks, no account.** Ports 8875/9475, shared with the measure-only `probe-tz-picker-cost.js`.

- **Budgets** at 4× on a fresh page: first search, index total, longest slice, long tasks against a quiet control window, row labels.
- **The catalog** under two device zones, each on a fresh page:
  - not built at boot;
  - the list: counts, `Etc/*` hidden (two injected into the engine's list) but accepted, `UTC` once, sorting, a country for every zone, spellings and accents;
  - 19 tier-one and 14 tier-two searches;
  - row facts in July and January;
  - recents, including corrupt and hostile stored values;
  - both search-term spellings, and a zone-less record still adding nothing (I3).
- **The fallback engine** (edge case 35): `supportedValuesOf` deleted and the newer `timeZoneName` styles throwing, installed before the app loads. The list comes from the embedded table, offsets from parts, and the index and searches still work.

**Regression, one suite at a time — at baseline.** Numbers below are checks. The regression script now runs 23 suites: `probe-tz-picker.js` first, and `harness-lease-prompt.js` (the takeover gate that Phase 4b must respect) last. The lease-prompt suite was baselined at 21 on the unmodified tree.

- **Time zone suites:** `probe-tz-picker` 135, `harness-tz-display` 129, `harness-tz-core` 80, `harness-tz-model` 28.
- **No-account suites:**
  - `harness-progress` 25, `harness-motion` 43, `harness-cloud-panel` 27, `harness-security` 17;
  - `probe-leave-rows` 12, `probe-csv-shape` 15, `probe-backup-and-leave` 26, `probe-lease-endshift` 30;
  - `probe-field-sweep` unchanged (19 short fields on desktop, 0 on the phone), and `harness.js` ALL PASS.
- **Live account and the long suites:**
  - `harness-handoff` 22, `harness-signin-render` 12, `probe-shift-rewind` ALL PASS;
  - `harness-phase7` 21, `harness-phase8` 13, `harness-import` 9, `harness-wipe` 18;
  - `probe-beat-cost` 9: owner 120 messages an hour, idle 0;
  - `harness-lease-prompt` 21.

Two live suites each failed one check inside the chain. Both passed on their own straight afterwards, and 4a changes nothing in sync:

- `harness-signin-render`, "signing in to an empty account uploads nothing" (got 1). It ran right after `harness-handoff`; this is the account-residue failure seen in 3b1.
- `harness-phase7`, "uploading marks the push time and leaves the pull time" (the cycle uploaded 0). It ran right after `probe-shift-rewind`.

**Mutations:** 13 new, all caught, each on the check written for it:

- country left out of search; the other spellings ignored; the list built at boot;
- diacritics not folded (caught by the accented country and the sort order: "sao paulo" still finds São Paulo through the engine's ASCII spelling);
- the index built in one slice; slices spaced by idle periods;
- `Etc/GMT` zones listed; UTC left out; recents unbounded;
- no parts fallback without `shortOffset`;
- Kolkata spelled Calcutta; record search terms in the engine's spelling only;
- the list sorted by the raw city name.

Anchors: 212, 0 misses. `index.html` was restored byte-identical.

**Measuring on a laptop.** The first mutation run started on a baseline that was already red on every 4× budget: timings came in 5–7× slow and the unmutated page crashed. The laptop was on battery, with the CPU held at 1.0 of 2.4 GHz. Plugged in, the same code measured 31 ms for the first search and 1.0 s for the index, and the re-run above is on AC. Two probe changes came out of it:

- A budget that misses is measured again on a fresh page, and graded on the better of the two runs.
- The index measurement is bounded at 20 s, so a crawling index fails its check instead of the harness.

Check the power state before any timing-graded run.

#### Phase 4b results (2026-09-14)

**Committed as** `feat(time): a searchable picker over every time zone`. Still reachable only from tests: Phase 5 adds the clocks and settings rows that open it. The label footer moved to Phase 5 (§4.2).

**What exists now:**

- **`ZonePicker.open({ role, current, onPick })`**, plus `close()`, `isOpen()` and `closeZonePicker()`.
- **`#zone-picker-modal` is a `.modal-overlay`** like every other dialog, so the existing machinery covers it:
  - it is listed in `MODAL_IDS` (Tab stays inside), in `MODAL_CLOSERS` (Escape) and in `closeAllActiveModals`;
  - the takeover offer's gate and `body[data-modal-raised]` see it with no extra wiring.
- **With an empty search:**
  - **SUGGESTED:** Automatic (local picker only), the current zone (✓), and this device's zone, labelled;
  - **RECENT**;
  - **ALL TIME ZONES**.
- **With a query:** the ranked results. "Searching all time zones…" shows while the index is still pending; a search with no match says so.
- **Rows:** city · country on the left, the time over abbreviation · offset on the right.
  - The labels are filled only as a row scrolls into view, and refreshed every 15 s while the picker is open.
  - Rows are 40 px on the desktop and 44 px on the phone.
- **Keys:**
  - ↑ ↓ Home End move the highlight, read out through `aria-activedescendant` on the search field;
  - Enter picks and Escape closes;
  - a printable key pressed anywhere in the open dialog goes to the search, and never reaches the app's shortcuts (Space would otherwise start the timer).
- **Desktop:** a 520 px dialog, search focused, rising in like the others.
- **Phone:** the help modal's full-width sheet, with no autofocus and the list as the only scroller.
- **A pick** is remembered in recents (Automatic never is), and focus returns to whatever opened the picker.
- **First paint** draws the headings and the first 24 rows; the rest follow 60 rows per task. A keyboard move paints ahead to wherever it lands.
  - Drawing all 421 rows at once measured 137–153 ms at 4×, against a 100 ms budget.
  - Chunked with 40 rows first it measured 86–103 ms, so the first paint was cut to 24 rows, still a full screen on both layouts.

**Tests.**

- **`probe-tz-picker.js` gains 41 dialog checks, 176 in all.**
  - **Desktop:**
    - wiring, and hidden and unbuilt at boot;
    - the first open at 4×;
    - titles, suggested rows and the selection mark;
    - labels only on screen;
    - search, Enter, recents and focus return;
    - arrows, Home and End, including End past the painted rows;
    - Escape, type-ahead, and Space not starting the timer;
    - `closeAllActiveModals`, and Automatic in the local picker;
    - a stored `Etc/GMT` zone shown as current;
    - a hostile current zone and recents never rendered as markup;
    - the empty state and the pending hint;
    - row height, one scroller, the entrance, reduced motion and all four themes.
  - **Phone:** 390 px with no autofocus, 44 px rows, one scroller and a full-width sheet; no overflow at 375 px.
- **`harness-lease-prompt.js` gains section 5b** (edge case 39): the real picker, opened on the phone over the timer, holds the takeover offer back, and closing it lets the offer through. 23 checks.

**Regression, one suite at a time — at baseline.** Numbers below are checks.

- **Time zone suites:** `probe-tz-picker` 176, `harness-tz-display` 129, `harness-tz-core` 80, `harness-tz-model` 28.
- **No-account suites:**
  - `harness-progress` 25, `harness-motion` 43, `harness-cloud-panel` 27, `harness-security` 17;
  - `probe-leave-rows` 12, `probe-csv-shape` 15, `probe-backup-and-leave` 26, `probe-lease-endshift` 30;
  - `probe-field-sweep` unchanged (19 short fields on desktop, 0 on the phone: the picker's 36 px search is not one of them), and `harness.js` ALL PASS.
- **Live account and the long suites:**
  - `harness-handoff` 22, `harness-signin-render` 12, `probe-shift-rewind` ALL PASS;
  - `harness-phase7` 21, `harness-phase8` 13, `harness-import` 9, `harness-wipe` 18;
  - `probe-beat-cost` 9;
  - `harness-lease-prompt` 23, including section 5b (edge case 39).

Five suites needed a run on their own, and all five passed alone:

- **`harness-progress`** never started inside the chain (exit 127, empty log), so there was no result to read.
- **`harness-handoff`** failed "a follower refuses a corrupt anchor" (read `null`), and **`harness-signin-render`** failed "uploads nothing" (got 1). These are the same two checks that failed inside the 3b1, 3b2 and 4a chains.
  - `harness-handoff` passed on its second run alone. Its first solo run failed at the start together with its own negative control ("the domains are not actually separate"), the harness's sign of trouble outside the app.
- **`harness-phase7`** failed "uploading marks the push time" (the pull stamp moved 1.8 s), the same check as in the 4a chain.
- **`harness-wipe`** failed "the cloud row really carries the running shift" (empty payload). This is the first time that check has failed, and nothing in 4b touches sync or the wipe.

**The first-open budget has little margin on this laptop.** In the chain, the first measurement was 155.6 ms and the retry on a fresh page 83.6 ms; the first run overlapped a formatting check started at the same moment. On a quiet machine with 40 rows drawn first it measured 102.9 ms and then 86.3 ms, which is why the first paint was cut to 24 rows. A cold first open sits near the 100 ms line at 4×; warm, about 84 ms.

**Mutations:** 15 new, all caught, each on the check written for it:

- Enter does nothing; not a `.modal-overlay`; phone rows below 44 px (the plan's three);
- Automatic offered to the work picker; the search focused on the phone; every row labelled, on screen or not;
- the dialog scrolling around the list; arrow keys not moving the highlight; a pick not remembered;
- left out of `MODAL_CLOSERS`; type-ahead letting the app's shortcuts read the key;
- every row drawn before the first paint; focus not handed back; opened by class instead of the inline display; the list not filled in after the first rows.

Anchors: 227, 0 misses. `index.html` was restored byte-identical. The run was on AC throughout: the battery status and the 2419 MHz clock were logged at its start and end.

An earlier run was stopped when the laptop came off AC. It had started on battery against a red baseline, so its results were discarded.

**Phase 4 is complete.** Carried into Phase 5:

- the triggers that open the picker: the clock buttons and the settings rows;
- the label footer (§4.2);
- the "nickname via `innerHTML`" mutation, once a nickname is rendered.

### Phase 5 — Status bar, settings card, phone sheet, change flows

**5a — chrome:** remove `#primary-tz`, `.tz-presets`, the static `BST` label and `updatePrimaryFormatter`/`selectPresetTZ`/`updateTZLabel`; add the two clock buttons, single-zone mode, label policy, ETA label; update the POINTER-DRIVEN POPOVERS `FAMILIES` (41081) and the CSS blocks at 1012–1024, 1385, 1505–1524, 1717, 1775–1897, 5219–5227, 6132, 7170–7230, 7315–7493, 8863–8933; drop `tzPref` from `PREF_KEYS`.

**5b — flows:** settings card, `RELOCATIONS` swap, hover help, work-zone confirm, deferred banner with Undo, local-zone immediate apply, sync toast, first-launch notice, guide rewrite (§4.6), and the label footer moved here from the picker (§4.2): a nickname per zone and the label style, tested against the clocks that show them.

**Tests — `probe-tz-ui.js`:** geometry at 1440 / 1280 / 1149 / 1024 / 820 / 768 / 430 / 390 / 375 px × 4 themes; pane ratio vs baseline; single-zone collapse; longest labels (row 38); banner uses a class (computed display off the timer pane on the phone); confirm asserts title before clicking; clicking a clock opens the picker for that role. Update `harness-phase8.js`'s parity case from `tzPref` to `workTz`/`localTz`/`tzDisplay`; update `harness-progress.js` if it reads the ETA text.

**Regression:** every no-account suite + `harness-phase8.js`.

**Mutations:** inline `display` on the banner; single-zone never collapses; phone label cap removed; ETA formatted in work zone; confirm skipped; `RELOCATIONS` still points at `.tz-presets`.

**Commits:** `feat(time): two live clocks for work and local time` (5a) and `feat(time): choose zones from settings and the phone sheet` (5b), plus `docs(guide): …` separately.

**Split (decided 2026-09-14):** the clocks are read-only in 5a, so a 5a deploy on its own can never change the work zone without the confirmation 5b adds. 5b becomes two parts:

- **5b1:** the clock buttons that open the picker, the settings card and the `RELOCATIONS` swap, hover help, the work-zone confirm, the deferred banner with Undo, local-zone immediate apply, and the sync toast.
- **5b2:** the label footer (§4.2), the first-launch notice, D5 (the device default and the clock-in pin), a local default of "auto", the guide rewrite (§4.6) and the "nickname via `innerHTML`" mutation.

**5b2 split again (decided 2026-09-14), each part its own commit:**

- **5b2a:** D5 and the local default. Nothing on screen changes for a device with data from before zones.
- **5b2b:** the clock labels, the first-launch notice, the guide rewrite and the `innerHTML` mutation.

**Decisions asked before 5b2 (2026-09-14):**

- **Label controls:** a "Clock labels" row in the Time zones card opens a small dialog: the style, a nickname for each clock's zone, and a live preview. The picker keeps picking and closing on a tap.
- **Clock-in pin:** only for a zone taken from the device, and not before a signed-in device's first sync (§3.3).
- **Notice:** a small dialog that waits its turn the way the takeover offer does.

#### Phase 5a results (2026-09-14)

**Committed as** `feat(time): two live clocks for work and local time`. The clocks are read-only: nothing on screen changes a zone yet.

**What changed:**

- **Gone:**
  - `#primary-tz`, the `.tz-presets` menu and its trigger, and the static `BST` label;
  - `updatePrimaryFormatter`, `selectPresetTZ` and `updateTZLabel`;
  - `tzPref` in `PREF_KEYS` (the storage key stays, and a factory reset still wipes it), and the menu's `FAMILIES` entry;
  - the phone sheet's Time Zone section, which 5b1 brings back with the settings card.
- **Clocks:** `#work-clock` shows `getWorkZone()` and `#local-clock` shows `getLocalZone()`.
  - Each has a label (`.tz-clock-label`) drawn by `renderClockLabels()` from the label policy (§4.5), and a tooltip such as "Work time · Pacific Time (Los Angeles) · UTC−7".
  - Labels are redrawn once a minute, and at once through `onZoneContextChanged()`, which now also resets the tick's per-second guard.
  - The tick's minute cache is keyed on the epoch minute and the work zone, because a shift that ends hands over to a pending work zone without passing through the funnel.
- **Single-zone mode:** `.m-clock-cluster.is-single-zone` hides the divider, the local label and the local clock (I13).
- **Phone:**
  - an offset label drops its "UTC" by a stylesheet rule (`+5:30`);
  - a label is capped at 5.5ch with an ellipsis, so a six-character nickname is cut and a five-character one is not.
- **Tablet band:** the work clock alone, as before. With the menu's chevron gone the bar fits one line at 1149 px (38 px, was 83 px); it still wraps at 1024 px and below.
- **Est. EOD:** in the local zone, labelled like the local clock at the finish instant.
- **D3:** `seedZoneLabels()` runs while the script is evaluated, before Sync takes its preference baseline.
  - On the first launch of this build it records `nodrift_tz_install_v1` as "upgrade" (the device already holds state or logs) or "fresh".
  - An upgrade with no display preference gets `{ nicknames: { "Asia/Dhaka": "BST" } }`, so this team's screens still read BST.
  - The verdict is device-local and wiped by a factory reset. 5b2's first-launch notice will read it.
- **Guide:** the passages that described the PST/MST/CST/EST menu and the fixed BST clock now describe the two clocks. The full rewrite is 5b2.

**Tests.**

- **`probe-tz-ui.js`, 51 checks** (ports 8876/9476):
  - **D3:**
    - a fresh install is fresh, and stays fresh after its first boot;
    - an upgrade gets BST, and the estimate uses it;
    - the seed is not a settings edit (I11);
    - a removed nickname stays removed, and an existing display preference is kept;
    - a factory reset forgets the verdict;
  - **old chrome:** the menu and `tzPref` are gone, and the zone preferences still sync;
  - **labels:**
    - both clocks' times and labels, PDT in July and PST in January, and the tooltips;
    - the offset, generic and nickname styles;
    - a hostile stored nickname is ignored and never becomes markup;
  - **zone changes:**
    - the label changes at once on a zone change, and a work zone other than Los Angeles is shown;
    - single-zone mode by class, with two spellings of one zone counting as one (I7), and the second clock coming back;
    - the estimate in the local zone;
    - the hand-over at the end of a shift within one minute;
  - **cost and device zone:** 3 s of ticks on a settled page create no formatter; the same results under device zone Pago Pago;
  - **geometry:**
    - 1440, 1280, 1149, 1024, 820, 768, 430, 390 and 375 px in four themes;
    - the pane ratio against the baseline measured before 5a: 1440 px 1.498 (was 1.512), 1280 px 1.709 (was 1.729);
    - the longest labels on a 375 px phone (edge case 38), the phone cap, and single-zone mode on the phone.
- **`harness-progress.js`:** the ETA pattern accepts any label.
- **`harness-phase8.js`:** the parity case moves from `tzPref` to `workTz`, set to `America/Vancouver`. It keeps Los Angeles' clocks all year, so no date on the shared account moves.

**Regression, one suite at a time — at baseline.** 24 suites, with `probe-tz-ui` (51) first. Every other suite read the same number as after Phase 4, `harness-phase8` 13 with its new case.

- `harness-signin-render` failed "signing in to an empty account uploads nothing" inside the chain, the same check as in earlier chains. It passed 12 of 12 alone.
- The laptop came off AC near the end of the chain. Nothing timing-graded failed; `probe-tz-picker` ran in its first minute.

**Mutations:** 10 new, all caught, each on the check written for it, on AC throughout:

- the plan's four that apply to 5a: single-zone mode never collapses; the second clock hidden by an inline display; no phone label cap; the estimate in the work zone;
- labels ignoring daylight saving; the minute cache ignoring the work zone; the work clock stuck on Los Angeles;
- the D3 seed ignoring the verdict; the seed on fresh installs; `tzPref` still synced.

The plan's other two, the banner's inline display and `RELOCATIONS` still pointing at `.tz-presets`, belong to 5b1. Anchors: 237, 0 misses. `index.html` was restored byte-identical.

**Two faults the first run of the probe found:**

- **A flex label reads "UTC", a line break, then "+6".** `inline-flex` makes each of the two spans its own block, which is invisible on screen and wrong in anything that copies or reads the text. The label is `inline-block`.
- **`scrollWidth` counts a closed popover.** At 1149 px the goal presets, laid out at opacity 0, reached 55 px past the bar. The probe measures only what is painted.

#### Phase 5b1 results (2026-09-14)

**Committed as** `feat(time): choose zones from settings and the phone sheet`.

**What changed:**

- **Clock labels** are buttons (`.tz-clock-btn`) that open `ZonePicker` for their role. Each carries its tooltip as `aria-label`.
  - **No chevrons.** With two of them the pane ratio measured 1.627 at 1440 px and 1.868 at 1280 px, against limits of 1.542 and 1.764, and the 1149 px bar wrapped to 83 px again. A hover and focus tint marks the buttons instead.
  - **Phone:** the bar only reads (`pointer-events: none`). The 5.5ch cap moved from the label to its text span, because not every engine draws an ellipsis inside a button's own box.
- **Settings card** (`.tz-settings-card`), first in the settings panel:
  - rows for the work and local zones, each showing the zone as its clock labels it, the city and a chevron;
  - a "Show log times in" dropdown, which merges the mode into `tzDisplay` so nicknames stay;
  - hover help for all three rows;
  - redrawn through `onZoneContextChanged()`, and whenever the panel or the phone sheet opens.
- **Phone sheet:** `RELOCATIONS` moves the card into a restored Time Zone section, between Goals and Appearance. Its rows are 48 px and the dropdown 44 px.
- **One path for every control:** `chooseWorkZone`, `chooseLocalZone`, `chooseLogTimes` and `undoPendingWorkZone`. Choosing the zone already in use does nothing.
- **Work zone, no shift running:** the shared confirmation, "Change work time zone?", in three lines:
  - from and to, by long name and city;
  - "Today becomes Tue 09/15/26 (was Mon 09/14/26)." or "Today stays …";
  - the §4.4 reassurance about existing logs.

  The zones and the day are bold, built from text nodes (I14). Change goes through `setWorkZonePref`, so a shift started while the dialog was up simply defers it. A toast confirms.

- **Work zone, shift running:** no dialog. The preference is saved, and `#tz-pending-banner` under the progress bar reads "Work time zone changes to Dhaka (UTC+6) when this shift ends · Undo".
  - It is toggled by a class (I13), and drawn from `renderStaticUI()` and once a minute with the clock labels.
  - Undo sets the preference back to the shift's zone.
  - It takes an `!important` sans font, because `.timers-wrapper *` gives everything under the timers the number font with `!important`.
- **Local zone:** applies at once, with no dialog.
- **Work zone synced from another device:** `Sync.applyPrefs` calls `announceAdoptedWorkZone()` after the funnel.
  - The toast reads "Work time zone synced: Tokyo (UTC+9)", or adds ", from the end of this shift" when the change waits.
  - It stays silent when the zone is the same one: a new spelling, or an unset preference made explicit (I7).
- **Guide:** three passages now say where zones are changed. The full rewrite is 5b2.

**Tests.**

- **`probe-tz-ui.js`, 93 checks** (was 51):
  - **the card:** first in the panel, reading both zones; hover help on each row;
  - **the confirmation:**
    - the title is read before anything is clicked;
    - both zones and the new day, with the bold built from text;
    - Cancel changes nothing; Change applies at once, today's date follows, and the toast and the card agree;
    - "Today stays" for a zone with the same date, and no dialog for the zone already in use;
  - **during a shift:**
    - no dialog, and the preference saved and waiting;
    - the banner's text, and its class;
    - Undo, and the hand-over when the shift ends;
    - a zone adopted from another device, waiting behind the banner;
  - **local zone:** applies at once and moves no other stored field (I10); Automatic;
  - **log times:** written, nicknames kept, and shown by the dropdown;
  - **sync toast:** names the zone; silent for the same zone, a new spelling or an unset preference made explicit;
  - **by real mouse and keys, desktop:**
    - each clock opens its own picker;
    - the card's work row, a search for Tokyo and Enter raise the confirmation, whose title is checked before Change is clicked;
    - Change applies, and the settings panel stays open behind the dialog;
    - the log times dropdown works by click;
    - a long city is cut inside the card;
  - **phone, loaded at 390 px:**
    - the Time Zone section sits between Goals and Appearance, with touch-sized rows;
    - a tap lands on a row, which opens the picker over the sheet;
    - a tap on a clock never reaches its button;
    - the banner shows on the timer pane without moving the buttons (390×844 and 375×667), and is hidden off it;
    - the card returns to the panel on the desktop;
  - **geometry as after 5a:** pane ratio 1.498 at 1440 px and 1.709 at 1280 px; the 1149 px bar is one line (38 px).

**Regression, one suite at a time.** 24 suites; 22 green inside the chain.

- `probe-tz-picker` stopped at its first evaluate, before the page had booted.
- `probe-lease-endshift` never started (exit 127, empty log).
- Both passed alone: 176 checks and 30 checks. The laptop was on AC throughout.

**Mutations:** 13 new (237–249), all caught, each on the check written for it, on AC:

- the plan's three for 5b1: the banner shown by an inline display, the confirmation skipped, and `RELOCATIONS` still pointing at the old menu;
- a change during a shift asking anyway, and Undo keeping the pending zone;
- no toast for a synced zone, and a toast for a new spelling;
- the local clock opening the work picker, and the phone's bar reachable by a tap;
- today named in the old zone, the card missing a change, log times dropping the nicknames, and no hover help.

Anchors: 250, 0 misses. `index.html` was restored byte-identical.

**Found while testing:**

- **Chevrons** cost more width than the plan allows (above).
- **`.custom-select { width: 100% }`** comes later in the stylesheet than the dropdown's own width, and squeezed the "Show log times in" label onto four lines. The dropdown's width now uses two classes.
- **The banner drew in the number font** (above).
- **In the harness, no synthesized touch produces a click in headless Chrome**, not even on the Cloud row. Phone taps are checked by where they land, then delivered with `click()`. Switching from desktop to phone metrics without a reload also left a layout viewport about 2800 px tall, so the phone section reloads first.

#### Phase 5b2a results (2026-09-14)

**Committed as** `feat(time): default zones from the device`.

**What changed:**

- **The work zone nobody chose (D5)**, from `derivedWorkZone()`, never stored:
  - Los Angeles on a device that used nodrift before zones (the install verdict from 5a), or when any log or task has no zone;
  - otherwise the zone of the most recently changed record, tasks included, with ties broken by zone id;
  - otherwise the device's own zone.

  It is cached on the verdict, the device zone, `dataVersion` and the two record lists.

  When records arriving move the answer, as when a new device's first sync pulls legacy logs, the funnel runs once. It waits until startup has finished: the logbook loads before the saved state, and an earlier redraw would realign a day that had not been read yet.

- **Clock-in pin:** `pinWorkZoneAtClockIn()` runs wherever a shift gets its zone, in `switchMode` and when an idle lock is resolved as work.
  - It writes the preference, and stamps it as a settings edit at once.
  - It only runs when the default came from the device.
  - A signed-in device skips it until `SyncEngine.lastSyncAt` (a new getter) is set.
- **Local zone:** unset means automatic. The clocks, the card ("Auto · Dhaka") and the picker (Automatic ticked) agree, and choosing Automatic writes nothing.
- **Device zone:** read once through `currentDeviceZone()`. `checkDeviceZone()` refreshes it once a minute, and now also when the app becomes visible, gains focus or is restored from the page cache.
  - A move redraws when the local zone is automatic, or when the work zone is still taken from the device.
- **Copy diagnostics:** the work line says where a default came from ("by default from device").

**For this team nothing changes.** A device with data from before zones resolves Los Angeles from that data and uploads nothing. The iPhone's automatic local zone is Dhaka.

**Tests.**

- **`probe-tz-ui.js`, 113 checks** (was 93):
  - **a brand-new user:** the device's zone for work and local, one clock, nothing written, synced or counted as an edit;
  - **the default from data:** a device from before zones, a logbook holding a log from before zones, and the newest record, tasks included;
  - **records arriving:** legacy logs redraw the page and realign today;
  - **the pin:**
    - written for a brand-new user and stamped as an edit;
    - not written for a device from before zones, or for a zone read from records;
    - held on a signed-in device until its first sync;
    - written when an idle lock is resolved as work;
  - **an unset local zone:** the card and the picker say Automatic; no formatter is created across 200 reads;
  - **the device moving:**
    - a work zone taken from the device follows, with the day and the clock;
    - a pinned work zone stays put;
    - an automatic local zone follows, and catches up on focus;
  - **Pago Pago:** an unset local zone is the device's own;
  - **edge case 33:** after a factory reset the work zone is a brand-new user's again.

  Every earlier section plays this team's device: the reset helper marks it as predating zones, so the earlier numbers stay comparable.

- **Premise updates, no app defect found.** Their first run failed 60 checks across four suites, all resting on "unset means Los Angeles and Dhaka":
  - `harness-tz-model`: three checks now state D5;
  - `harness-tz-core`: section 8 marks the device as predating zones, then restores it;
  - `harness-tz-display`: its zone reset does the same.

**Regression, one suite at a time:** 24 suites, all green inside one chain, on AC throughout. The baseline numbers are unchanged apart from `probe-tz-ui`.

**Mutations:** 13 new (250–262), all caught, each on the check written for it, on AC throughout:

- **the default:** no device default for a brand-new user; a log filed before zones ignored; the install verdict ignored; the default written to storage;
- **the pin:** missing at the first clock-in; applied to a zone read from records; applied before a signed-in device's first sync;
- **moves:** records arriving that move the default without a redraw; a work zone taken from the device ignoring a move of the device;
- **the local zone:** unset still meaning Dhaka; the device's zone read on every call; not rechecked on focus; the picker marking Dhaka for an unset local zone.

Anchors: 263, 0 misses. `index.html` was restored byte-identical.

**Found while testing:** the probe's reload helper returned as soon as sync was ready, which can come before startup has finished. Two mutations that never touch the redraw also failed the "records arriving" check for that reason. The helper now waits for startup to finish.

#### Phase 5b2b results (2026-09-14)

**Committed as** `feat(time): clock labels, the time zones notice and the guide`.

**What changed:**

- **Clock labels** (§4.2's label footer, §4.5). A "Clock labels" row in the Time zones card shows both labels, or one when both clocks share a zone. It opens `#zone-labels-modal`:
  - **the form:**
    - a style dropdown (Abbreviation, Generic name, UTC offset);
    - a nickname field for each clock's zone, or a single field when both clocks share a zone;
    - under each field, its zone and the label an empty field shows;
    - a live preview of the labels.
  - **Done** saves the style and the nicknames under the zones' ids in `tzDisplay`, replacing every spelling of each zone (I7). Nothing is written when nothing changed. Cancel and Escape keep nothing.
  - **A nickname outside the rule** is quoted back as text in the error line, and Done is disabled (I14). The rule is `TimeZones.isNickname`, now shared by the labels, the stored preference's validator and the dialog.
  - **Layout:**
    - the nickname fields carry no `type` attribute, so the bare `input[type="text"]` rule cannot shrink them on the desktop;
    - on the phone the dialog is a bottom sheet with 44 px fields, and no field takes focus when it opens.
- **The time zones notice** (§4.4). `#zone-notice-modal` reads "Time zones are here. Work: Pacific Time (Los Angeles), as before. Local: Dhaka, from this device.", with Review and OK.
  - **When:** only on a device whose install verdict is `"upgrade"`. It is offered at the end of startup, retried every two seconds and whenever the phone shell changes pane, and raised only when `promptSurfaceReady` allows.
  - **Latch:** OK, Review and Escape all latch it on this device (`nodrift_tz_notice_v1`). The latch is never synced, and a factory reset wipes it.
  - **Review** opens the settings panel on the desktop, or the sheet at its Time Zone section on the phone.
- **One rule for when a prompt may appear.** `promptSurfaceReady(except)` and `otherDialogUp(except)` moved out of `SessionLease` to top level. The takeover offer passes `"lease-modal"`, and the notice passes its own id.
- **Escape with nothing focused** now closes the dialog on top through `MODAL_CLOSERS`, the same route as Escape from a field, and falls back to the sweep only when no dialog is up.
- **Guide:**
  - a new "Time zones" section in the Settings tab: the two clocks, what each zone decides, where to change them, changing the work zone, log times, clock labels, and a new device;
  - the old time zone bullet is gone from the list above it, which is now headed "Theme and goal presets";
  - the phone sheet passage mentions clock labels and log times.
- **Hover help** for the Clock labels row.

**Tests.**

- **`probe-tz-ui.js`, 146 checks** (was 113):
  - **the labels dialog:**
    - the card row and what it shows;
    - the fields, hints and preview;
    - typing and a style change each preview at once and save nothing;
    - Done saves under the zone's id, and the clocks and the card follow, as a settings edit;
    - a nickname belongs to its zone;
    - reopening shows what was saved;
    - Done with nothing changed writes and redraws nothing;
    - Cancel keeps nothing, and an emptied field removes the nickname;
    - `<img>` is quoted back as text and cannot be saved;
    - one field for one zone;
    - another spelling of a zone is found, and leaves one entry (I7);
    - the shared nickname rule;
  - **the notice:**
    - never on a fresh install;
    - held behind another dialog, then shown;
    - §4.4's wording, with bold built from text;
    - dismissing latches it without touching a synced preference, and a latched notice is not offered again;
    - a factory reset forgets the latch;
    - one copy of the surface rule;
  - **by hand on the desktop:**
    - the row opens the dialog over the settings panel, with the work field focused and full height;
    - typing and Enter save;
    - the style dropdown works by click;
    - Escape closes the dialog and leaves the panel open;
    - the notice appears by itself at startup;
    - OK latches it across a reload;
    - Escape dismisses it with nothing focused;
    - Review opens the Time zones card;
  - **on the phone:**
    - the notice waits for the timer tab and appears the moment it is in front;
    - Review opens the sheet at Time Zone;
    - the labels dialog fits once it has risen into place, with touch-sized fields and no keyboard;
    - the sheet's Time Zone section now has four rows.
- **Harness:** the two lease-prompt mutations follow the moved surface rule, and mutation 249's pattern includes the new row.

**Regression, one suite at a time:** 24 suites, on AC throughout, all at the numbers before 5b2b apart from `probe-tz-ui`. `harness-signin-render` failed "signing in to an empty account uploads nothing" inside the chain, the same check as in earlier chains, and passed 12 of 12 alone. `harness-lease-prompt` passed 23 of 23 with the surface rule moved out of `SessionLease`.

**Mutations:** 15 new (263–277), all caught, each on the check written for it, on AC throughout:

- **the labels dialog:**
  - a bad nickname quoted back as markup (the plan's "nickname via `innerHTML`");
  - the local preview waiting for something else to redraw it;
  - the local nickname saved on the work zone;
  - Done writing when nothing changed;
  - a bad nickname closing the dialog;
  - two spellings of a zone keeping two nicknames;
  - no hover help for the row;
- **the notice:**
  - shown on a fresh install;
  - dismissing it without a latch;
  - shown over another dialog;
  - never retried by the phone shell;
  - never offered at startup;
  - a factory reset keeping the latch;
  - Review only dismissing it;
- **Escape** with nothing focused skipping the dialog on top.

Anchors: 278, 0 misses. `index.html` was restored byte-identical.

**Found while testing:**

- **Escape with nothing focused** only ran the sweep, which names dialogs one by one and knew neither new dialog. The notice has no field to focus, so Escape could never close it. Fixed at the route (above), with a mutation.
- **A phone dialog rises into place.** Measured at once, the labels sheet was still below the screen. Settled, it fits at 390×844 and at 375×667.
- **A style change redraws the whole preview**, which would hide a nickname field that never redraws it by itself. The probe reads the preview between the two.
- **Rewriting identical JSON leaves storage and the preference fingerprint looking untouched, but still redraws.** The unchanged-Done check also compares `TimeZones.version`.
- **Only a profile that held data before its first boot of the zone build is due the notice.** Every other suite starts on an empty profile and never sees it.

### Phase 6 — Sync hardening, multi-device, iPhone

**Goal:** prove §3.8 against the live database and the real device.

- Live suites, one at a time: `harness-phase8.js` (three devices: zone prefs parity), `harness-handoff.js` (+ row 30), `harness-signin-render.js` (+ rows 31–32), `harness-wipe.js` (zone keys wiped), `harness-realtime.js`, `harness-lease.js`, `harness-lease-prompt.js`, `harness-devices.js`, `harness-import.js`, `probe-beat-cost.js` (1.00 per owner beat, ceiling unchanged), `probe-live-gate.js`, `probe-shift-rewind.js`.
- Old-client check: serve `git show 9181afa:index.html` as device B beside the new build as device A on the same account; B must not throw, must keep `tz` on records it edits, and A must render B's edits correctly.
- **iPhone checklist for the user** (home-screen PWA, signed in): upgrade mid-shift; change local zone; change work zone during a shift and watch it apply at EOD; lock across midnight in a non-LA work zone (row 40); change the OS time zone and resume; read Copy diagnostics.

**Exit:** all live suites green; user confirms the checklist.

**Commit:** test-only changes live in the ignored harness; commit any app fixes found as `fix(time): …`.

#### Phase 6a results (2026-09-15)

**Committed as** `fix(time): a goal the app works out is not a settings edit`.

**Baseline.** The live suites ran one at a time on the Phase 5 tree, starting at 02:30 Dhaka:

- green: handoff 22, signin-render 12, wipe 18, realtime 16, lease 20, lease-prompt 23, devices 29, import 9, shift-rewind 13;
- `harness-phase8` failed 3 of 13, `probe-beat-cost` 8 of 9, and `probe-live-gate` stopped in its setup.

Every Phase 5b2 run had happened around 21:00 Dhaka, when Dhaka and Los Angeles share a date. Between 00:00 and 13:00 Dhaka they do not.

**Found: a new device could replace the account's settings with its own defaults.** A diagnostic logged every preference write and every `sync_session` body on three devices, and showed this:

1. A fresh device takes its day from its own zone (D5) and fills in that day's goal. The goal counts up through the week, so a Tuesday with nothing logged on Monday asks 16 h.
2. Its first sync pulls the account's logs. Logs from before zones make the work zone Los Angeles, the day moves back to Monday, and `autoPopulateDailyGoal` rewrites the goal to 8 h.
3. The next beat's preference fingerprint read that rewrite as the user's edit. It stamped the device's own settings and uploaded them: idle limit 60, and no theme, work zone, presets or leave allowances.
4. That upload was newer than the account's settings, so the server replaced them and every device adopted the defaults (I11, §5 row 31).

This is not only a zone problem. Any automatic goal rewrite between startup and a device's first look at the account's settings does the same. One example is a fresh sign-in on a Wednesday to an account with logs from earlier that week.

Every automatic rewrite on a device that already held the account's settings was uploaded too. That did no harm to the data, but cost a settings upload and a realtime message each time.

**Fix (decided with the user: an automatic goal is not an edit).**

- `Sync.notePrefsDerived(write)` runs the write, then re-takes the preference baseline. It does not re-take it when a real edit was already waiting to be sent; that edit still goes, carrying the new goal with it.
- `autoPopulateDailyGoal` writes the goal through it. A goal the user types or picks still syncs.
- A leave day arriving by sync now works out the goal again, as adding one on the device always did. Pulled logs already did this, through `saveLogs`.

**Tests.**

- **`probe-tz-ui.js`, 149 checks** (was 146). Dates in the week of 03/15/27, so the result does not depend on the day it runs:
  - an automatic rewrite stamps and queues nothing;
  - a goal picked by the user is still an edit;
  - an edit already waiting survives an automatic rewrite.
- **`harness-signin-render.js`, 16 checks** (was 12):
  - **Section 4, row 31:** a fresh device in a zone whose date differs from Los Angeles' signs in. It resolves Los Angeles and its day and goal move. The server's settings and their stamp stay unchanged, and the device takes them. The zone (Kiritimati or Pago Pago) is chosen at run time. On a Los Angeles weekend from 04:00, when every date's goal is the same, the section prints SKIP.
  - **With the automatic goal off,** a leave day arriving by sync still redraws insights.
- **`harness-phase8.js`, 14 checks** (was 13):
  - its devices now run on Los Angeles' date, since the suite is about parity;
  - a leave day arriving by sync recomputes that device's goal.
- Before the fix, the row 31, goal and leave recompute checks each failed for the reason written for them. After it, all pass.

**Harness fixes, no app defect:**

- `probe-live-gate.js` deleted every device row without clearing `Sync.deviceRegisteredFor`. That is the trap fixed in three other suites in `26bd02b`, and here the device signed itself out. It passes 12 of 12 after the fix.
- `probe-beat-cost.js`'s one socket-driven beat was this defect. Its fixture's shift moved the day, and the goal rewrite uploaded the settings. It passes 9 of 9 after the fix.

**Old-client check** (`probe-tz-oldclient.js`, new, 8 checks, live). Device A runs this build and device B the build from `9181afa`, both on the test account:

- B pulls records carrying a zone, keeps the field and throws nothing.
- B edits a Los Angeles record through its own edit dialog. The record keeps its zone, instants and date, and A shows the same In and Out.
- B's edit of a Dhaka record keeps the zone.
- A shift crosses both ways: B mirrors a shift A started, and A adopts a shift B authored and keeps Los Angeles for it.
- B's settings upload leaves A's work zone, local zone and clock labels in place.

Two things were measured that no change to this build can reach (§3.8, "Older cached client"):

- **A non-Los Angeles record saved on the old build moves.** Its dialog shows the stored times (09:00 AM – 05:00 PM, Dhaka) and reads them in Los Angeles. Saving only a note moved the instants 13 h, and A now shows 10:00 PM – 06:00 AM. Every record this team holds is Los Angeles, and the service worker updates an old client on its next launch.
- **The old build's settings blob has no zone preferences,** so its upload replaces the server's copy without them. Devices that already hold them keep them, because an absent key never deletes. A device signing in for the first time before a new-build device next changes a preference works out its zones from the records, and has no nicknames.

**Regression**, one suite at a time, on AC throughout (03:03–03:15):

- **The 24 suites of the time zone chain** are green, at the numbers from before this phase apart from `probe-tz-ui` 149, `harness-signin-render` 15 (16 with the check added later), `harness-phase8` 14 and `probe-beat-cost` 9.
- **The other live suites:** `harness-lease` 20, `harness-devices` 29, `probe-live-gate` 12, `probe-tz-oldclient` 8.
- **`harness-realtime`** failed 2 of 16 inside the chain, on the timing pair already known ("a row change arrives over the socket", "and a second one nudges the lease"). It passed 16 of 16 alone.
- **`harness-signin-render`'s view-prune check** ("the next launch keeps the user's and drops the furniture") failed in three runs today, one of them on the Phase 5 tree, and passed alone. It is the timing flake already recorded for it.

**Mutations:** 4 new (278–281), each caught on the check written for it, on AC:

- an automatic goal uploaded as an edit (`probe-tz-ui`);
- an automatic rewrite swallowing an edit waiting to be sent (`probe-tz-ui`).
  - It escaped at first, because the check's waiting edit was a goal picked from the presets. Picking a goal turns the automatic goal off, so the rewrite never ran.
  - The waiting edit is now the theme, and the check asserts that the goal moved.
- a leave day arriving by sync leaving the goal alone (`harness-phase8`);
- row 31: a fresh device uploading its automatic goal over the account (`harness-signin-render`).

**Mutation 84** ("let the insights tab redraw itself after a merge"):

1. It first missed its anchor, because the new recompute sits where it matched. It was re-anchored with the same intent.
2. Graded, it then escaped.
3. A controlled revert put the Phase 5 `index.html` back with only that mutation applied, and the suite failed there. So the escape came from the fix: while the automatic goal is on, the goal recompute on a pulled leave day redraws insights too.
4. With the automatic goal off, the merge's own `renderInsights()` is still the only redraw. The check added for that catches mutation 84.

Anchors: 282, 0 misses. `index.html` was restored byte-identical after every run.

#### Phase 6b results (2026-09-15)

**No app change.** Rows 29, 30, 34 and 40, and the wipe of the zone preferences, were checked against the build committed in 6a (`index.html` md5 `79c372ee`). All behave as §3.5 and §3.8 say.

**Tests.**

- **`harness-tz-sync.js`**: new, 12 checks, live, two devices with the device zone Asia/Dhaka.
  - **Row 29.** B runs a shift in Los Angeles, and A changes the work zone to Kolkata.
    - B adopts the preference, but its shift keeps Los Angeles (I4).
    - The banner names Kolkata, and the toast reads "Work time zone synced: Kolkata (UTC+5:30), from the end of this shift".
    - Today's date does not move.
    - B files the shift in Los Angeles, then works in Kolkata.
  - **Row 30.** A runs a shift in Kolkata, and B's preference becomes Los Angeles.
    - B mirrors the shift in Kolkata and shows the change waiting.
    - B takes the shift over, and its rollover works in Kolkata.
    - The record B files carries Kolkata and Kolkata's date: 09/15/26, while Los Angeles was still on 09/14.
    - Afterwards, B's work zone is its own preference.
  - **Row 34.** B holds Kolkata in Chrome's spelling (`Asia/Calcutta`) for both clocks.
    - A sends Safari's spelling (`Asia/Kolkata`). B stores it with no zone toast and no banner, and its clocks still read as one zone.
    - A shift started under Safari's spelling shows nothing pending on B.
  - End of day goes through the app's own `executeSubmit`. It refuses a shift with no whole second of work, so each check waits for two seconds of work first.
- **`harness-tz-core.js`**: 85 checks (was 80), no account. This covers **row 40**.
  - The same story is set up in Los Angeles and in Dhaka, against each zone's own midnight: clocked in three hours before it, suspended two hours before it, and woken now with yesterday still the active day.
  - The setup and the wake run in one synchronous block, through the app's `handleWakeUpRecovery`, so the page's tick cannot get in first.
  - In both zones the wake raises the system pause prompt before any rollover: idle from the suspend, one hour banked, and yesterday still active.
  - After Discard, both zones file one record on yesterday's date in their own zone, and the two records have the same shape.
- **`harness-wipe.js`**: 18 checks.
  - The settings the wipe must remove now include a work zone and clock labels. The precondition requires them to be in the server's copy first.
  - All 18 pass: 12 keys seeded with the zone preferences included, and none left after the wipe.
  - A device's own zone keys, the recent zones, the install verdict and the notice latch are graded in `probe-tz-ui.js`.

**Found, not changed.** This happens the same way in Los Angeles, so it is not zone work.

- It follows a suspend across midnight that the user resolves as Discard.
- The rollover then files, on yesterday's date, a record whose window runs from now to an hour from now, so its logout is in the future.
- That record holds the hour banked before the suspend.

**Mutations:** 4 new (282–285), each caught on the check written for it, on AC:

- a mirror ignoring the zone its shift started in (row 30);
- a zone synced mid-shift applying at once (row 29);
- another spelling of the shift's zone reading as a pending change (row 34);
- the rollover after a wake working in Los Angeles (row 40, also caught by the Honolulu and Kolkata rollover checks).

There is no mutation for "a zone toast when another device's spelling arrives". On Chrome both sides are already in the engine's one spelling, so no Chrome suite could tell `TimeZones.same` from `===` there.

Anchors: 286, 0 misses. `index.html` was restored byte-identical.

#### Phase 6c results — iPhone checklist (2026-09-15)

**No app change.** The user ran the checklist on their iPhone, in the home-screen app, signed in to their own account. The build was the pushed one (`index.html` md5 `79c372ee`), checked on the production site first.

1. **Load the new version** (close the app fully and reopen it): passed.
2. **The one-time notice** on a device that used nodrift before zones, with Review opening the Time Zone sheet: passed.
3. **The clocks** read PDT and BST, and the finish time is in the phone's time: passed.
4. **Local zone** set to Tokyo, then back to Automatic: passed.
5. **Work zone change:** the "Change work time zone?" confirmation appeared with no shift running: passed.
6. **The phone's own time zone** changed in iOS Settings: partly.
   - The phone was set to Tokyo with the app in the background. Back in the app, the second clock still read BST, and it read Tokyo only after the app was closed fully and reopened.
   - Setting the phone back to automatic showed in the app at once, with no relaunch.
   - The cause is not established. The check on return may run before iOS tells the web engine, in which case the check once a minute would catch it, or WebKit may keep the old zone until the app restarts. Headless Chrome's zone override cannot reproduce either.
   - The user accepts it as minor. No change; §3.5 notes it.
7. **Clock labels:** as designed.
   - The user had also backed up, used "Sign out & erase this device", and started again. The local clock then read "UTC+6", not BST, with the style still Abbreviation.
   - Dhaka has no abbreviation in `Intl`, so its offset shows (§4.5).
   - The BST nickname is seeded only on a device that held data from before zones (D3). A seed is worked out, not chosen, so it is never uploaded (I11), and an erased device starts as a new install.
   - The remedy is to type BST under Clock labels → Local clock nickname → Done. That is the user's choice, so it syncs with the clock labels and survives an erase or a new device.
8. **Copy diagnostics,** after that fresh sign-in: passed.
   - It shows 139 rows applied from the account, 0 pushed, and no push ever. A new device signing in to the real account uploaded nothing, so the 6a fix holds there.
   - Work zone America/Los_Angeles, from the user's preference, with no shift running. Local zone Asia/Dhaka, automatic, following the phone.
9. **Overnight lock** (optional): skipped. Row 40 is graded without a device in `harness-tz-core.js` (6b).

**Exit.** All live suites are green (6a, 6b) and the user has confirmed the checklist, so Phase 6 is done. The Discard record found in 6b is fixed below, on its own.

#### Follow-up: a pause answered after midnight (2026-09-15)

**Committed as** `fix(idle): a pause answered after midnight is applied to the new day`. Found in 6b; not zone work.

**The story.** A shift is clocked in at 21:00 work time, the phone locks at 22:00, and the user opens nodrift the next day. The wake raises the system pause prompt at once, and the page's next tick, about a second later, rolls the day over.

**Measured on both builds** with `probe-discard-midnight.js` (new, no account), which runs the build from `9181afa` beside this one. All six answers were identical on the two builds.

- **Answered after the tick,** which is what a user who reads the prompt gets and what a cold boot always gets: yesterday is filed from 21:00 to 00:00 with the one hour of work. The answer covers only the time after midnight. After Discard, today's shift showed In 00:00.
- **Answered before the tick:**
  - Discard filed yesterday's hour stamped from the answer to an hour after it, and today's timer counted from midnight, so the whole night showed as work.
  - Work filed yesterday with the time after midnight in it, then counted that time again on today's timer. Break did the same with break.
- **Answered while a rollover was still saving,** today's shift was left with no clock-in time.

**Cause.** `resolveIdle` applied the answer on the active day even when that day had ended. The rollover then treated the resumed shift as if it had run up to midnight.

**Fix (decided with the user).**

- The answer belongs to the day it is given on. `resolveIdle` first rolls a day that has ended over, still locked, and only then applies the answer. Every order now gives the "after the tick" result.
- A rollover already in flight is waited for. `checkMidnightReset` hands a second caller a promise that settles when the running rollover finishes, where it used to return at once.
- **Discard:** when the rollover moved the login and the pause's start to today's midnight and nothing was tracked, today's shift starts at the answer, not at 00:00. A same-day Discard is unchanged.
- **Work and Break** still cover only today's part (the user's choice). The part of the pause before midnight is still not offered to yesterday.
- Only a pause can be resolved. A second tap, or a prompt still on screen with no pause behind it, puts the prompt away and changes nothing. Before, it stopped the shift.

**Tests.**

- **`harness-idle-midnight.js`**, new, 24 checks, no account.
  - Discard, Work and Break, each answered at once, after the tick and during a rollover; Discard answered twice at once; three same-day controls.
  - The work zone is chosen at run time: Los Angeles or Dhaka, whichever day is at least 90 minutes old.
  - On the unmodified tree 10 checks failed, each for the reason written for it, and the same-day controls passed.
- **`harness-tz-core.js`**, 85 checks. Row 40's "once resolved, yesterday's work is filed" now requires exactly one record, from three hours before midnight to midnight. It failed on the unmodified tree in both zones.
- **`probe-tz-ui.js`**, 149 checks. The idle clock-in check now awaits `resolveIdle`, which can finish after an await.

**Regression**, one suite at a time, on AC throughout (08:38–08:48). `run-tz-regression.sh` now also runs `harness-tz-sync.js` and `harness-idle-midnight.js`, 26 suites in all.

- 24 are green inside the chain, at the numbers from before this fix, plus `harness-idle-midnight` 24.
- `harness-signin-render` failed 2 of 16 inside the chain and `harness-phase8` 1 of 14 ("a third device reproduces the first"). Both passed alone, at 16 and 14. The signin-render pair most likely came from rows a stopped harness run had left on the test account, since that suite runs before `probe-shift-rewind` clears them.

**Mutations:** 7 new (286–292), each caught on the check written for it, on AC:

- the answer applied before the rollover (`harness-idle-midnight`, and row 40 in `harness-tz-core`);
- a rollover in flight not waited for;
- today's shift keeping the midnight login after Discard;
- the Discard rule widened to any pause with nothing banked, caught by the same-day control;
- a second answer still acting after the wait;
- an answer with no pause up still switching the shift.

Anchors: 293, 0 misses. `index.html` was restored byte-identical.

### Phase 7 — Cleanup, docs, release

- Remove `getPSTDate`/`getPSTDateObj` aliases; update every harness reference (`harness-handoff.js:198`, `harness-phase6.js:299–305`, `harness-progress.js:95`, `probe-backup-and-leave.js`, `probe-leave-rows.js`, `tests-auth.js`, `tests-phase5.js`) and the mutation anchors.
- `docs/SYNC-BLUEPRINT.md`: a section on `sessionTz`, record `tz`, zone prefs and I3/I4/I11.
- README feature list; memory update.
- Full no-account + live sweep and the full mutation run.

**Commit:** `chore(time): retire the PST names` and `docs: time zones`.

#### Phase 7 results (2026-09-15)

**Committed as** `d93726f` `chore(time): retire the PST names` (`index.html` alone), then this docs commit.

**Scope.**

- The `getPSTDate` / `getPSTDateObj` aliases and their comment are gone.
- Decided with the user: the seven local names that still said PST were renamed too, although they already read the work zone. They are `nowPST`→`nowWork`, `nowPSTObj`→`nowWorkObj`, `todayPST`→`todayWork`, `todayPSTDay`→`todayWorkDay`, `_cachedCurrentDatePST`→`_cachedCurrentWorkDate`, `currentDatePST`→`currentWorkDate` and `nextDatePST`→`nextWorkDate` (71 identifiers), plus one comment ("today's work date"). Comments about the PST abbreviation itself stay.
- `index.html` +74/−78. Prettier reflowed two lines: the `while (` condition in `checkMidnightReset`, and a `targetDate = new Date(` in the second date parser. No behaviour change.
- `README.md`: a "Work & Local Time Zones" feature bullet, and "Midnight Rollover" now says it is the work time zone's midnight.
- `docs/SYNC-BLUEPRINT.md`: a new §15 "Time zones", with pointers at the two places that named `getPSTDate()`. It covers record `tz` and I3, `sessionTz` and I4, the zone preferences and their validation, why nothing the app works out is uploaded (I11), backup, import and wipe, and older clients.

**Tests.**

- Seven harness files call `getWorkDate()` now: `harness-handoff`, `harness-progress`, `harness-phase6`, `probe-backup-and-leave`, `probe-leave-rows`, `tests-auth` and `tests-phase5`. `probe-discard-midnight.js` keeps its one call, which only runs on the build from `9181afa`.
- `harness-tz-core.js`, 86 checks. The static check that allowed the two aliases became two: "the old PST date names are gone from the app, aliases included" and "no name in the app has PST in it" (any identifier with PST joined into it). On the unmodified tree exactly those two failed.

**Baseline on the unmodified tree** (`92acc31`, on AC): the 14 live suites green at their usual numbers; `harness-phase6` 21, `harness.js` 80, `harness-progress` 25, `harness-tz-core` 85, `probe-leave-rows` 12, `probe-backup-and-leave` 26.

**Exit sweep**, one suite at a time, on AC (09:18–09:36): the 26-suite regression chain, the 14 live suites and `harness-phase6` (21). All were green at the baseline numbers except four misses inside the chain, each green alone right after:

- `probe-tz-picker` "the first open at 4x paints within 100 ms" (258.8 ms and 146.6 ms under load): 176/176 alone.
- `harness-phase8` exited one second after launching Chrome, before any check ran: 14/14 alone.
- `harness-handoff` 2 and `harness-signin-render` 1 (the known view-prune timing check), in the two live suites that followed: 22/22 and 16/16 alone.

**Mutations.** Two new (293–294), each caught on the check written for it: an alias put back, and a local named `nowPST` put back.

**The full mutation run**, all 295 on AC (09:40–15:47, paused while the laptop was needed): 286 caught, 9 not. Each of the 9 was graded again alone, with the full output kept, on this tree and on `92acc31`. All 9 graded the same on both, so none comes from this phase.

- **Four were caught alone.** The full run had graded them on a broken run:
  - `harness-phase6` and `probe-live-gate` crashed mid-run.
  - `harness-phase8`'s baseline was red on its known "a third device reproduces the first" check.
  - `harness-signin-render`'s baseline was red because the suite before it had left rows on the test account.
- **Five were real gaps in the tests**, fixed with the user in the harness only; the app is unchanged:
  - **The details panel hidden** (`harness-phase7`). The check read the inline style, but since `26bd02b` the stylesheet lays out the grid, so a rule that hides it was invisible. It reads the computed style now.
  - **`getWorkDate` cached on the second alone** (`harness-tz-core`). The check primed the cache in the device's own zone. Since Phase 5b2a that zone can share a date with the zone it switches to, and at 11:30 in Dhaka it did. It primes in Los Angeles now, so the dates always differ.
  - **A forced takeover pushing on a stale belief in ownership** (`harness-handoff`). No existing check had a device that still believed it held the lease. New check: B holds the lease, A takes it back while B hears nothing, and B forces with its screen emptied. The forced claim must carry no session, and both devices keep the shift.
  - **Adoption keeping the device's own idleness** (`harness-handoff`). `lastActivity` is not a session field, and the device had been driven moments before, so the check could not fail. New check: B's last activity is set three hours back before it picks the shift up, and it must not idle-lock.
  - **Reconnecting after a refused subscription** (`harness-realtime`). Its checks only ran on a server without realtime, which no longer exists. New section 4b rewrites the subscription answer in the page into a refusal. The socket must be retired, and the network coming back must not reopen it.
- **Each fixed suite passed without its mutation and failed with it**, on the check written for it:
  - `harness-phase7` on "the details section is on screen".
  - `harness-tz-core` on "getWorkDate follows a change of zone within the same second", in both device zones.
  - `harness-handoff`, 24 checks now, on "a device that forces while it still believes it holds the lease takes over without wiping it" (the forced claim carried a session) and on "a device idle for hours picks up the shift and does not idle-lock on it" (B idle-locked).
  - `harness-realtime`, 19 checks now, on "and the network coming back does not reconnect into a refusal".
- **Placement.** The forced-takeover check first sat right after section 5's opening check. There it made the next check, "a follower refuses a corrupt anchor rather than showing days", fail in two of three runs. It runs last in the section now, just before the devices are reset, and that check passed in all five runs since.
- **The 35 other mutations on these four suites** were graded again after the fixes (16:26–16:41, on AC). All 35 were caught, so no fix hid an existing catch.

Anchors: 295, 0 misses. `index.html` was restored byte-identical after every run.

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
