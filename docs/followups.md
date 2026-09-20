# Follow-ups: work week, clock and date formats, re-filing records

> **Status:** plan approved by the user on 2026-09-15, including every proposed default in §10. Phases W0 (measurements), W1 (the `WorkWeek` module, behaviour-identical apart from two differences the user chose), W2 (the schedule, its history and the generalised rules), W3 (the settings card, the wording, the bar and the guide) and W4 (live multi-device, the iPhone pass, and decision W16) are done, and W0–W4 are **deployed** (`676976f`, 2026-09-19); Phase C1 (the 24-hour clock) and Phase D1 (the date order) are done and **deployed** (`add47ce`, 2026-09-20); Phase Z1 (re-filing a record in another zone) is done and not yet deployed; Phase R is next.
> **Baseline commit:** `0ba1bd6` (all line numbers below refer to it and WILL drift — re-grep before editing).
> **Rule:** one phase at a time. A phase starts only when the previous phase's exit criteria are green and committed.
> **Origin:** the candidate follow-ups in §9 of `docs/implement.md`. "More than two clocks; per-client zones" was dropped by the user (§11 here).

| Phase | Title                                                             | Touches data?    | Needs live account? | Size              | State   |
| ----- | ----------------------------------------------------------------- | ---------------- | ------------------- | ----------------- | ------- |
| W0    | Work week groundwork: golden master, probes, audit                | no               | one probe           | S–M               | done    |
| W1    | `WorkWeek` core + behaviour-identical refactor                    | no               | regression only     | L (split W1a/W1b) | done    |
| W2    | The schedule: preference, history, the generalised rules          | prefs            | stub / fake server  | L (split W2a/W2b) | done    |
| W3    | Work week UI: settings card, phone sheet, bar, labels, guide      | prefs            | no                  | M–L (split W3a/b) | done    |
| W4    | Work week sync hardening, multi-device, iPhone                    | no               | **yes**             | M                 | done    |
| C1    | 24-hour clock                                                     | prefs            | no                  | M                 | done    |
| D1    | Date order: MM/DD, DD/MM, YYYY-MM-DD                              | prefs            | no                  | M–L (split D1a/b) | done    |
| Z1    | Re-filing a record in another time zone                           | yes (edit paths) | no                  | M (split Z1a/b)   | done    |
| R     | Release: full mutation run, README, guide sweep, iPhone checklist | no               | full sweep          | S                 | planned |

---

## 0. How to execute a phase (read this every session)

1. Read §2 (vocabulary), §3 (invariants) and the phase's own section. Its feature section (§4, §5 or §6) is the design it implements.
2. **Re-grep every call site the phase names.** Line numbers here are from `0ba1bd6`.
3. Run the phase's regression list against the **unmodified** tree first and write the numbers down. A mutation graded against an already-red suite grades nothing.
4. Separate concerns **before** editing (git reset is blocked here; commits cannot be split afterwards).
5. Implement. `npx --no-install prettier --write index.html`, then `node nodrift-harness/mutation-anchors.js` (0 misses).
6. Run the phase's new tests, then the regression list, **one suite at a time** (they share ports and the test account). Re-run an in-chain failure alone before believing it.
7. Run the phase's mutations with a baseline, **on AC power with the laptop idle**. Every new mutation must be caught by a check that was newly red. Never `require('./mutation-test.js')` to check it; use `node --check` and `mutation-anchors.js`.
8. Commit `index.html` **alone**, then the docs. Every commit must be deploy-safe (main deploys to Vercel). Update the status table. **Never push without the user's word.**
9. Anything the user checks on the iPhone is written as exact tap-by-tap steps, with what they should see and how to undo it.
10. **Save memory after every step** (compactions happen mid-phase).
11. **Stop condition:** if an exit criterion cannot be met, stop and report. Do not start the next phase to "come back to it".

---

## 1. Goal

Four features, each correct for anyone and invisible to a user who changes nothing:

- **Work week** — a person chooses which days they work (any mix of the seven) and which day their week starts. The weekly goal is shared equally across the work days. Work on a day off has its own goal and, if they choose, counts toward the week. A shortfall is made up the next work day (today's way) or spread over the rest of the week. Changing any of this never rewrites a past week.
- **24-hour clock** — a 12-hour / 24-hour switch for every time shown on screen. Typing accepts both forms. Exports stay 12-hour.
- **Date order** — MM/DD/YY, DD/MM/YY or YYYY-MM-DD for every date shown, typed and exported. Stored data and backups stay `MM/DD/YY`.
- **Re-filing a record** — the edit dialog can move a shift or task to another time zone, keeping either the real moments or the times as written, with a preview.

**Defaults are today.** An existing user who touches no new setting sees every number, word and export exactly as at `0ba1bd6`, except the fixes this document names (the weekly-goal history, §4.4).

---

## 2. Vocabulary (use these words in code comments and commits)

| Term                   | Meaning                                                                                                                                             | Where it lives                                  |
| ---------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------- |
| **Work day**           | A weekday (0 = Sunday … 6 = Saturday, the `getUTCDay` numbering) the schedule says the person works.                                                | `workWeek.workDays`                             |
| **Day off**            | Any other weekday. Replaces "weekend" in code and, from W3, in the UI (proposed P-W11).                                                             | derived                                         |
| **Schedule**           | The values that decide goals for a date: weekly goal hours, work days, week start, day-off goal, day-off counts, catch-up mode.                     | current: `state.weeklyGoalHours` + `workWeek`   |
| **Archived schedule**  | A schedule that applied up to and including a business date (`until`), kept so past weeks keep their own targets.                                   | `workWeek.history[]`                            |
| **Effective schedule** | For a date D: the first archived schedule with `until ≥ D`, otherwise the current one. **The only schedule goal logic may use.**                    | `WorkWeek.scheduleFor(dateKey)`                 |
| **Week start**         | The weekday a week begins on: Monday (1), Sunday (0) or Saturday (6).                                                                               | `workWeek.weekStart`                            |
| **Week**               | A run of consecutive business dates decided by `WorkWeek.weekOf`. Normally 7 days; a **transition week** (1–6 days) follows a week-start change.    | derived                                         |
| **Work-day goal**      | `round(round(weeklyGoalHours × 3600) / workDays.length)` — today's `getStandardDayGoalSec` with 5 replaced by the count.                            | `WorkWeek.dayGoalSec`                           |
| **Day-off goal**       | The goal of a day off: a fixed number of hours once the user types one, otherwise three quarters of the work-day goal (today's ratio). 0 = no goal. | `workWeek.dayOffGoalHours` (`null` = automatic) |
| **Week target**        | The sum of the work-day goals of a week's work days that are not leave. Day-off goals never add to it.                                              | `WorkWeek.weekTargetSec`                        |
| **Counted work**       | Work on work days, plus work on days off when `dayOffCounts` is on.                                                                                 | `WorkWeek.countsToward(dateKey)`                |
| **Catch-up mode**      | `"next"`: the next work day absorbs the whole shortfall (today). `"spread"`: it is shared across the remaining work days.                           | `workWeek.catchUp`                              |
| **Clock format**       | `"12h"` or `"24h"`. Display only.                                                                                                                   | pref `clockFormat`                              |
| **Date order**         | `"mdy"`, `"dmy"` or `"ymd"`. Display, typing and exports; never storage.                                                                            | pref `dateOrder`                                |
| **Stored form**        | What records, sync and backups hold: `MM/DD/YY` dates and `09:00:00 AM` time strings. **Never changes.**                                            | `log.date`, `log.login`, …                      |
| **Re-file**            | An explicit edit that changes a record's zone (`record.tz`), in one of two modes: **keep moments** or **keep written times**.                       | the edit dialogs                                |

---

## 3. Invariants (every phase must preserve all of them)

The time zone invariants **I1–I14 of `docs/implement.md` §3.2 still hold** and are not repeated. These are added:

- **F1 — Stored forms never change.** `MM/DD/YY` business dates, `09:00:00 AM` stored time strings, instants, leave ids, `activeDate`, `dailyAnchorMap` keys, chunk keys, sync payloads and JSON backups keep their exact shape whatever the clock format or date order. A display string never reaches a stored field; a typed value is converted to the stored form before it is saved.
- **F2 — Defaults are today, and a default is never uploaded.** An absent preference means today's behaviour, resolved in memory. Nothing is written to storage or the settings blob until the user changes something (I11). Diffing storage before and after boot, sign-in and a day's rollover shows no new key.
- **F3 — One resolver per concept.** Goal and week logic asks `WorkWeek`; time display asks `clockStyle()`; date display asks `formatDateKey()`; typed dates go through `parseTypedDate()`. Nothing else reads the preference keys, loops `for (i < 5)`, tests `getUTCDay() === 0 || === 6`, snaps to Monday, or hardcodes an AM/PM or MM/DD shape.
- **F4 — Every new preference is validated at every trust boundary** (storage, sync blob, import file) before use. An invalid value is skipped whole, the previous value kept, and nothing throws inside the tick.
- **F5 — A schedule change never moves the past.** A week that ended before the change keeps the schedule it had: its target, its bar, its "achieved / incomplete". A record's locked `dayGoal` never changes because of a setting.
- **F6 — A schedule change never retargets a running shift.** `shiftStartGoalSec` stays; the new schedule applies the next time the goal is populated.
- **F7 — Week boundaries are decided in one place.** The analytics worker stops computing weeks; it groups by business date, and `WorkWeek.weekOf` assembles weeks.
- **F8 — One invalidation funnel per preference family.** A schedule change goes through `onScheduleChanged()`; a clock or date format change through `onDisplayFormatChanged()`. Each bumps a version that every cache key and row key includes (the logbook row key, `insightsCacheKey`, the heatmap), then redraws.
- **F9 — Exports are explicit.** CSV, email and copy code call export formatters (`exportTime`, `exportDate`) and never the screen formatters, so a screen setting reaches an export only where §5/§6 say it does.
- **F10 — Older builds lose nothing and break nothing.** A build from `0ba1bd6` ignores the new preference keys, but when it wins a settings race the account's copy loses them (measured in W0). A new build that adopts settings missing a preference it holds therefore sends its own copy back on its next beat (W2a, decision W11); W4 proves it live.

---

## 4. Work week

### 4.1 What exists today (audit at `0ba1bd6`)

**Constants and the one number.** `WEEKLY_GOAL_DEFAULT_HOURS = 40`, `WEEKLY_GOAL_WORKDAYS = 5` (16390–16391), `WEEKEND_GOAL_RATIO = 0.75` (16398). `getWeeklyGoalSec()` reads `state.weeklyGoalHours` (16400); `getStandardDayGoalSec()` = `round(weekly / 5)` (16417). `weeklyGoalHours` is a synced state setting (`SETTINGS_FIELDS`, 21311); the settings row is `#weekly-goal-hours` (14988–15003, min 1, max 168, step 0.5), handled by `onWeeklyGoalChange` (35884); import accepts 0 < h ≤ 168 (34986).

**The daily goal** — `autoPopulateDailyGoal(dateStr)` (27459–27613), skipped when `goalAutopopulateEnabled === false`:

- A date that already has a saved shift: the remaining part of its locked anchor (`dailyAnchorMap`).
- Saturday or Sunday: `round(standardDay × 0.75)` — **leave is not checked**, so a Saturday booked as leave still asks 6 h.
- Monday–Friday: `dayOfWeek × standardDay − (work logged Monday..yesterday + prior leave days × standardDay)`, floored at 0; a leave day is 0. The whole shortfall lands on today. Weekend work never enters it.
- Written through `Sync.notePrefsDerived` (I11); sets `state.shiftStartGoalSec` while a shift runs.

**The week is Monday–Sunday everywhere, and only Monday–Friday counts:**

| Where                                            | Lines                                     | What it assumes                                                                     |
| ------------------------------------------------ | ----------------------------------------- | ----------------------------------------------------------------------------------- |
| `calculatePeriodGoalStats`                       | 16422                                     | a list of weekdays; target = standard day × non-leave days, **current** weekly goal |
| `calculatePaceRequired`                          | 16445                                     | —                                                                                   |
| `getMonthlyWeeks`                                | 16462                                     | Monday snap                                                                         |
| `weeklyCache` (key: UTC Monday noon)             | 17379                                     | Monday                                                                              |
| `resolveGoalSecForDate` fallback                 | 17384–17414                               | standard day for any past date                                                      |
| analytics worker + main-thread fallback          | 27098–27165, 27177–27240                  | Monday week keys                                                                    |
| `updateLiveWeeklySummary` (the live weekly card) | 28307–28515                               | `for (i < 5)`, `nowDay >= 1 && <= 5`, weekend ⇒ pace "—", trend                     |
| `isViewingCurrentWeek`                           | 28548–28581                               | Monday                                                                              |
| `updateProgress` today's segment                 | 28670–28717                               | `isoDay <= 5`, segment index `isoDay − 1`                                           |
| logbook row tag and delta fallback               | 31723–31850 (tag 31843, `8 * 3600` 31818) | weekend = Sat/Sun; 8 h                                                              |
| filter "This week"                               | 30926–30940                               | Monday..Sunday                                                                      |
| heatmap columns, leave-day goal, streak          | 32335–32346, 32240, 32578–32602           | Monday columns; standard day; streak skips Sat/Sun                                  |
| `renderInsights` (weekly)                        | 32665–33270                               | Monday; 7 rows; `totalW_MonFri`; bar rebuilt as 5 segments "M T W T F" (33043)      |
| `renderMacroInsights` (monthly / yearly)         | 33275–33700                               | Monday weeks; weekend work excluded and badged "N Weekends" (33369–33411)           |
| segmented bar markup / `DOM.progressSegments`    | 13778, 17619–17642                        | Monday–Friday                                                                       |
| guide: daily goal, insights                      | 10528–10561, 10681–10685                  | "Monday to Friday", "Saturday and Sunday", "40-hour week"                           |
| `.badge-weekend`                                 | CSS 6442                                  | —                                                                                   |

**Two facts that shape the design:**

- **Changing the weekly goal already rewrites every past week's target**, because `calculatePeriodGoalStats` reads the current value. Only a record's own `dayGoal` is locked. §4.4 fixes this as part of the schedule history (decision W7).
- **Weekend work is excluded from every weekly, monthly and yearly total**, and is shown only as a tag. That is today's meaning of "day-off work does not count" (decision W4, default off).

**Settings adoption does not validate.** `adoptSettings` (24207) copies every `SETTINGS_FIELDS` value straight into `state`. `PREF_KEYS` (21401) supports a `validate`. The schedule therefore lives in a validated JSON preference, not in `state` (§4.3).

**Backups name each preference.** `buildBackupPayload` (34705) lists `workTz`, `localTz`, `tzDisplay` one by one; `finalizeImport` (35139) restores `state` fields one by one; `purgeFactoryKeys` (35743) lists every key. Each new key is added to all three.

### 4.2 Decisions in force (confirmed by the user, 2026-09-15)

W1 any mix of the seven days, no presets · W2 the weekly goal is split equally · W3 one day-off goal setting, typed by hand, today's value by default, 0 = no goal · W4 a switch "day-off work counts toward the week", default off · W5 week start is a setting (Mon / Sun / Sat), default Monday · W6 catch-up is a setting, default today's way · W7 past weeks keep their old schedule, a change applies from the current week · W8 holidays stay leave; leave on a day off changes no goal and the booking says so · W9 the weekly bar shows work days only · W10 rotations out of scope, but the stored shape leaves room · S1 (proposed) the schedule syncs like the weekly goal.

### 4.3 Data model

```js
// localStorage "nodrift_work_week_v1" (WORK_WEEK_KEY); synced as PREF_KEYS.workWeek { json: true, validate: isWorkWeekPref }
// ABSENT means today's schedule (F2). Written only by an explicit change.
{
  v: 1,
  workDays: [1, 2, 3, 4, 5],   // getUTCDay numbers, unique, sorted, 1–7 entries
  weekStart: 1,                // 1 Monday · 0 Sunday · 6 Saturday
  dayOffGoalHours: null,       // null = 0.75 × work-day goal; else 0 ≤ h ≤ 24, step 0.25
  dayOffCounts: false,
  catchUp: "next",             // "next" | "spread"
  history: [                   // archived schedules, strictly ascending `until`, at most 520
    { until: "09/13/26", weeklyGoalHours: 40, workDays: [1,2,3,4,5], weekStart: 1,
      dayOffGoalHours: null, dayOffCounts: false, catchUp: "next" }
  ]
}
```

- **The current weekly goal stays `state.weeklyGoalHours`**, so a build from `0ba1bd6` keeps reading and editing the number it knows. Archived entries carry their own `weeklyGoalHours`.
- The whole schedule is **one value**. Two devices racing never produce a mix of one device's work days and the other's catch-up mode: the newest whole schedule wins (the settings rule, `SYNC-BLUEPRINT.md`).
- `v` and unknown top-level keys: the validator accepts `v === 1` and ignores unknown keys, so a later rotation (W10) can be added as a new key without breaking this build. A `v` it does not know is skipped whole (F4).
- **Validation** (`isWorkWeekPref`): the types and ranges above; `workDays` non-empty, unique and ascending; `until` a real date written `MM/DD/YY`; `history` strictly ascending and at most 520 entries; every entry's `weeklyGoalHours` in (0, 168]. Anything else is refused whole. A long work day is never a reason to refuse a stored, synced or imported schedule (decision W14): the 24-hour limit applies when the work days are chosen, and the weekly goal keeps its own 1–168 h range.

### 4.4 Resolution rules

**R1 — Effective schedule for a business date D.** Walk `history` in order; the first entry with `until ≥ D` governs D. If none, the current schedule (`state.weeklyGoalHours` + the pref's top-level values, or the defaults when the pref is absent) governs D.

**R2 — Period of a schedule.** An archived entry k governs `[until(k−1) + 1 day, until(k)]` (the first from the beginning of time). The current schedule governs from `until(last) + 1 day` onward.

**R3 — Weeks.** For D governed by schedule S with period start P and period end E:

- `ws = max(the latest date ≤ D whose weekday is S.weekStart, P)`
- `we = min(the day before the first S.weekStart weekday after ws, E)`

Normally that is 7 days. It is shorter only for the first week after a week-start change (a **transition week**) and never crosses a schedule boundary. Property: every date belongs to exactly one week; weeks are contiguous; lengths are 1–7; only a week starting at a period start can be shorter than 7, and only if the week start changed.

**R4 — Archiving on change.** When the user changes the weekly goal or anything in the work-week card on work date T:

1. `ws` = the start of T's week under the schedule **before** the change (R3).
2. `until` = `ws − 1 day`.
3. If the last archived entry already has `until ≥` that date, an earlier change this week archived the pre-week values: overwrite only the current values.
4. Otherwise push `{ until, ...values before the change }`, then write the new current values.

So the current week follows the new schedule (W7), and a week that ended keeps its own. Several edits in one week make one archive entry. A week-start change starts a transition week at `ws` that runs until the new week start comes round (P-W12). The settings card says so: "This week runs Mon 14 – Sat 19; weeks start on Sunday from Sep 20".

**R5 — Day goals.** For D under schedule S: a work day's goal is the work-day goal (§2); a day off's goal is `round(dayOffGoalHours × 3600)`, or `round(workDayGoal × 0.75)` when unset. A leave day that is a work day: 0. A leave day that is a day off: the day-off goal, unchanged (W8, today's weekend behaviour).

**R6 — Week target and counted work.** Target = Σ work-day goals over the week's work days that are not leave. Counted work = work on the week's work days, plus work on its days off when `S.dayOffCounts`. For a week, the schedule is the one governing its days (R3 keeps a week inside one period).

**R7 — The automatic goal for date D** (replacing `autoPopulateDailyGoal`'s arithmetic, same early returns: autopopulate off; a date with a saved shift uses its anchor):

- D is a day off: R5.
- D is a leave work day: 0.
- Otherwise, over the week's days before D:
  - `owed = Σ goals of prior work days (leave work days count as met) − Σ work logged on prior work days − (dayOffCounts ? Σ work logged on prior days off : 0)`
  - `"next"`: `max(0, workDayGoal + owed)`.
  - `"spread"`: `n` = the work days from D to the week's end that are not leave, D included; `max(0, round(workDayGoal + owed / n))`.

With the defaults this is exactly today's formula: on Mon–Fri, `dayOfWeek × standardDay − (prior work + prior leave × standardDay)` equals `standardDay + (prior goals − prior leave credit − prior work)`. W1's golden master proves it.

**R8 — The live and weekly figures:**

- **Pace required:** remaining (target − counted work) ÷ work days from today to the week's end that are not leave, today included only if it is a work day; "— / Day" when none remain.
- **Expected so far:** goals of the work days before today, not leave; a past week expects its whole target.
- **Trend:** subtract today's work from counted work when today is a work day, or when it is a day off and `dayOffCounts` is on.

**R9 — Streak:** a day off that missed its goal is skipped, as a weekend is today. **Heatmap:** columns start on the week start in effect on Jan 1 of the year shown; a leave-only day's goal is R5.

### 4.5 UI / UX

**Settings — a new "Work week" card** directly under the tracking card (which keeps Auto-populate and the weekly goal, the node the phone sheet borrows into its goal slot):

```
Work week
  Work days          [Mo][Tu][We][Th][Fr] Sa  Su     ← chips in week-start order; filled = work day
  Week starts on     ( Monday ▾ )
  Per work day       8h                              ← read-out: weekly goal ÷ work days
  Goal on a day off  [ 6 ] h   Auto                  ← placeholder shows the automatic value; "Auto" clears it
  Day-off work counts toward the week   [ ○ ]
  Catch-up           ( Next work day ▾ )             ← Next work day · Spread over the week
```

- Chips are two letters with a full-name `aria-label`; seven fit in 375 px (§4.7 row 42). The last work day cannot be switched off ("At least one work day").
- With seven work days, the day-off rows are disabled with the note "No days off".
- Choosing work days that would make a work day longer than 24 h is refused with the reason (P-W13, narrowed by W14); the weekly goal keeps its 1–168 h range.
- Every change raises a toast with **Undo** that restores the previous preference byte-for-byte, history included: "Work days: Mon–Thu, from this week (Sep 14)". The weekly-goal toast gains the same wording.
- A running shift is untouched (F6); the toast adds "Today's shift keeps its goal".
- **Phone:** the card is one node, borrowed into a new sheet section "Work week" under the goal (`RELOCATIONS`, 44750), exactly as the Time zones card is. No `display` inline under `.main-ui` (I13).

**Weekly bar (W9):** one segment per work day of the week shown, in week order, labelled with the day's first letter. A past week shows its own schedule's segments. Today's segment is the index of today among the work days, or none on a day off. (This section first proposed a second letter wherever two work days share an initial; **decision W15** kept one letter apiece, because Tuesday and Thursday share one in the default week and §1 promises that week does not change.)

**Wording (P-W11):** from W3, "Weekend" becomes **"Day off"** in the logbook tag and the insights rows, and the "N Weekends" badge becomes **"N Days off worked"** — worked, because the badge beside it already counts leave as "N Days Off" (decided with the user during W3). Its tooltip reads "…worked on N days off — not counted toward the weekly target", or "— counted toward the weekly target" when the switch is on; the badge appears either way. W1 and W2 keep "Weekend", because they must be behaviour-identical.

**A goal of 0 on a day off (P-W16, narrowed by decision W16):** the goal badge reads "No goal", the progress text reads "No goal · 2h 10m worked" with no Overtime figure, the bar stays empty, no finishing time is estimated, the heatmap colours the square for having been worked rather than for being exceeded, and no goal toast fires (the toast already requires ≥ 60 s, 28812). It is the **day** that asks nothing, not the arithmetic: this reaches a day off whose goal is 0 and nothing else. A **work** day whose goal comes out 0 — the week is already met, or the day is on leave — keeps the percentage line every build before W3 showed ("0.0% (Overtime: 0m)"), its full bar and its heatmap ladder. W3 shipped the wider reading; W4 narrowed it to this after measuring what the wider one cost against the golden master.

**Leave on a day off (W8):** the booking toast reads "Added leave on 09/19/26 — Saturday is already a day off, so no goal changes".

**Guide:** "The Daily Goal" and "What Insights shows" are rewritten around work days, the day-off goal, the switch and both catch-up modes, with the 40-hour Monday–Friday week kept as the worked example.

### 4.6 Things that deliberately do not change

- Leave allowances, leave types and balances.
- The locked anchor and split-shift logic (a day with a saved shift).
- The daily goal presets and the "Update Session Goal?" prompt.
- Midnight rollover and the time zone rules.
- A catch-up goal can exceed 24 h in `"next"` mode, as it can today (a Friday with nothing logged asks 40 h); `"spread"` is the answer to that, not a cap.

### 4.7 Edge-case catalogue — work week

Each row becomes at least one assertion in the phase named.

| #   | Scenario                                                                                            | Expected                                                                                                                                                                                                                                                                                       | Phase  |
| --- | --------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ |
| 1   | Existing user upgrades, no setting touched                                                          | Every figure identical to the `0ba1bd6` golden master                                                                                                                                                                                                                                          | W1, W2 |
| 2   | Upgrade lands mid-shift                                                                             | Shift goal unchanged; nothing re-dated                                                                                                                                                                                                                                                         | W2     |
| 3   | Fresh device signs into an account with a custom schedule                                           | Adopts it; uploads nothing                                                                                                                                                                                                                                                                     | W2, W4 |
| 4   | Fresh device, account with no schedule                                                              | Defaults; no key written, nothing uploaded (F2)                                                                                                                                                                                                                                                | W2, W4 |
| 5   | Mon–Thu, 40 h                                                                                       | 10 h per work day; Fri–Sun days off at 7.5 h (automatic)                                                                                                                                                                                                                                       | W2     |
| 6   | Mon / Wed / Fri, 30 h, "next"                                                                       | Tuesday is a day off and never owes; Wednesday owes Monday's shortfall                                                                                                                                                                                                                         | W2     |
| 7   | Mon–Sat, 48 h                                                                                       | 8 h per work day; Sunday a day off                                                                                                                                                                                                                                                             | W2     |
| 8   | Seven work days                                                                                     | No days off; day-off rows disabled                                                                                                                                                                                                                                                             | W2, W3 |
| 9   | One work day at 40 h                                                                                | Refused: a 40 h day goal exceeds 24 h                                                                                                                                                                                                                                                          | W2, W3 |
| 10  | Sun–Thu with week start Sunday                                                                      | Fri / Sat days off; weekly rows Sun..Sat; bar S M T W T                                                                                                                                                                                                                                        | W2, W3 |
| 11  | Week start Mon → Sun on a Wednesday                                                                 | Transition week Mon–Sat; Sunday-start weeks after; last week unchanged                                                                                                                                                                                                                         | W2     |
| 12  | Week start changed on the first day of a week                                                       | Transition week still starts at `ws`, runs to the new start (property of R3/R4)                                                                                                                                                                                                                | W2     |
| 13  | Work days changed mid-week                                                                          | Current week follows the new schedule; last week keeps its target and bar                                                                                                                                                                                                                      | W2     |
| 14  | Weekly goal changed                                                                                 | Past weeks keep the old target (today they are rewritten — the one intended difference)                                                                                                                                                                                                        | W2     |
| 15  | Three changes in one week                                                                           | One archive entry, holding the values from before the week                                                                                                                                                                                                                                     | W2     |
| 16  | Schedule changed during a shift                                                                     | Running shift's goal unchanged (F6); applied at the next populate                                                                                                                                                                                                                              | W2, W3 |
| 17  | Today becomes a day off during its shift                                                            | Goal kept; after EOD, today's work is day-off work in insights                                                                                                                                                                                                                                 | W2     |
| 18  | Day-off goal 0                                                                                      | "No goal"; no Overtime; no toast; heatmap and streak handle a 0 goal                                                                                                                                                                                                                           | W2, W3 |
| 19  | Day-off work, switch off                                                                            | Excluded from totals, shown as "N Days off" — today's weekend behaviour                                                                                                                                                                                                                        | W1, W2 |
| 20  | Day-off work, switch on                                                                             | Counts in totals and reduces what the remaining work days owe; target unchanged                                                                                                                                                                                                                | W2     |
| 21  | "next": 6 h behind on Monday (Mon–Fri, 40 h)                                                        | Tuesday asks 14 h (identical)                                                                                                                                                                                                                                                                  | W1     |
| 22  | "spread": 6 h behind on Monday                                                                      | Tuesday–Friday each ask 9 h 30 m; ahead lowers them; floored at 0                                                                                                                                                                                                                              | W2     |
| 23  | "spread" with leave on Thursday                                                                     | The shortfall is shared over Tue, Wed, Fri                                                                                                                                                                                                                                                     | W2     |
| 24  | "spread" on the last work day                                                                       | Same as "next"                                                                                                                                                                                                                                                                                 | W2     |
| 25  | Leave on a work day                                                                                 | Goal 0; target drops one work-day goal (identical)                                                                                                                                                                                                                                             | W1     |
| 26  | Leave on a day off                                                                                  | Day-off goal unchanged; booking toast says it is a day off                                                                                                                                                                                                                                     | W2, W3 |
| 27  | Past week viewed after a schedule change                                                            | Its own segment count, target and result                                                                                                                                                                                                                                                       | W3     |
| 28  | Monthly view: a week straddling two months, and a transition week                                   | Per-day schedule; month-clipped targets                                                                                                                                                                                                                                                        | W2     |
| 29  | Yearly view across a mid-month change                                                               | Per-day schedule                                                                                                                                                                                                                                                                               | W2     |
| 30  | Heatmap and streak with Sun–Thu                                                                     | Columns start Sunday; streak skips Fri / Sat                                                                                                                                                                                                                                                   | W2, W3 |
| 31  | A week across 12/31 → 01/01 (two-digit year) under every week start                                 | Correct dates, keys and totals                                                                                                                                                                                                                                                                 | W1, W2 |
| 32  | Records of two zones on one business date                                                           | The weekday comes from the business date only (I2)                                                                                                                                                                                                                                             | W1     |
| 33  | Synced schedule invalid or hostile (empty days, weekStart 3, unsorted history, strings, `v: 2`)     | Skipped whole; previous kept; no throw; anomaly logged                                                                                                                                                                                                                                         | W2     |
| 34  | Import a backup with a schedule / a legacy backup without                                           | Validated and applied / schedule untouched                                                                                                                                                                                                                                                     | W2     |
| 35  | Factory reset                                                                                       | Key removed; defaults                                                                                                                                                                                                                                                                          | W2     |
| 36  | A `0ba1bd6` build wins a settings race beside a new build                                           | Measured in W0: the account's copy loses the schedule. The new build keeps its own and, on adopting that blob, sends it back (row 86), so a device signing in afterwards receives it. A weekly-goal edit on the old build writes no archive, so weeks since the last one follow the new number | W2, W4 |
| 37  | Two devices change the schedule at once                                                             | The newest whole schedule wins; never a mix                                                                                                                                                                                                                                                    | W4     |
| 38  | Autopopulate off                                                                                    | Nothing written; insights still follow the schedule                                                                                                                                                                                                                                            | W2     |
| 39  | A day with a saved shift                                                                            | Anchor locked; schedule does not move it                                                                                                                                                                                                                                                       | W2     |
| 40  | Logbook row with no `dayGoal`                                                                       | Delta against R5's goal, not 8 h                                                                                                                                                                                                                                                               | W1     |
| 41  | Filter "This week"                                                                                  | The schedule's week                                                                                                                                                                                                                                                                            | W2     |
| 42  | 375 px phone                                                                                        | Seven chips without wrap; a seven-segment bar legible; card fits the sheet                                                                                                                                                                                                                     | W3     |
| 43  | Week arrows across a transition week                                                                | Each week visited once, in order                                                                                                                                                                                                                                                               | W3     |
| 44  | Work zone change moves "today" across a week boundary                                               | Week follows the business date; no archive written                                                                                                                                                                                                                                             | W2     |
| 85  | A shift filed with a goal of 0 (a worked leave day, a 0 h day off), after a reload and after a pull | `dayGoal` stays 0 (today it becomes 8 h, measured in W0); only a missing goal is filled in (decision W12)                                                                                                                                                                                      | W2     |
| 86  | A new build adopts a settings blob without the schedule it holds                                    | It keeps its schedule and re-uploads the whole blob on its next beat; an old build adopting that loses nothing; no back-and-forth between devices (decision W11)                                                                                                                               | W2, W4 |

---

## 5. 24-hour clock

### 5.1 What exists today (audit at `0ba1bd6`)

- **Formatter styles** (`TimeZones` STYLES, 18135–18190): `time` "09:05:03 AM" (logbook In/Out, both status bar clocks), `timeOnly` "9:05:03 AM" (idle dialog), `hm` "05:30 PM" (Est. EOD), `clock` (picker rows), all `hour12: true`; `parts` uses `hourCycle: "h23"` internally. `formatTime(ms, zone, style)` at 18452.
- **Status bar clocks** split the AM/PM into their own element: `setClock` (26352) matches `/^(.*?)\s*(AM|PM)$/i`; `.clock-ampm` CSS (1738, 7465).
- **Stored strings are 12-hour and parsed as such:** the parser at 16636–16658 (used by `typedTimeInZone` as `parseClockTimeToSeconds`), `parseTimeToMinutes` (16660), `secondsToAMPM` (16682), `minutesToAMPM` (16696). `recordEndpointText` (19235) returns the stored string when it agrees with the instant.
- **Typing:** `parseClockTimePreview` (42380–42446) accepts `0900`, `900p`, `9:30p`, 24-hour input without a suffix, and always writes `09:00:00 AM`; bound on blur to manual and edit login/logout (42456). `typedGapMessage` builds a 12-hour sentence (42538).
- **Exports:** CSV `csvRowForLog` (34620) and tasks CSV (40700) use `recordEndpointText`; the EOD email (29134) and the row copy (35546) carry durations and dates, no clock times (the other copy sites, 35670, 37359, 38753, 40637, 40672, are audited in C1).
- **Guide:** "Typing times quickly" (10631–10661) quotes `09:00:00 AM`.

### 5.2 Decisions in force

C1 a 12-hour / 24-hour switch, default 12-hour; every time on screen follows; typing accepts both forms · C2 exports (CSV, tasks CSV, email, copy buttons) stay 12-hour · S1 (proposed) the preference syncs · P-F1 (proposed) the row lives in the Time zones card, renamed "Time and date".

### 5.3 Design

- Preference `clockFormat`: `"12h"` | `"24h"`, key `nodrift_clock_format_v1`, `PREF_KEYS` entry with `validate`, absent = `"12h"`. Backup, import, factory reset lists.
- `TimeZones` gains `h23` twins of `time`, `timeOnly`, `hm` and `clock` (`hourCycle: "h23"`, never `hour12: false`, which some engines render as `24:05`). `clockStyle("time")` returns the twin for the preference; the tick reads the preference from a module variable, never from `localStorage`. **Measured in C1:** on the Chrome the suites grade against, `en-US` with `hour12: false` already resolves to `h23`, so midnight reads `00:00:05` either way there. The rule stays, because it is the engines that do not that it is for — but it is not gradeable by a mutation on this machine, and C1's mutation list says so.
- **Screens** call `clockStyle`. `recordEndpointView` formats from the instant when the preference is 24-hour (the stored string is 12-hour by F1). `setClock` leaves `.clock-ampm` empty and collapsed in 24-hour mode.
- **Exports** call `exportTime(record, end)`, which is today's `recordEndpointText`, pinned to 12-hour (F9).
- **Typing:** `parseClockTimePreview` accepts both forms in either mode and writes the preference's form into the field. Every save path converts the field to the stored 12-hour string before saving. The kept-instant comparison in the edit dialog (`keptTypedInstant`, 34375) compares **seconds**, not strings, so an unchanged field stays byte-identical in both modes.
- `onDisplayFormatChanged()` bumps a version included in `zoneRenderKey()` (19127) and the logbook row key (31744), then redraws.

### 5.4 Edge-case catalogue — clock

| #   | Scenario                                                                       | Expected                                                              | Phase |
| --- | ------------------------------------------------------------------------------ | --------------------------------------------------------------------- | ----- |
| 45  | Default                                                                        | Every string identical to `0ba1bd6`                                   | C1    |
| 46  | 24-hour status bar                                                             | "17:30:05"; no empty AM/PM gap; 375 px geometry unchanged or narrower | C1    |
| 47  | Just after midnight                                                            | "00:00:05", never "24:00:05"                                          | C1    |
| 48  | Edit and save unchanged in 24-hour mode                                        | Record byte-identical, stored strings still 12-hour                   | C1    |
| 49  | Typing "5:30 pm", "1730", "17:30" in each mode                                 | Normalised to the preference's form; stored 12-hour                   | C1    |
| 50  | Manual entry saved in 24-hour mode                                             | Stored login / logout are 12-hour strings                             | C1    |
| 51  | CSV, tasks CSV, email, copy buttons in 24-hour mode                            | Byte-identical to 12-hour mode                                        | C1    |
| 52  | DST gap message in 24-hour mode                                                | "02:30 doesn't exist on …"                                            | C1    |
| 53  | Hostile or unknown synced value                                                | Ignored, previous kept                                                | C1    |
| 54  | Zone picker rows, idle dialog, Est. EOD, banners, insights first-in / last-out | All follow the preference                                             | C1    |

---

## 6. Date order

### 6.1 What exists today (audit at `0ba1bd6`)

- **Stored form** `MM/DD/YY` everywhere (the vocabulary of `docs/implement.md`).
- **Shown:**
  - logbook `(09/15)` (31726–31769);
  - weekly insights rows (32814);
  - heatmap title and tooltip (32487–32540, `showHeatmapTooltip` 32023);
  - `businessDayLabel` "Sat 09/13/26" (26430);
  - leave list and toasts (41549, 41602, 41629);
  - `toLocaleDateString` (29995);
  - `displayDate` built at 31100 and 39750;
  - the import conflict wizard.
- **Typed:**
  - `handleDateInputBlur` (two copies, around 41940 and 42250), bound to nine inputs (42365);
  - an ambiguous `03/04` is read by the device's region (`_cachedLocaleDayFirst`, 18080);
  - month names are accepted; ISO is accepted by the typing preview but **not** by the blur handler, which stores the 30th of the month instead (measured in D1, fixed in D1b);
  - `saveEditModal` re-checks `^\d{1,2}/\d{1,2}/` as MM/DD (34348–34360);
  - `parseDateStringLocal` (42463);
  - labels "Date (MM/DD/YY)" and placeholders "05/16/26" (11388, 11507–11514, 11632, 11781–11787, 12082);
  - toasts "Use MM/DD/YY" (34572, 39820, 41536).
- **Exported:**
  - CSV `l.date` (34633);
  - tasks CSV `task.date` (40708);
  - EOD email subject and body `[09/15/26 - Tue]` (29189–29226);
  - row copy (35546);
  - JSON backup (stored form);
  - file names year-first via `isoDate` (34682, 34791, 40720).

### 6.2 Decisions in force

D1 three choices — MM/DD/YY, DD/MM/YY, YYYY-MM-DD — default MM/DD/YY; everything shown, typed and exported follows ("the user must get what the user sees in the app exactly the same") · D2 the JSON backup keeps the stored form; export file names stay year-first · S1 (proposed) the preference syncs · P-F2 (proposed) in YYYY-MM-DD mode a typed slash date is read by the device's region, as today · P-F3 (proposed) search accepts dates typed in the chosen order.

### 6.3 Design

- Preference `dateOrder`: `"mdy"` | `"dmy"` | `"ymd"`, key `nodrift_date_order_v1`, `PREF_KEYS` with `validate`, absent = `"mdy"`.
- `formatDateKey(key, form)`, the one display function (F3). It covers:

  | Form      | MM/DD/YY       | DD/MM/YY       | YYYY-MM-DD       |
  | --------- | -------------- | -------------- | ---------------- |
  | `full`    | `09/15/26`     | `15/09/26`     | `2026-09-15`     |
  | `short`   | `09/15`        | `15/09`        | `09-15`          |
  | `weekday` | `Tue 09/15/26` | `Tue 15/09/26` | `Tue 2026-09-15` |

- `parseTypedDate(value) → key | null`, the one parser. It replaces both `handleDateInputBlur` copies and the save-path regexes. Rules:
  - an unambiguous value is read as today;
  - ISO is always accepted;
  - an ambiguous slash date follows the preference, and follows the device's region in YYYY-MM-DD mode (P-F2).

  Fields display `formatDateKey(key, "full")`; save paths call `parseTypedDate` and store the key.

- Labels, placeholders and toasts are built from the preference: "Date (DD/MM/YY)", "16/05/26", "Use DD/MM/YY".
- `exportDate(key)` = `formatDateKey(key, "full")` for CSV, tasks CSV, email and copy buttons (D1). `buildBackupPayload` is untouched (D2). File names are untouched.
- **Search:** a query that parses as a date in the chosen order also matches the stored key (records' `searchStr` is stored and cannot change, F1).
- `onDisplayFormatChanged()` (§5.3) covers this preference too.

### 6.4 Edge-case catalogue — dates

| #   | Scenario                                                       | Expected                                                       | Phase |
| --- | -------------------------------------------------------------- | -------------------------------------------------------------- | ----- |
| 55  | Default                                                        | Every string and export identical to `0ba1bd6`                 | D1a   |
| 56  | DD/MM: logbook, insights, heatmap, leave list, dialogs, toasts | `15/09`, `15/09/26`                                            | D1a   |
| 57  | YYYY-MM-DD                                                     | `2026-09-15`, short `09-15`                                    | D1a   |
| 58  | Typed `03/04/26` in DD/MM / in MM/DD                           | Stored `04/03/26` / `03/04/26`                                 | D1b   |
| 59  | Typed `15/09` in MM/DD                                         | Still read as 15 September (unambiguous)                       | D1b   |
| 60  | Typed `2026-09-15` in any mode                                 | Accepted                                                       | D1b   |
| 61  | Typed slash date in YYYY-MM-DD mode                            | Device region rule (P-F2)                                      | D1b   |
| 62  | Edit and save unchanged in DD/MM                               | Record byte-identical                                          | D1b   |
| 63  | CSV, tasks CSV, email subject and body, copy buttons           | Follow the preference; the column order is unchanged           | D1a   |
| 64  | JSON backup in DD/MM                                           | Stored `MM/DD/YY`; file name year-first; restores on `0ba1bd6` | D1a   |
| 65  | Search `15/09` in DD/MM                                        | Finds 15 September's records                                   | D1b   |
| 66  | Filters' date range in DD/MM                                   | Reads and shows the preference                                 | D1b   |
| 67  | Import conflict wizard                                         | Shows the preference; stores the key                           | D1a   |
| 68  | Hostile or unknown synced value                                | Ignored                                                        | D1a   |
| 69  | Zone messages ("doesn't exist on …", pending-zone banner)      | Follow the preference                                          | D1a   |

---

## 7. Re-filing a record in another zone

### 7.1 What exists today (audit at `0ba1bd6`)

- `recordZone(record)` (18911) sanitises `record.tz` to `LEGACY_TZ`; I3 keeps a record in the zone it was filed in.
- `saveEditModal` (34295):
  - reads the typed times in `recordZone(log)` (34372);
  - keeps the original instants when the text is unchanged (`keptTypedInstant`, 34375);
  - places the rest with `resolveTypedWindow` (34387), which refuses a gap (D6) and takes the earlier repeated hour;
  - saves with an explicit `tz`.
- The task edit dialog (11388) has the same shape.
- **Records carry no "manual entry" marker** on the record itself, so the dialog cannot tell a timed shift from a typed one by a flag. **Audited in Z1a and settled (see the results below): nothing reliable stands in for one.** A tracked record and a typed one carry the same seventeen fields; the milliseconds on `loginEpochMs` say "timed" only one way round, since a clock-in on a whole second looks typed; and the one marker that exists — the words "manual entry" that `saveManualModal` puts in `searchStr` — is erased by `saveEditModal` the first time the record is saved. P-Z4 therefore stands.

### 7.2 Decisions in force

Z1 the zone is chosen in the edit dialog, with a before/after preview and two modes — **keep the real moments** or **keep the times as written**; hours worked never change; the preview says when the day moves · P-Z2 (proposed) shifts and tasks both · P-Z3 (proposed) re-filing may move the business date — the one exception to I2, because it is an explicit re-filing · P-Z4 (proposed) the default mode is "keep the real moments" for every record unless Z1a finds a reliable manual marker.

### 7.3 Design

The zone is **which zone the form's times are read in**, so re-filing reuses the save path instead of adding one:

1. A "Time zone" row in the dialog shows `zoneCityOffset(recordZone(log))` and a **Change** button that opens `ZonePicker`.
2. After a choice, a preview block with two radio options:
   - **Keep when it happened** — the form's date and times are re-filled with the same instants in the new zone. The date is the business date of the login instant there. The kept instants are carried explicitly, so a re-fill landing in a repeated hour still saves byte-identical instants.
   - **Keep the times as written** — the form is unchanged. On save the times are read in the new zone: a gap is refused (D6), a repeated hour takes the earlier reading, `workSec` / `breakSec` are unchanged.

   Each option shows its In → Out and, when it differs, "Date 09/14/26 → 09/15/26". A **Cancel zone change** link restores the form.

3. Save is the normal Save: `tz` = the chosen zone; `lastModified` bumped; the old and new months' chunks marked dirty; anchors and insights recompute.
4. A record with placeholder times offers only "Keep when it happened".
5. A leave row has no zone row. The running shift is not a record and is not re-filed here (its zone change is D2's banner).

### 7.4 Edge-case catalogue — re-filing

| #   | Scenario                                             | Expected                                                               | Phase |
| --- | ---------------------------------------------------- | ---------------------------------------------------------------------- | ----- |
| 70  | Keep moments, LA → Dhaka                             | Instants byte-identical; times and date re-derived; preview matched it | Z1b   |
| 71  | Keep written times, LA → Dhaka                       | Strings and date unchanged; instants move 13 h; work / break unchanged | Z1a   |
| 72  | Keep written times into a DST gap                    | Refused with D6's sentence                                             | Z1a   |
| 73  | Keep written times in a repeated hour                | Earlier occurrence                                                     | Z1a   |
| 74  | Keep moments landing in the new zone's repeated hour | Instants byte-identical                                                | Z1a   |
| 75  | Legacy record (no `tz`)                              | Read from Los Angeles; saved with the new `tz`                         | Z1a   |
| 76  | The date moves into another month                    | Both chunks dirty; both months' insights updated                       | Z1a   |
| 77  | The moved record overlaps another                    | The existing overlap warning                                           | Z1a   |
| 78  | The moved record was its day's oldest                | Both days' anchors recompute; the record keeps its `dayGoal`           | Z1a   |
| 79  | The shift crosses midnight in the new zone           | One record, dated by its login; no split                               | Z1a   |
| 80  | A task re-filed                                      | Same rules                                                             | Z1b   |
| 81  | Synced to a second device                            | One upload; the other device shows the new zone and times              | Z1b   |
| 82  | Placeholder times                                    | Only "Keep when it happened" offered                                   | Z1b   |
| 83  | Picker cancelled, or zone change cancelled           | Form and record untouched                                              | Z1b   |
| 84  | Re-filed in 24-hour and DD/MM modes                  | Preview and form in the preferences; stored forms unchanged (F1)       | Z1b   |

---

## 8. Test strategy

**Tools** (all existing, see the harness memory): the raw CDP harness in the git-ignored `nodrift-harness/`; `Emulation.setTimezoneOverride` for the device zone; the `Date.now` shim to pin instants (never depend on the day a test runs — arm a date by seeding `state.activeDate` and the shim); `preload-supabase-stub.js` and the in-process fake server for sync; `probe-tz-oldclient.js`'s pattern for an old build beside a new one.

**The golden master (W0).** `probe-workweek-golden.js` loads the **unmodified** build and records, into `nodrift-harness/fixtures/workweek-golden-0ba1bd6.json.gz`:

- the automatic goal for every date of five pinned weeks, including a DST week and the 12/31 week;
- the live weekly card's summary, percent, pace and trend;
- the weekly, monthly and yearly insights breakdown text and bar segments;
- heatmap classes and the streak;
- the logbook tags and deltas.

It runs over a matrix of weekly goals (40, 37.5, 20, 15), log patterns (none, behind, ahead, weekend work, split shifts), leave patterns (none, a weekday, a weekend day), autopopulate on / off, and a running shift. **W1 and W2 must reproduce it byte for byte.**

**Property checks (W1, W2)** over random schedules and 3 years of dates:

- R3's week properties;
- R7 in `"next"` mode against a brute-force reference;
- `"spread"` never negative and summing to the week target when every day is met exactly;
- archiving never changes a date before `until + 1`.

**Zone matrix for the formats (C1, D1, Z1):** device zones `Asia/Dhaka`, `America/Los_Angeles`, `Pacific/Kiritimati`, `Pacific/Pago_Pago`; records in LA, Dhaka, London (DST), Santiago (the day with no midnight).

**New suites.** Ports: the follow-up suites own HTTP 8881–8883 and 8885–8889 and CDP 9481–9489 (W0 found 8884 registered by Windows HTTP.sys on the development machine).

| Suite                                                                                                                                                                                                    | Account            | Phase  |
| -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------ | ------ |
| `probe-workweek-golden.js`                                                                                                                                                                               | none               | W0     |
| `probe-workweek-server.js` (a nested `workWeek` round-trips byte-identical; an old client beside a new one)                                                                                              | test account       | W0, W4 |
| `harness-workweek-core.js`                                                                                                                                                                               | none               | W1     |
| `harness-workweek-model.js`                                                                                                                                                                              | stub / fake server | W2     |
| `probe-workweek-ui.js`                                                                                                                                                                                   | none               | W3     |
| `harness-formats.js` (clock and date, screens, typing, exports)                                                                                                                                          | none               | C1, D1 |
| `probe-refile.js` (one device for rows 70-80 and 82-84; a second against a fake server for row 81)                                                                                                       | none               | Z1     |
| extensions to `harness-progress.js`, `harness-phase8.js`, `harness-wipe.js`, `harness-security.js`, `probe-csv-shape.js`, `probe-backup-and-leave.js`, `probe-leave-rows.js`, `harness-signin-render.js` | live / none        | W2–Z1  |

Also from W0: `probe-workweek-audit.js` (no account; W0, then W2b, where its measured check that a goal of 0 survives a reload turns green) and `run-followups-regression.sh` (the list below, one suite at a time, power and md5 at both ends).

**Regression list** (W0 records the baseline; every phase runs it):

- `harness.js`, `harness-progress.js`, `harness-motion.js`, `harness-cloud-panel.js`;
- `harness-security.js`, `probe-leave-rows.js`, `probe-csv-shape.js`, `probe-backup-and-leave.js`;
- `probe-shift-rewind.js`, `probe-lease-endshift.js`, `harness-handoff.js`;
- `harness-tz-core.js`, `harness-tz-model.js`, `harness-tz-display.js`, `probe-tz-picker.js`, `probe-tz-ui.js`;
- live phases add `harness-phase8.js`, `harness-signin-render.js` and `harness-wipe.js`;
- from W1: `harness-workweek-core.js`, `probe-workweek-golden.js compare` (with the `--expect` of the phase) and `probe-workweek-eviction.js`;
- from W2: `harness-workweek-model.js` and `probe-workweek-audit.js`;
- from W3: `probe-workweek-ui.js`, and the golden master's `--expect=w3`;
- from W4: `probe-workweek-server.js` (live; last in the list, so a shared-account failure is easy to re-run alone);
- from C1: `harness-formats.js`, before the live suite (it covers D1's rows 55-69 too, from D1b);
- from Z1: `probe-refile.js`, also before the live suite (28 entries).

**House rules:**

- Assert the precondition (seed, read back, carry the count).
- Poll a window rather than sleep once.
- Assert `getComputedStyle(...).display` for anything a media query can hide.
- Open panels through their real trigger.
- Pair every assertion with a negative control.
- Diff storage for F1 / F2.
- Never run two suites at once.

---

## 9. Phases

### Phase W0 — Work week groundwork, golden master, probes, audit

**Goal:** turn every assumption in §4 into a measurement before code changes. **No `index.html` change.**

- `probe-workweek-golden.js` and its fixture (§8).
- **Server and old client:** a nested `workWeek` object in the settings blob round-trips byte-identical through `sync_session`. Then a `0ba1bd6` build and a probe build that writes the key share the test account: does a settings race won by the old build remove `workWeek` from the server row (it sends only the preferences it knows)? The answer decides whether W2 needs a guard (for example re-sending on adoption), and §4.7 row 36 is rewritten with the measured result.
- **Audit and record:**
  - what `executeSubmit` (29280) stores as `dayGoal` when the goal field is 0;
  - how a goal of 0 renders today;
  - every `dayNames[dateObj.getDay()]` site (29171, 35533, 35624, 37327, 40366) under the four device zones;
  - the other `autoPopulateDailyGoal` callers (22951, 23020, 27043, 27361, 29727, 36155–36432, 38061, 41600, 41627, 44060);
  - `syncSettingsUI` (39193–39240);
  - the manual goal edits (40834–40873, 41709–41829).
- Record the regression baseline; confirm ports 8881–8889 / 9481–9489 are free.

**Exit:** fixture saved; server round trip and old-client answer recorded here; baseline numbers written here. Docs commit only: `docs(week): record phase W0 results`.

#### Phase W0 results (2026-09-15)

`index.html` untouched throughout (md5 `1ad7e159` before and after every run). All runs on AC power at 2419 MHz.

**Ports.** No harness file uses 8881–8889 or 9481–9489, but **127.0.0.1:8884 is a URL registered with Windows HTTP.sys** (PID 4) on this machine. The follow-up suites use 8881–8883 and 8885–8889; 8884 stays free.

**Regression baseline** (`nodrift-harness/run-followups-regression.sh`, the §8 list one suite at a time, 18:01–18:08): **19 of 19 green.**

| Suite                     | Checks | Suite                    | Checks |
| ------------------------- | ------ | ------------------------ | ------ |
| harness.js                | 80     | harness-handoff.js       | 24     |
| harness-progress.js       | 25     | harness-tz-core.js       | 86     |
| harness-motion.js         | 43     | harness-tz-model.js      | 28     |
| harness-cloud-panel.js    | 27     | harness-tz-display.js    | 129    |
| harness-security.js       | 17     | probe-tz-picker.js       | 176    |
| probe-leave-rows.js       | 12     | probe-tz-ui.js           | 149    |
| probe-csv-shape.js        | 15     | harness-phase8.js        | 14     |
| probe-backup-and-leave.js | 26     | harness-signin-render.js | 16     |
| probe-shift-rewind.js     | 13     | harness-wipe.js          | 18     |
| probe-lease-endshift.js   | 30     |                          |        |

**Golden master** (`nodrift-harness/probe-workweek-golden.js`, fixture `nodrift-harness/fixtures/workweek-golden-0ba1bd6.json.gz`, md5 `af6175bd`, 987 KB gzipped from 36.7 MB of JSON, with a per-scenario digest beside it):

- **Matrix:** 5 log patterns × 3 leave patterns × weekly goals 40 / 37.5 / 20 / 15 × automatic goal on / off × no shift / a running shift = **240 scenarios**, plus **60 logbook sets** (log × leave × goal). Five pinned weeks: Mondays 03/02/26 (US DST start), 06/29/26 (across a month end), 09/07/26, 10/26/26 (US DST end), 12/28/26 (across the year end). Device and work zone Los Angeles.
- **Recorded:** the automatic goal for all 35 dates (and the frozen shift goal); at six moments per week (Mon, Wed, Fri, Sat, Sun, next Mon) the weekly card after `updateProgress` (label, total, percent, status and trend, break, every breakdown row, every bar segment with its data), the progress line, ETA and goal badge, and the streak; on Wed and next Mon also the heatmap cells of the pinned dates, the YTD line, and the monthly and yearly cards; on next Mon the finished week; every logbook row.
- **How:** a fresh browser profile per log × leave page, seeded through the real import and the analytics worker; each scenario is one synchronous evaluate with `Date.now` pinned and the state restored before it returns, so the app's own tick never sees it. Each page runs in its own process: a single process died silently with exit 127 (the Windows libuv assertion) in two of three full runs; a page whose process dies before writing a result is run once more and the run says so.
- **Record:** 31 checks, 0 failures. **Determinism:** a second full run compared 300 sets, **0 differ**. **Control:** the same comparison with a work day one minute longer reports 240 of 300 sets different, on the single-process runner and again on the per-page one (every scenario; the logbook sets do not use the standard day, see below).
- **Hand-checked** (40 h, "behind" logs, Thursday leave, week of 09/07): goals Mon 06:00 (the day's anchor 8 h − 2 h logged), Tue 06:30, Wed 06:30, Thu 07:30 (a log with no `dayGoal`: nothing is written and the field keeps its value), Fri 05:00, Sat and Sun 06:00. A running shift's frozen goal is rewritten only on a date with no saved log. Wednesday's card reads "28h 45m / 32h (90%)", "Pace Required: 1h 37m 30s / Day ↑ 4.8h ahead": the worked leave day's 8 h 15 m counts in the Monday–Friday total while its goal is taken off the target.
- **For W1's comparison:** the "behind" pattern's `_nogoal` logs show the logbook's hardcoded 8 h delta at every weekly goal. §4.7 row 40 changes that on purpose, so at 37.5 / 20 / 15 h those rows are the expected difference.

**Server and old client** (`nodrift-harness/probe-workweek-server.js`, live test account, **19 checks, all pass**, account empty afterwards):

- A nested schedule (history array, `null`, `0`, `4.5`, booleans) goes through `sync_session` and comes back, and is stored, identical.
- Three browsers: A a copy of this build whose `PREF_KEYS` also syncs `workWeek`, B this build unmodified, C a fresh copy of A.
  - A's edit uploads the schedule.
  - **B wins a settings race (a theme change) and the server's settings no longer contain `workWeek`.** The blob is replaced whole, and B's omits a key it does not know.
  - A adopts B's blob and keeps its own schedule (`applyPrefs` never deletes).
  - **A does not put the schedule back by itself** (four more beats).
  - **A fresh device C that signs in now receives no schedule**, so it would run the default one.
  - A's next edit of any preference restores the schedule on the server, and C receives it.

**Audit:**

- **A goal of 0 is filed but not kept** (`nodrift-harness/probe-workweek-audit.js`, measured). A shift whose frozen goal is 0 is stored with `dayGoal: 0`. It renders as overtime: "100.0% (Overtime: 3s)", "Daily Goal Reached", the weekly row "O 3s, G —", the heatmap cell `heatmap-exc`, and the streak counts it. The logbook's delta treats 0 as 8 h. **After a reload the same record says `dayGoal: 28800`, status UNDER**: `hydrateLogsInChunks` (44107) rewrites a goal that is not positive on any record without a `status`, `executeSubmit` writes no `status`, and the rewrite is saved. It used 8 h although the week had been set to 20 h. `rehydrate` (22948) does the same to records pulled from another device. Today this reaches any shift worked on a leave weekday, whose automatic goal is 0.
- **How a frozen goal is taken:** `switchMode` (27941) freezes `domWriteCache._goalSecCached || the goal field`, and that cache is refreshed only by `updateProgress`.
- **Weekday names in email and copy text** (29171, 35533, 35624, 37327, 40366) build `new Date(y, m − 1, d)` and read `getDay()`. Across every date of 2026–2027 under Asia/Dhaka, America/Los_Angeles, Pacific/Kiritimati, Pacific/Pago_Pago and America/Santiago that is the business weekday on all 730 days in all five zones. The control (`getDay()` of UTC noon) is wrong on 730 of 730 in Kiritimati, so the check can see the mistake. **These sites are correct and need no change.** 29225 and 32071 use `getUTCDay()` of UTC noon, also correct.
- **Manual goal edits** (typed goal 40789–40843, presets 41696–41717, the ± buttons 41761–41796) all switch the automatic goal off, write the goal keys as a user edit, and ask "Update Session Goal?" during a shift only when the frozen goal is truthy. A typed goal or a preset may be 0; the ± buttons stop at 15 minutes.
- **Callers of `autoPopulateDailyGoal`:** 23020 (leave pulled from another device), 27043 (after `saveLogs`), 27361 (the worker's reply), 29727 (after a submit), 35919 (a weekly-goal edit with no shift running), 36155 / 36171 / 36183 / 36432 (the active date set or rolled over), 38061 (the automatic goal switched on), 41600 / 41627 (leave added or removed), 44060 (boot). The plan's "22951" is `rehydrate`'s fallback, not a caller.
- **`syncSettingsUI`** (39191–39240) writes the weekly-goal field and the automatic-goal switch; W3's card render belongs there.

**What changed in the plan** (asked and confirmed, §10 W11 and W12): F10 and §4.7 row 36 now state the measured erasure and the guard; W2a gains the re-send-on-adoption guard; W2b keeps an explicit goal of 0; new §4.7 rows 85 and 86; W2 gains two mutations; W4's old-client test checks the guard live. The audit suite's one failing check is that measurement, expected to stay red until W2b.

### Phase W1 — `WorkWeek` core + behaviour-identical refactor

**Goal:** every week and goal calculation goes through one module, with only today's schedule in play. The app behaves **identically** to `0ba1bd6` (the golden master).

**W1a — the module** (a new section beside the weekly-goal constants, 16381):

```js
const WorkWeek = {
  version,                            // bumped by onScheduleChanged() (W2)
  defaults(),                         // today's schedule
  scheduleFor(dateKey),               // R1 (W1: always the current schedule)
  isWorkDay(dateKey), workDaysOf(week),
  weekOf(dateKey),                    // R3 → { startKey, endKey, days: [keys] }
  weeksInMonth(y, m), weekStartForYear(y),
  dayGoalSec(dateKey),                // R5, before leave
  weekTargetSec(week, leaveSet),      // R6
  countsToward(dateKey),
  autoGoalSec(dateKey, logsByDate, leaveSet),  // R7
  pace(...), expectedSoFar(...),      // R8
};
```

`getStandardDayGoalSec` stays as a thin alias (mutations and harness use it). `harness-workweek-core.js` covers every function against the golden master's arithmetic, R3's properties on the default schedule, and the year-boundary and DST weeks.

**W1b — the call-site migration** (mechanical, one concern). Every site in §4.1's table:

- `autoPopulateDailyGoal` keeps its early returns and writes; its arithmetic becomes `autoGoalSec`.
- The analytics worker and its fallback group by business date only (F7); `weeklyCache` is replaced by date lookups over `weekOf`.
- The live weekly card, `renderInsights`, `renderMacroInsights`, the heatmap and streak, the logbook tag and fallback, "This week", `getMonthlyWeeks`, `isViewingCurrentWeek`, `updateProgress`'s segment index and `resolveGoalSecForDate`'s fallback all read `WorkWeek`.
- The bar is built from `workDaysOf(week)` (five on the default).
- The wording stays "Weekend".

**Regression:** §8's list. **Golden master byte-identical.**

**Mutations:**

- R7 off by one day;
- `weekOf` ignores `weekStart`;
- the worker regains a Monday key;
- a leave day on a weekend counted;
- `dayGoalSec` divides by 5 regardless of work days;
- the trend subtracts today on a day off;
- the existing goal mutations (`mutation-test.js` 1448, 1461, 1474, 1488, 3530) re-anchored.

**Exit:** all green; `grep` finds no `diffToMonday`, no `getUTCDay() === 0 || … === 6` and no `for (let i = 0; i < 5` outside `WorkWeek`; anchors 0 misses.

**Commits:** `refactor(week): one module for every work-week calculation` (W1a) and `refactor(week): route every call site through WorkWeek` (W1b).

#### Phase W1 results (2026-09-15)

All runs on AC power at 2419 MHz, one suite at a time.

**Baseline on the unmodified tree** (`index.html` md5 `1ad7e159`): the §8 regression list, 19 of 19 green (`harness-phase8.js` died with exit 127 in the chain before any check and passed alone, 14 checks); the golden master, 300 sets compared, 0 differ.

**W1a — the module** (`3f127b6`, md5 `c32ebfe9`, +262 / −2 lines). `WorkWeek` sits right after `getWeeklyGoalSec`, and `getStandardDayGoalSec` is now its alias. The API as built, with the names the call sites needed where they differ from the sketch above:

- `defaults()`, `scheduleFor(dateKey)` (W1: always today's schedule, rebuilt only when the weekly goal moves);
- `dayNum(key)`, `keyOfDay(n)`, `dayOfMs(ms)`, `weekday(key)`: all arithmetic is on day numbers, whole days since 1970-01-01, so no zone or DST can move a boundary;
- `isWorkDay` / `isWorkDayNum`, `countsToward` / `countsTowardNum`;
- `weekOf(key)` / `weekOfDay(n)` → `{ startDay, endDay, startKey, endKey, startMs, days, keys }`; `startMs` is noon UTC on the first day, the instant every week was keyed by before;
- `workDaysOf(week)`, `workDayIndex(key)` (the weekly bar's segment, memoised for the tick, added in W1b), `weeksInMonth(y, m)`, `yearGrid(y)` (for "weekStartForYear");
- `workDayGoalSec`, `dayGoalSec` (R5 before leave), `targetOf(keys, leaveSet)` (R6 over any list of dates, for "weekTargetSec"), `workDaysInRange(from, to)`;
- `autoGoalSec(key, logs, leaveSet)` (R7 in exactly today's expression order, so fractional seconds round as before), `expectedSoFarSec` and `remainingWorkDays` (R8, for "pace" and "expectedSoFar").

`harness-workweek-core.js` (new, no account, 8886 / 9487) checks every function against copies of the 0ba1bd6 inline arithmetic kept in the suite, over every date of 2026–2028 at seven weekly goals (40, 37.5, 20, 15, 1, 168, 0.5), random histories with fractional work and leave, and the year-end, DST and Saturday-leave weeks, plus "asking anything writes nothing" (F2) and two controls: 71 checks, 0 failures. Golden master 300 / 0 differ; control 240 / 300; regression 19 / 19.

**W1b — every call site** (`3b9a873`, md5 `1bedca19`, +202 / −504 lines against W1a):

- `autoPopulateDailyGoal` keeps its early returns and writes; its arithmetic is `WorkWeek.autoGoalSec`.
- The analytics worker and its fallback group by business day only (F7). `weeklyCache` became `dailyCache` (day number → that day's logs), and `logsForWeek(week)` joins a week's days newest first, which is exactly the order a week's group had.
- The live weekly card, `renderInsights`, `renderMacroInsights`, `isViewingCurrentWeek`, `updateProgress`'s segment, the "This week" filter, the logbook tag and fallback, `isLogOver`, and the heatmap grid and streak all read `WorkWeek`. The weekly bar is built from `workDaysOf(week)`, with labels from the day's initial. The wording stays "Weekend".
- Removed: `calculatePeriodGoalStats`, `getMonthlyWeeks`, `WEEKLY_GOAL_WORKDAYS`; `WEEKEND_GOAL_RATIO` moved into `WorkWeek`.
- Exit greps: 0 `diffToMonday`, 0 `=== 0 || … === 6`, 0 `for (let i = 0; i < 5`, 0 `getUTCDay() === 0`, 0 `weeklyCache`. The two `isoDay` left are the date picker's.
- Tests: `harness-workweek-core.js` 78 / 0 (adds `workDayIndex` and `weekday` over every date in turn); golden master `compare --expect=w1` 300 / 0 differ; `probe-workweek-eviction.js` 6 / 0; regression 18 / 19 in the chain, with `harness-handoff.js`'s "a follower refuses a corrupt anchor" failing and then 24 / 24 alone (the check the harness notes list as sensitive to the check before it). Golden control: 252 of 300 sets differ (240 before; the 12 more are the "behind" logbook sets, whose no-goal rows now follow the day's goal, so a longer week reaches them). Mutations: 9 GOOD, 0 BAD (below).

**The two differences W1 makes on purpose** (both the user's decisions):

1. **§4.7 row 40:** a logbook row with no `dayGoal` is measured against the day's goal, not a hardcoded 8 h, and `isLogOver`'s last fallback follows. It is the golden master's only difference: the "behind" pattern's Thursday rows at 37.5 / 20 / 15 h read 45m / 4h 15m / 5h 15m instead of 15m. `compare --expect=w1` expects exactly that and nothing else.
2. **Every week keeps its history (decision W13).** Measured on `3f127b6` with `probe-workweek-eviction.js`: 70 weekly 8-hour shifts, and the weeks 61–70 back read "0h / 40h" with an empty monthly row, because the weekly cache kept only the newest 60 weeks. After W1b those weeks read "8h / 40h" and their monthly row "W 8h … 1 Shift". The cache holds references to logs already in memory.

**Harness changes made on the way:**

- The golden probe's premise counts weeks from the logs (there is no `weeklyCache` after W1b), and its control now patches `getWeeklyGoalSec` (+300 s), which both builds call; the control still finds 240 / 300 sets different on 0ba1bd6.
- **Leave-record rows are compared without their hidden stats.** The logbook reuses row nodes, and a leave row hides its stats with CSS (`.log-row.is-leave-row .log-stats-group { display: none }`) without writing them, so those nodes keep the text of whatever row used them last. W1b's first comparison caught a Saturday leave row carrying the no-goal row's delta. Those four fields of leave rows are left out on both sides.
- `probe-workweek-golden-quick.js` runs three pages of the golden master with `--expect=w1` for `mutation-test.js`, which runs every harness without arguments. `run-followups-regression.sh` now passes `compare` to the golden probe.
- The per-page runner re-ran one crashed page (Windows 0xC0000409, before any result) in three of the five full golden runs; no result was ever re-run.

**Mutations:** #99 and #100 (the standard day and the weekend's flat six hours) were re-anchored onto `WorkWeek.autoGoalSec`; seven were added: the automatic goal counts today as already worked; a week starts on Sunday regardless; leave on a day off takes its goal away; the worker files a day's logs under the next day; the live card takes today's work off the trend on a day off; the analytics cache forgets old days again; a no-goal logbook row is measured against 8 h again. **All 9 graded GOOD, 0 BAD, 0 SKIP** (21:17–21:23, on AC; `index.html` and `sw.js` restored byte-identical after each). **Deferred to W2**, because no suite can see them while only today's schedule exists: "the worker regains a Monday key" (with Monday-start weeks a week's logs grouped under its Monday are the same logs) and "a work day divides the weekly goal by 5".

**§4.7 rows asserted in W1:** 1 (the golden master), 19 (weekend work excluded: the golden "weekend" pattern), 21 (catch-up on the next work day: core and golden "behind"), 25 (leave on a work day: core `targetOf` and golden), 31 (the week across 12/31: core), 32 (the weekday comes from the business date only: all `WorkWeek` arithmetic is on the date key), 40 (above).

### Phase W2 — The schedule: preference, history, the generalised rules

**W2a — the preference and history:**

- `WORK_WEEK_KEY`, `isWorkWeekPref` (§4.3), and `PREF_KEYS.workWeek`.
- `buildBackupPayload`, `finalizeImport` and the import validator, and `purgeFactoryKeys`.
- `scheduleFor` and `weekOf` honour history and transition weeks (R1–R3).
- Archiving on change (R4), including `onWeeklyGoalChange`.
- `onScheduleChanged()` (F8).
- **The old-build guard (decision W11):** when adopting a settings blob that lacks `workWeek` while this device holds one, mark settings edited so the next beat re-uploads the whole blob. Declared as a `resendIfMissing` flag on the `PREF_KEYS` entry, so C1's and D1's preferences reuse it.
- A JS-level API for tests (`WorkWeek.setSchedule(next)`), no UI yet.

**W2b — the generalised rules:**

- any work days;
- day-off goal (R5), counts (R6), `"spread"` (R7);
- pace, expected and trend (R8);
- streak and heatmap (R9);
- the guards: work-day goal ≤ 24 h, at least one work day;
- **an explicit goal of 0 is kept (decision W12):** `hydrateLogsInChunks` and `rehydrate` fill in only a missing `dayGoal`, never a 0. Records already rewritten stay as they are. `probe-workweek-audit.js`'s measured check turns green.

`harness-workweek-model.js` covers §4.7 rows 2–41, 85 and 86 through the API, storage diffs for F2, hostile blobs through the stub, import and wipe.

**Regression:** §8's list; the golden master still byte-identical with no preference written.

**Mutations:**

- archive written on every edit (not once per week);
- `until` uses the new schedule's week;
- the validator accepts empty `workDays`;
- `"spread"` divides by all remaining days including leave;
- counts ignored in the trend;
- the day-off goal ignores `dayOffGoalHours`;
- a default written at boot;
- the old-build guard re-sends nothing;
- a goal of 0 filled in at load;
- deferred from W1, visible only with another schedule: the worker regains a Monday key; a work day divides the weekly goal by 5.

**Exit:** all green; rows 2–41, 85 and 86 asserted; anchors 0 misses.

**Commits:** `feat(week): a work-week schedule that keeps past weeks` (W2a) and `feat(week): day-off goals, day-off work and catch-up modes` (W2b). **Deploy-safe:** without the UI nobody can write the preference, and an imported or synced one only moves numbers the model already proves.

#### Phase W2 results (2026-09-16)

All runs on AC power at 2419 MHz, one suite at a time.

**Baseline on the unmodified tree** (`index.html` md5 `1bedca19`): the regression list, 22 of 22 green. `probe-tz-ui.js`'s timing check "3 s of ticks on a settled page create no formatter" missed once in the chain and passed alone (149 checks).

**Decision W14** was asked while reading, before any code: the plan refused any schedule with a work day over 24 hours, but the weekly-goal field already allows 168 h on Monday–Friday. The limit now applies only when work days are chosen (§10).

**W2a — the preference and its history** (`99e6ff2`, md5 `0c808ece`, +473 / −39 lines):

- `WORK_WEEK_KEY` (`nodrift_work_week_v1`) and `isWorkWeekPref` (`WorkWeek.isValid`, the shape in §4.3, W14).
- `scheduleFor` answers from the history (R1); weeks run from the week-start day to the day before the next, clipped to their schedule's period, so a week-start change makes a transition week and no week straddles two schedules (R3). `weeksInMonth` steps week by week; `yearGrid` keeps seven-day columns in the week start that governs Jan 1 (R9).
- `WorkWeek.change(changes, todayKey)` (R4): the first change in a week archives the values from before it with `until` = the day before the week's start under the old schedule; later changes that week only replace the current values; unknown keys are kept (W10); choosing work days that make a work day over 24 h is refused (W14). `restore` (backups), `setSchedule` (the test door until W3), `invalidate`, `renderKey`.
- Sync: `PREF_KEYS.workWeek` with `schedule: true` (applying it runs `onScheduleChanged()`) and `resendIfMissing: true`. **The old-build guard (W11):** `adoptSettings` calls `Sync.resendMissingPrefs` after taking its baselines; a device that adopts a blob without a schedule it holds (and holds validly) marks its settings edited, stamped after the adopted blob. Only an absent value triggers it: a value present but invalid here may come from a newer build.
- Backups carry the schedule, an import restores a valid one whole and leaves an invalid one out (F4), a factory reset erases it. A weekly-goal edit goes through `WorkWeek.change`. `onScheduleChanged()` (F8) moves the version, re-populates today's automatic goal when no shift is running (F6) and redraws; the insights cache key and the logbook row key carry `WorkWeek.renderKey()`. The weekly day loop and the "This week" filter follow the week's own length.
- Tests: core 78 / 0; golden master 300 sets, 0 differ (no preference written, F2); eviction 6 / 0; regression 22 of 23 in the chain — `harness-progress.js` failed the two checks that W2's intended difference changes (below), then passed 26 / 26 alone once its dates moved; **`harness-workweek-model.js`** (new; HTTP 8888, CDP 9484 and 9489), 84 / 0 at W2a. Part 1, one device: nothing written or synced by default; 26 hostile synced schedules each skipped whole with the previous one kept, and 520 history entries accepted; junk in storage read as none; W14 both ways; R1, R3 and R5 on a known history with a transition week; R3's properties over 40 random histories (1 154 weeks); R4 over 115 random changes (no date before a change's week moved; short weeks only where the week start changed); rows 11–15, 28, 34, 35, 38, 44 and F6/F8. Part 2, a fake server transcribed from `0004_sync_session.sql`: this build, the real `0ba1bd6` build (`git show`) and a fresh device. The old build's theme change drops the schedule from the account; this build puts the whole blob back on its next beat; the two then settle (no upload over four more rounds); the old build keeps its theme; the fresh device receives the schedule and uploads nothing (rows 3, 4, 36, 86).
- Mutations: 9 GOOD (8 W2a and "a work day divides the weekly goal by 5", deferred from W1), and #99 / #100 re-graded GOOD on `harness-progress.js`'s moved checks.

**W2b — the generalised rules** (`c6337e6`, md5 `f6780b44`, +72 / −23 lines):

- R5: `dayOffGoalOf` — a typed day-off goal is that many hours whatever the weekly goal (P-W14), unset is three quarters of a work day, 0 is none.
- R7: work on days off comes off what is owed when the schedule counts it; `"spread"` shares what is owed over the work days left that are not leave, today included, and on the last of them asks what `"next"` asks. With the defaults the arithmetic is the same expression as before (golden master identical).
- F5: `resolveGoalSecForDate`'s fallback for a past date without a saved goal is that date's own work day; the heatmap's leave-only day takes R5's goal.
- **W12:** `rehydrate` and `hydrateLogsInChunks` fill in only a missing `dayGoal`; a 0 is kept.
- The weekly bar is rebuilt when the work days change, not only their count.
- Tests: core 78 / 0; golden master 300 / 0; eviction 6 / 0; **`probe-workweek-audit.js` 11 / 0** — "the stored goal of 0 survives a reload" is green (0 when filed, 0 after the reload); model suite 114 / 0 (part 3, the rules on a device of its own: rows 2, 5–8, 10, 17–20, 22–24, 26, 29–31, 39, 41 and the F5 fallback; R7 against a brute-force reference over 300 random schedules and 4 500 dates in both catch-up modes, 0 differ; `"spread"` never negative and landing exactly on the target in 197 random weeks; the worker filing logs by their own day in a Sunday-start week; the live card's trend with day-off work counted; part 2 adds rows 36 and 85's pull); regression 24 / 24 in the chain (01:46–01:56).
- Mutations, all GOOD in the end: "the worker regains a Monday key" (deferred from W1; a Sunday log of a Sunday-start week lands outside its week) and the eight W2b ones — `"spread"` sharing what is owed over leave days too; day-off work never counted; the day-off goal ignoring the hours typed for it; a goal of 0 filled in at load again (graded by `probe-workweek-audit.js`) and at pull again; the live card's trend ignoring whether day-off work counts; a past date's fallback on today's schedule; the weekly bar keeping its old days. That last one was first graded BAD: its check changed the number of work days as well as which ones, so the bar was rebuilt anyway, and the mutation was caught only by row 10. The check now changes the days and not their count (Sun–Thu to Mon–Fri) and both fail under the mutation. The re-anchored #100, "leave booked on a day off" and "the automatic goal counts today" were re-graded GOOD.

**The difference W2 makes on purpose** (decision W7, §4.7 row 14): a weekly-goal edit applies from the week it is made in, and a week that has ended keeps its own target. `harness-progress.js`'s "the arithmetic, on dates that cannot drift" used fixed dates in August 2025 and edited the goal today, so after W2a those past weeks kept 8 h: its dates moved to the same days of 2031, and a new check holds a 2025 Monday at 8 h through the edit (26 checks).

**Harness changes on the way:**

- The model suite's part 2 launches a browser on a port part 1 had just left. Under the mutation runner's load one came up with no page target, the suite crashed before its first part-2 check, and "the old-build guard re-sends nothing" was graded BAD for the wrong reason. The suite now retries a launch up to three times and pauses after closing a browser; the mutation was re-graded GOOD.
- Rows 17 and 2 first froze a running shift at a goal of 0 (the day already held a shift filed with 0), which could not fail; they now freeze 7 h 30 m.
- Mutation anchors moved with the code: #169 (the logbook row key now ends in the work week's key), "a week starts on Sunday", #100, "leave booked on a day off", "the automatic goal counts today"; each re-graded.
- `run-followups-regression.sh` also runs `harness-workweek-model.js` and `probe-workweek-audit.js`.

**Not changed, for W3:** a day whose saved goal is 0 still colours the heatmap as exceeded (work ÷ 0) and reads as overtime; P-W16's "No goal" is W3's. The progress, tooltip and yearly baselines keep today's schedule, because they are about today.

**§4.7 rows asserted in W2:** 1–20, 22–24, 26, 28–31, 33–36, 38, 39, 41, 44, 85 and 86. Rows 27, 42 and 43 belong to W3, row 37 to W4; rows 21, 25, 32 and 40 were W1's.

### Phase W3 — Work week UI

**W3a** — the Work week card, its phone sheet section, chips, selects, the day-off input, the switch, toasts with Undo, the 24 h and one-day guards' messages, disabled rows at seven days.

**W3b:**

- the weekly bar with N segments;
- "Day off" wording (P-W11) and the "No goal" state (P-W16);
- the leave-on-a-day-off toast;
- week arrows over transition weeks;
- the guide rewrite.

`probe-workweek-ui.js`:

- real clicks and keys on desktop and at 375 px;
- computed display (I13), and no inline `display` under `.main-ui`;
- geometry for rows 42 and 10;
- the undo round trip byte-identical;
- `textContent` only (I14).

**Regression:** §8's list plus `harness-motion.js` and `harness-cloud-panel.js` geometry.

**Exit:** rows 8–10, 16, 18, 26, 27, 30, 42, 43 asserted; the golden master byte-identical apart from the wording rows it names; anchors 0 misses.

**Commits:** `feat(week): the work week settings card` (W3a) and `feat(week): insights, the bar and the guide follow the schedule` (W3b).

#### Phase W3 results (2026-09-19)

All runs on AC power at 2419 MHz, one suite at a time.

**Baseline on the unmodified tree** (`index.html` md5 `f6780b44`): the regression list, 24 of 24 green, with no in-chain failure at all — `probe-tz-ui.js` managed 149 of 149 inside the chain this time, having needed a solo run at W2's baseline.

**W3a — the settings card** (`4d44464`, md5 `c073dce5`, +724 / −12 lines):

- A `Work week` card directly under the tracking card whose weekly goal it divides: seven chips in week-start order (two letters, with the day's full name as the `aria-label`), the week start, a `Per work day` read-out, the goal on a day off with `Auto` beside it, the day-off work switch, and the catch-up mode. One node for both layouts: the phone sheet borrows it into a new `Work week` section above Time Zone, so nothing in the card is shown or hidden with an inline `display` — a row with nothing to answer takes a class and stays laid out (I13).
- Every control goes through one path, which asks `WorkWeek.change` to archive the week that is ending (R4), runs `onScheduleChanged()` (F8), redraws the card and raises a toast with an **Undo**. Undo writes back the bytes that were in storage before the edit rather than a schedule rebuilt from the card: a history another device wrote, or a key a later version added, returns exactly as it was found, and so does the absence of any preference at all (F2). `WorkWeek.snapshot()` and `restoreSnapshot()` are that primitive; `dayOffGoalSec()` answers the placeholder behind an empty field, so the ¾ ratio stays inside the module (F3).
- The weekly goal beside it now offers the same Undo and says which week it applies from, keeping the words it had, so `harness-progress.js`'s existing assertion still holds.
- The guards say why: a choice that would ask more than 24 hours of one day is refused (W14), the last work day cannot be switched off, seven work days leave the day-off rows with nothing to answer and a note saying so, and a running shift keeps the goal it started with (F6).
- The one toast that had an Undo hard-wired into it now takes the way back from its caller, and the rule keeping that button its size reaches it by class rather than by id, because there are two of them now.
- Tests: **`probe-workweek-ui.js`** (new; HTTP 8889, CDP 9480, no account), 82 / 0 at W3a — the defaults with a storage diff (F2), a chip with its toast and an Undo back to no key, an Undo of a planted schedule carrying an unknown key and a history (byte-identical, 281 bytes), rows 9 and 8, the field, `Auto`, the switch and catch-up, the week start with its transition note, row 16, the weekly goal's own Undo, 375 px (borrowed into the sheet, seven chips on one line, 44 px targets, a real tap's aim), and the return to the desktop after a reload. Regression 24 of 25 in the chain; golden master 300 sets, 0 differ, so the card changes no figure. Mutations: 8, all GOOD.

**W3b — the wording, the bar, the guide** (`75e8372`, md5 `9eb082b4`, +228 / −92 lines):

- P-W11 throughout: `Day off` in the logbook's context tag and the insights row, `.badge-weekend` renamed with it, and the identifiers that named a weekend renamed too (§2). The monthly and yearly badge now tracks work on a day off separately from whether that work counts, so it appears either way and its tooltip says which.
- P-W16: a goal of 0 is a day that asks nothing. The badge reads `No goal`, the line below says what was worked instead of a percentage of nothing, the session and day percentages fall to 0 rather than 100, no finishing time is estimated, and the heatmap colours the square for having been worked rather than for being past a target that was never set.
- W8: booking leave on a day off says that it changes no goal. Row 43: the week arrows ask the schedule where the neighbouring week begins instead of stepping seven days.
- The guide gains a `Your work week` section and drops its assumption that a week is Monday to Friday.
- Tests: `probe-workweek-ui.js` 105 / 0 (sections 12–15 add the wording end to end, P-W16 including the heatmap, the leave toast with a work-day control, and row 43); regression 24 of 25 in the chain — `harness-signin-render.js` failed "signing in to an empty account uploads nothing" and passed 13 / 13 alone, the live-suite-in-chain pattern already recorded twice; golden master **300 sets, 0 differ under `--expect=w3`**; model 114 / 0, audit 11 / 0, core 78 / 0, eviction 6 / 0, `probe-tz-ui.js` 149 / 149. Mutations: 9, all GOOD.

**The differences W3 makes on purpose**, named in the golden master's `--expect=w3` and nowhere else:

- `Weekend` becomes `Day off` in the logbook tag and the insights row, with `.badge-weekend` becoming `.badge-day-off`;
- `N Weekends` becomes `N Days off worked`, and its tooltip `worked on N weekend days` becomes `worked on N days off`;
- a day whose goal is 0 reads `No goal · 0m worked` where it read `0.0% (Overtime: 0m)`. The golden master's `ahead` pattern contains such days — work days whose automatic goal lands on 0 because the week is already met — so P-W16 reaches further than the day-off goal it was written for. That is the rule as stated: it is about the goal, not about why it is 0. **Superseded in W4 by decision W16**, which restricted it to days off; with that, the third difference below disappears and the golden master matches byte for byte again.

**Decisions taken during the phase:** W15 (one letter per bar segment) and the `N Days off worked` wording; both in §10, both asked before the code was written and after the golden master measured what the alternative would cost.

**Harness changes on the way:**

- `probe-tz-ui.js`'s phone check asserted the sheet's section order and now expects `Work week` between `Goals` and `Time Zone`.
- `probe-leave-rows.js` looks for the `Day off` tag and `.badge-day-off`.
- `probe-workweek-golden.js` gained `--expect=w3`, which rewrites the fixture by exactly the rules listed above; `run-followups-regression.sh` and `probe-workweek-golden-quick.js` pass it, and the runner's list gained `probe-workweek-ui.js` (25 entries).
- A mutation graded BAD for a reason worth keeping: the bar check called `renderInsights()` inside its own reader, so it repaired the omission it was meant to catch. A check of a redraw must never redraw. Three more traps, all in the probe: records live in IndexedDB, so clearing `localStorage` left an earlier section's shift behind and locked today's goal to its anchor; a logbook row has a badge slot at each end and writes whichever the header leaves free, so the first one in the DOM is as likely to be the empty spare; and a seven-day step lands in the right week from inside a short week, so the week-arrow check has to cross the transition week from the later side or its mutation cannot fail.

**§4.7 rows asserted in W3:** 8, 9, 10, 16, 18, 26, 27, 30, 42 and 43. Row 37 remains W4's.

### Phase W4 — Work week sync hardening, multi-device, iPhone

- Live suites with the test account:
  - two devices race a schedule change (row 37);
  - a fresh device uploads nothing (rows 3–4);
  - an old `0ba1bd6` client beside a new one: the guard puts the schedule back and a fresh device receives it (rows 36, 86; extends `probe-workweek-server.js`);
  - a handoff mid-shift after a schedule change (F6).
- **iPhone checklist for the user** (tap-by-tap, written at the time from the real labels):
  - change work days, then undo;
  - the day-off goal;
  - week start;
  - see last week unchanged;
  - leave on a day off;
  - revert everything.

**Exit:** all green; the user's checklist recorded here. **Commit:** docs, plus `fix(week): …` only if a defect is found.

#### Phase W4 results (2026-09-19 / 20)

All runs on AC power at 2419 MHz, one suite at a time.

**Baseline on the unmodified tree** (`index.html` md5 `9eb082b4`): the regression list, 25 of 25 green, with no in-chain failure at all.

**The live suites.** `probe-workweek-server.js` was W0's measurement of whether an account could hold a schedule at all, and it could no longer run: its second part patched a `workWeek` entry into the `0ba1bd6` build to stand in for a build that syncs one, and refused to start unless `index.html` was that build. That build is this one now, so the roles were reversed — this checkout serves as the new build and `ww-old/`, rebuilt from `git show 0ba1bd6:index.html` on every run, as the old one. Part 1, the REST round trip of a nested schedule, is unchanged. **38 checks, all pass**, on the live test account:

- **Row 4.** A device signed into an account that holds no schedule writes no key and uploads none: the account's settings keys are the nine it always had, with no `workWeek` among them (F2). A schedule chosen here then reaches the account whole, history included.
- **Rows 36 and 86, live.** The `0ba1bd6` build uploads a theme change and the account's copy loses the schedule — the W0 measurement reproduced, and now the premise rather than the finding. This build adopts that blob, keeps its own schedule and sends the whole blob back on its next beat: 282 ms later the account holds both the schedule and the old build's theme (decision W11). Four more rounds of beats from both builds change nothing, so the two settle rather than argue. A weekly-goal edit on the old build then writes no archive: this build takes the new number, keeps its history entry, and puts the schedule back again.
- **Row 3.** A fresh device signing in afterwards receives the schedule, reads it identically to the first device, and the account's stamp does not move.
- **Row 37**, twice. Two devices change the schedule without seeing each other, and every field of one differs from the other's, so "the winner's schedule, whole" is distinguishable from any mix of the two field by field. The later edit wins on the account and the loser adopts it entire. Then an edit stamped **before** the winner's is uploaded **after** it, and is refused whole: the account keeps the winner's stamp and takes no field from the refused device, which adopts the winner's schedule instead. Four more rounds of beats change nothing.
- **F6 and row 16, live.** A shift starts on one device with today's goal frozen at 4 h 30 m; the schedule changes on the other device, mid-shift; the running shift keeps the frozen number while the new schedule would ask 1 h (the control). The other device then takes the shift over and reads the same frozen goal and the same elapsed time to within a second — the goal travels with the shift, not with the schedule. Once the shift ends, the next populate asks the new schedule's 1 h.

Two faults of the harness's own on the way, both worth keeping: the row stores `settings_modified` as a timestamptz string while a device stamps wire milliseconds, so comparing the two forms directly is always false; and the two racing edits were five milliseconds apart, close enough for two devices' clock offsets to invert them, so they are spaced deliberately now and the premise asserts the order either way.

The suite is the last entry of `run-followups-regression.sh` (26): a live suite's shared-account failure is then easy to re-run alone. In the chain it passed 38 of 38 in 21 s.

**The one app change: decision W16.** P-W16 as W3 shipped it reached every goal of 0, and W3's results recorded that this was wider than the wording suggested. Asked, the user restricted it to days off. The badge's "No goal", the empty bar, the zero percentages, the missing estimate and the heatmap's "worked" shade now belong to a day off whose goal is 0; a **work** day whose goal comes out 0 — the week already met, or the day on leave — keeps the percentage line, the full bar and the heatmap ladder every build before W3 showed. One flag carries it in `updateProgress` (`dayAsksNothing = !WorkWeek.isWorkDay(todayStr)`), the three percentages get their old three-way arithmetic back, and the heatmap enters its ladder for a work day whatever the goal is. Committed alone as `676976f fix(week): a goal of zero reads as no goal only on a day off`.

**What that measured.** With the rewrite rule for the 0-goal line removed from the golden master, `compare --expect=w3` reports **300 sets, 0 differ**: the build is byte-identical to `0ba1bd6` again, and the only difference W3 still makes on purpose is the "Day off" wording. The rule is gone from `--expect=w3`, which is now that wording and nothing else.

**Tests after the fix** (md5 `bde9f557`): `probe-workweek-ui.js` **110 / 0** — a new section 13b puts today's one work day at 8 h (40 would break the 24-hour rule), takes the goal over by hand at zero, and asserts the old reading end to end: badge "Goal", `100.0% (Overtime: 2s)`, a full bar, `heatmap-exc`. Mutations: the two W3b entries whose code moved were re-anchored and re-graded GOOD, the other seven W3b entries re-graded GOOD unchanged, and two new `W4:` mutations — "a goal of zero reads as no goal on a work day too" and "a work day with no goal is coloured as worked rather than exceeded" — are both caught by that section. **339 mutations, 0 anchor misses.** The 26-suite regression list: 25 green, with `probe-tz-picker.js`'s known flaky "the first open at 4x paints within 100 ms" (145.1 ms in the chain) passing **176 of 176 alone**; `harness-signin-render.js`, red in the chain at the baseline, was green in this one.

**Deployed.** On the user's word, `0ba1bd6..676976f` was pushed — twelve commits, W0 to W3 plus this fix — because the iPhone checklist could not run otherwise: production was still `0ba1bd6`, which has no work week at all. Production served md5 `bde9f557`, identical to the tested file, ten seconds after the push. This is the first deploy since 2026-09-15, and the work week is live.

**The iPhone checklist** (the user, on the installed PWA, 2026-09-19/20). The card as first opened: chips `Mo Tu We Th Fr`, week starts on Monday, per work day `8h`, an empty day-off box showing `6h` as its placeholder, the switch off, catch-up "Next work day" — the defaults, drawn from nothing stored. Reported working exactly as written: a chip with its toast and **Undo**; the day-off goal typed, then `Auto` returning it to the placeholder; the week start with its transition-week note; and booking leave on a day off, which said so and changed no goal.

Step 5 — "last week does not move" — was reported as doubtful and was then measured rather than argued. A diagnostic, `diag-w4-lastweek.js` (8890 / 9490, no account), files eight hours on every work day of this week and last week and drives the card's own chip and the real week arrows, on the desktop layout and at 375 px: last week reads `Week of Sep 7 · M T W T F · 40h / 40h (100%) · 5 rows` before the change, with Saturday added, and after it is taken away again — identical all three times, on both layouts — while this week goes `M T W T F` → `M T W T F S` → `M T W T F`, keeps its 40 h target and moves its status line from "0.0h ahead" to "6.7h ahead", which is what six work days expect by a Saturday. The stored schedule ends with one archive entry, `until: 09/13/26`, holding the old Monday-to-Friday week. Two phone-only controls explain what a reading can look like without anything having moved: **a horizontal swipe on the day list changes the week** (60 px across, under 40 px down), and **a double tap on the date label jumps back to the current week**. Told to read the date label at each step and to use only the arrows, the user confirmed the behaviour. Step 7, the optional mid-shift check, was not run; the live suite covers F6 end to end.

Worth recording: running the checklist leaves the device holding a `nodrift_work_week_v1` preference whose current half is the default and whose history holds one entry. That is the design (R4, W13) — F2 promises only that nothing is written until the user changes something, and they did.

**§4.7 rows asserted in W4:** 3, 4, 16, 36, 37 and 86, plus F6 end to end and F5 on the phone. Row 37 was W4's alone.

### Phase C1 — 24-hour clock

§5.3 in one phase:

- the preference, styles and funnel;
- screens, typing and exports pinned to 12-hour;
- the row "Clock: 12-hour / 24-hour" in the renamed "Time and date" card (P-F1);
- the guide's typing section.

`harness-formats.js` covers rows 45–54, storage diffs, and CSV / email byte-identity across both modes. `harness-progress.js`'s `ETA_SHAPE` gains the 24-hour form.

**Mutations:**

- CSV uses the screen formatter;
- `hour12: false` instead of `h23`;
- a 24-hour string stored by manual entry;
- the kept-instant check compares strings.

**Exit:** all green; anchors 0 misses. **Commit:** `feat(time): a 24-hour clock`.

#### Phase C1 results (2026-09-20)

**Power, and what it cost.** The laptop came off AC during the baseline run and stayed off it: the CPU dropped from 2419 MHz to 1007 MHz partway through the phase. Every functional suite was unaffected. The one suite that was is `probe-tz-picker.js`, whose six 4×-CPU-throttle budgets failed **on the unmodified tree, before a line of C1 was written** — the full index took 4525 ms against a 1.5 s budget, and the first open 694 ms against 100 ms — where the same suite was 176 of 176 on AC in W4. So the C1 baseline is **25 of 26**, with the 26th a power reading rather than a code one; it is the one measurement this phase leaves open, and it belongs to the machine, not to the build. Asked with that in hand, the user chose to grade C1's mutations on battery: all twelve are graded by `harness-formats.js`, which contains no timing check, so nothing about a verdict depends on the clock speed. `harness-phase8.js`'s in-chain exit 127 was the usual launch death — 14 of 14 alone.

**The shape of it.** One resolver and one funnel, as §5.3 asks.

- **`clockStyle(style)`** maps the four styles that show a clock time — `time`, `timeOnly`, `hm`, `clock` — to their `h23` twins when the preference says so, and hands back anything else unchanged. Nothing else in the build reads the preference key, and nothing else decides. `clockFormat()` holds the value in a module variable rather than reading `localStorage`, because the status bar clock asks it every second.
- **`onDisplayFormatChanged()`** is the only way it changes: it drops the cached preference, bumps a version that `zoneRenderKey()` now carries — so the logbook rows, the task rows, the insights key and the today-row cache all redraw — clears the formatted-time memo and the three formatter caches the clocks, the estimate and the idle dialog hold, then redraws. Deliberately narrower than `onZoneContextChanged()`: no date realigns and no shift changes zone, because nothing about the day has moved, only the way a time is written down.
- **The preference** is `nodrift_clock_format_v1`, `"12h"` or `"24h"`, absent meaning 12-hour. It syncs (decision S1) with `resendIfMissing`, for the same reason the work week has it: a build that predates it drops the key from the account when it wins a settings race, and this one puts its own back on the next beat (F10). It is in the backup, the import and the factory reset list.
- **What stays 12-hour (F1, F9, decision C2).** The two places a filed shift's `login` / `logout` strings are written ask for `"time"` literally, with a comment saying why. A typed value becomes a stored one through `storedTypedTime()`, at the two save paths and nowhere else. `exportTime()` and `exportTimeView()` are the export formatters, and the logbook CSV, the tasks CSV and both task copy buttons call them. The other copy buttons and the end-of-day email were audited and carry no clock time at all — only durations and dates.
- **Typing accepts both forms in either mode** (decision C1). One parse, `parseTypedClockSeconds()`, reads `0900`, `900p`, `9:30p`, `17:30` and `09:00:00 AM` alike; `parseClockTimePreview()` writes it back in the form on screen and `typedTimeToStored()` in the form a record keeps. `parseClockTimeToSeconds` and `parseTimeToMinutes` now take the AM/PM suffix as optional — a bare hour above 23 is not a time — so a field holding `17:30:00` reads everywhere a field holding `05:30:00 PM` did. **`keptTypedInstant` compares seconds rather than text**, so a dialog opened on one clock and saved on the other still counts as untouched and keeps its instant to the millisecond.
- **The card** is renamed **"Time and date"** (decision P-F1), on the desktop and as the phone sheet's section label, and the Clock row sits last in it, under "Show log times in". The empty `.clock-ampm` element loses its margin so the 24-hour status bar leaves no gap where AM/PM was.

**`harness-formats.js`** (ports 8891 / 9491, no account) is new and green at **43 of 43**, in nine sections: the default and its storage diff, choosing 24-hour through the real dropdown, midnight, the exports, typing and both dialogs, the DST gap sentence, eight hostile synced values, the resolver on every screen, and the phone at 375 px. It is the last entry but one of `run-followups-regression.sh`, before the live suite.

**§5.4 rows asserted:** 45 (the default, plus the golden master below), 46, 47, 48, 49, 50, 51, 52, 53 and 54, with F1, F2, F3, F4, F8 and F9 each carrying a check of its own.

**Tests.** `probe-workweek-golden.js compare --expect=w3`: **300 sets, 0 differ** — C1 changes nothing for a user who touches nothing, which is row 45 and §1's promise. `harness-formats.js` **43 of 43**. The rest of the list green: `harness.js` 80, `harness-progress.js` 26, `harness-security.js` 17, `probe-csv-shape.js` 15, `probe-backup-and-leave.js` 26, `probe-leave-rows.js` 12, `harness-tz-core.js` 86, `harness-tz-model.js` 28, `harness-tz-display.js` 129, `harness-wipe.js` 18, `probe-workweek-ui.js` 110, `harness-workweek-model.js` 114, and `probe-tz-ui.js` **149 of 149 alone** after two intended differences were written into it — the sheet section is "Time and date" now, and the card has five touch targets rather than four. `harness-progress.js`'s `ETA_SHAPE` accepts both clocks.

**Mutations: 351 in the file, 0 anchor misses, and every one of C1's caught.** Four entries whose code this phase moved — `keptTypedInstant`, `csvRowForLog`, the tasks CSV and the hover-help row list — were re-anchored and re-graded GOOD. Twelve new `C1:` entries were added and all twelve are GOOD. Three of them were BAD first, and each said something:

- **One mutation could not be caught by anything, because it broke nothing.** `_recordTimeMemo` is keyed on the formatter style, so a memo entry made in one clock format can never be returned in the other; the funnel's `_recordTimeMemo.clear()` frees memory and nothing more. It was replaced by a mutation on the line that _is_ load-bearing — dropping `window._lastClockMinCache = -1`, without which the status bar goes on reading the old format until the minute turns over.
- **Two were real gaps in the new suite**, closed with two checks: a dialog **opened on one clock and saved on the other** (the seeded login carries 437 ms, which only a kept instant preserves — a re-derived one lands on the second), and the manual dialog **working the missing finish time out from a bare 24-hour login**, which is the one live path that still hands `parseClockTimeToSeconds` a field without an AM/PM suffix, now that both save paths convert to the stored form first.
- **Both stayed BAD on the first re-grade for a reason worth writing down:** their `mustFail` patterns still named the checks they were written against. The runner grades a mutation by finding a _failing check whose name matches_ `mustFail`, so a new check that fails under the mutation proves nothing until `mustFail` points at it.

**Two measurements worth keeping.**

- **`hour12: false` is no longer distinguishable here.** §5.3 asks for `hourCycle: "h23"` because some engines render `hour12: false` as `24:05` at midnight. On the Chrome these suites grade against, `en-US` with `hour12: false` already resolves to `h23`: midnight reads `00:00:05` either way. The rule stays — it is the other engines it is for — but §9's fourth listed mutation cannot fail a check on this machine, so it is not in the list and two mutations covering the same code are. Recorded in §5.3.
- **A save-unchanged always moves three fields.** `lastModified`, `searchStr` and `_idx` are rewritten by every save at every build; row 48 is therefore asserted as "nothing but the save stamp moved", with a separate check that the rebuilt search index carries the **12-hour** times and not the 24-hour ones — which is the F1 claim the row was really making.

### Phase D1 — Date order

- **D1a** — the preference, `formatDateKey`, every shown date, exports, labels, placeholders and toasts; the backup untouched.
- **D1b** — `parseTypedDate` replacing both blur handlers and the save-path regexes; filters; search; the guide.

`harness-formats.js` covers rows 55–69, storage diffs, a DD/MM backup restored on the `0ba1bd6` build, and every typed input path in the three modes.

**Mutations:**

- the backup follows the preference;
- the ambiguous parse ignores the preference;
- the CSV date column stays MM/DD;
- the logbook short form built by slicing.

**Commits:** `feat(date): date order for everything shown and exported` (D1a) and `feat(date): typed dates and search follow the date order` (D1b).

#### Phase D1 results (2026-09-20)

**The measurement C1 left open is closed.** `probe-tz-picker.js` is **176 of 176** on AC, alone and in the chain. Its six failures during C1 were the four-times-CPU-throttle budgets reading a laptop that had come off mains, exactly as the C1 handoff said. Nothing was wrong with the build. The D1 baseline on the unmodified tree is **27 of 27** — every suite green, with `harness-signin-render.js`'s single in-chain failure its usual flake and 13 of 13 alone. On mains the two other standing in-chain flakes, `probe-tz-ui.js` and `harness-phase8.js`, did not flake either, and the golden master ran in 185 s against 346 s on battery.

**A bug found in the audit, and what it says about F3.** §6.1 records that a typed ISO date is accepted. It is not. Driving the real `handleDateInputBlur` on the unmodified tree:

| typed        | field became |
| ------------ | ------------ |
| `2026-09-15` | `09/30/15`   |
| `2026/09/15` | `09/30/15`   |
| `09/15/26`   | `09/15/26`   |
| `15/09/26`   | `09/15/26`   |
| `sep 15`     | `09/15/26`   |

The handler swaps the dashes for slashes before anything else, so the slash branch reads `2026` as a day number and the clamp pins it to the 30th. The _other_ copy of these rules — `parseDatePreview`, which draws the tooltip while you type — has a real year-first branch and gets it right. So the two copies of the date rules disagreed with each other, and the one that told the user what would happen was not the one that decided. That is F3's argument stated as a defect, and it makes §6.4 row 60 a fix rather than something to preserve.

**How the phase was split, and why it differs from §9.** §9 puts the labels, placeholders and toasts in D1a and `parseTypedDate` in D1b. They cannot be separated that way: every save path calls `handleDateInputBlur` and then re-reads the field, so a field showing `03/04/26` on a DD/MM screen would be re-read by the old device-region rule and filed as the wrong day. Shipping that would have been a commit that corrupts a date, and every commit here has to be deploy-safe. So the line moved: **D1a** is the preference, the resolver and every date shown and exported; **D1b** is typing, and with it the labels, placeholders, filters and search. That also fits the commit messages §9 itself chose — a label reading "Date (DD/MM/YY)" belongs with "typed dates follow the date order".

**The shape of it.**

- **`formatDateKey(key, form)`** is the one display function, in three forms: `full`, `short` (the logbook's row heading) and `weekday`. **`exportDate(key)`** is its export twin. Unlike a clock time, an exported date follows the preference, because decision D1 says an exported date is one the user reads, where decision C2 says a clock time is one a spreadsheet reads.
- **The default order is a pass-through, not a rebuild.** In `mdy`, `formatDateKey` hands the stored key back character for character and the short form is the same slice the logbook always took. This was measured, not designed: `probe-csv-shape.js` seeds a loose legacy key, `1/2/26`, and asserts the CSV prints it as it stands. A rebuilt-and-padded `01/02/26` broke it. §1 promises a user who changes nothing sees exactly what `0ba1bd6` gave them, and the only way to promise that for a key an old import left loose is to return the input rather than a rebuild of it.
- **`parseTypedDate(value)`** is the one parser and replaces both copies. `handleDateInputBlur` falls from 174 lines to a wrapper; `parseDatePreview` from 154 to 9. An unambiguous date reads the only way it can whatever the order; a year-first date is always taken; an ambiguous one follows the preference, and in YYYY-MM-DD mode follows the device's region as it always has (decision P-F2).
- **A field carries its own key.** The blur handler parses in the order that is on screen and leaves the stored key on the field as `dataset.dateKey`; every save path reads that rather than the text (F1), which is C1's `storedTypedTime` pattern applied to dates. The key is dropped first thing on every blur, so a field that stops parsing cannot keep a stale one and file the date the user just replaced. The three native pickers, the four task pickers and `CustomDatePicker` write the key on directly instead of round-tripping through the typed rules — which on a DD/MM screen would read `03/04/26` back as the 3rd of April.
- **The preference** is `nodrift_date_order_v1`, absent meaning `"mdy"`, and it rides C1's funnel: `onDisplayFormatChanged()` already drops the caches, bumps the version `zoneRenderKey()` carries and redraws, so the logbook, tasks, insights and heatmap follow without a reload (F8). It syncs on the clock format's terms and is resent when an older build drops it (decision S1, F10).
- **The backup does not follow it** (decision D2): every date inside stays `MM/DD/YY` and the file names stay year-first, so a backup restores on any build. The preference itself travels, so a restore brings the order back with it.

**Three things the new tests found, and each was real.**

- **The logbook row built its short form by splitting the key** — a second site, in the row loop, beside the one in insights that D1a had already fixed. Only a check that read the rendered rows found it.
- **The funnel redrew six things and none of them owns the leave list**, so leave dates kept the old order until the dialog was closed and reopened. `renderLeaveDatesList()` joined the funnel (F8).
- **The date picker's own value label built `MM/DD/YY` by hand** from the ISO string it had.

**Two traps in the tests themselves, worth writing down.** `harness-formats.js`'s last C1 section leaves the page on 375 px phone metrics and never restores the desktop, so every D1 check appended after it silently ran on a phone and the settings-card click landed nowhere — reported as "covered by nothing", which is what `elementFromPoint` returning null actually means: the point is not in the viewport at all. And a blind identifier rename inside a spliced block rewrites string literals too: renaming a local `gap` to dodge a collision turned `status === "gap"` into `status === "gapD1"`, and the check then failed for a reason that had nothing to do with the app.

**§6.4 rows asserted:** 55, 56, 57, 58, 59, 60, 61, 62, 63, 64, 65, 66, 67, 68 and 69, with F1, F2, F3, F4, F8 and F9 each carrying a check of its own.

**Tests.** `probe-workweek-golden.js compare --expect=w3`: **300 sets, 0 differ** — D1 changes nothing for a user who touches nothing, which is row 55 and §1's promise. `harness-formats.js` is **96 of 96**, up from 43, and now covers both format phases. The rest of the list green: `harness.js` 80, `harness-progress.js` 26, `harness-motion.js` 43, `harness-cloud-panel.js` 27, `harness-security.js` 17, `probe-csv-shape.js`, `probe-leave-rows.js` 12, `probe-backup-and-leave.js` 26, `probe-shift-rewind.js` 13, `probe-lease-endshift.js` 30, `harness-handoff.js` 24, `harness-tz-core.js` 86, `harness-tz-model.js` 28, `harness-tz-display.js` 129, `probe-tz-picker.js` 176, `probe-tz-ui.js` 149, `harness-phase8.js` 14, `harness-signin-render.js` 13, `harness-wipe.js` 18, `harness-workweek-core.js` 78, `probe-workweek-eviction.js` 6, `harness-workweek-model.js` 114, `probe-workweek-audit.js` 11, `probe-workweek-ui.js` 110 and `probe-workweek-server.js` 38. Two intended differences went into `probe-tz-ui.js`: the Time and date card's row list gains the Date row, and the phone's touch-target count is **six** rather than five. The closing run of the whole list was **27 of 27 with nothing failing in the chain at all** — on mains, not one of the three standing in-chain flakes appeared, and the md5 was identical at both ends.

**Mutations: 367 in the file, 0 anchor misses.** Sixteen new `D1:` entries, including all four §9 names — the backup follows the preference, the ambiguous parse ignores it, the CSV column stays MM/DD, and the short form built by slicing. Three were BAD on the first grading, and each named a real gap rather than a defect in the build:

- **The manual dialog's save path was never driven.** Every save check went through the edit dialog, so mutating the other save path broke nothing that was tested. Closed by filing a shift through the real manual dialog and reading the stored key back off the record.
- **The search's shape guard was graded with a word.** `parseTypedDate` refuses a word anyway, so removing the guard changed nothing. The guard exists for a term the parser _would_ read as a date — `9` is the 9th of this month to it — and the check searches for that now.
- **The date range was one both readings contain.** 1–3 January holds the day whether it is read day-first or month-first; 2–3 January holds it only day-first, and that is the range the check uses.

Two of the three also needed their `mustFail` pointed at the check that now catches them — the lesson C1 wrote down, which is that the runner grades a mutation by finding a failing check whose _name_ matches, so a new check proves nothing until `mustFail` names it.

### Phase Z1 — Re-filing a record in another zone

- **Z1a** — the audit of §7.1 (a manual marker), then the save path: the form's zone, kept instants carried across a re-fill, the date re-derived, chunks and anchors (rows 71–79).
- **Z1b** — the dialog row, picker, preview, both modes, tasks, placeholders, cancel, sync (rows 70, 80–84).

`probe-refile.js` covers the zone matrix × both modes × device zones, with byte-identity where promised.

**Mutations:**

- keep-moments recomputes instants;
- keep-written reads in the old zone;
- the date not re-derived;
- only the new month's chunk marked dirty.

**Commits:** `feat(time): re-file a record in another time zone` (Z1a) and `feat(time): choose a record's zone in the edit dialogs` (Z1b).

#### Phase Z1 results (2026-09-20)

**The audit §7.1 asked for, and what it settles.** §7.1 says records carry no "manual entry" marker and asks Z1a to find out whether anything reliable stands in for one, because P-Z4's default depends on it. Measured on the real build (`z1-probe-marker.js`, 10 checks):

- a shift filed by clocking in and out and one typed into the manual dialog carry **exactly the same seventeen fields** — `_idx`, `breakSec`, `date`, `dayGoal`, `diff`, `displayDate`, `epochMs`, `id`, `lastModified`, `login`, `loginEpochMs`, `logout`, `logoutEpochMs`, `notes`, `searchStr`, `tz`, `workSec`. None of them says how the record came to exist;
- the only signal in the numbers is the milliseconds on `loginEpochMs` — 582 for the tracked one, 0 for the typed one — and it is one-directional: a clock-in landing exactly on a whole second files a record with `loginEpochMs % 1000 === 0`, measured, indistinguishable from a typed one;
- there **is** one marker, and the edit dialog destroys it. `saveManualModal` writes the literal words "manual entry" into `searchStr` so a person can search for one; `saveEditModal` rebuilds `searchStr` without them, so **saving a manual record unchanged through the edit dialog erases the marker**. The one dialog that would read it is the one that wipes it.

So **P-Z4 stands as proposed**: both readings are offered for every record, keeping the real moments is the default, and nothing in this phase branches on provenance.

**A defect the audit found in the tree, and it is the phase's shape.** `typedFormZone(prefix)` already existed, and its comment already said it was "the zone a dialog's typed times are read in" — but only the live typing preview called it. Both save paths read `recordZone(record)` for themselves. Two copies of one concept, agreeing only by coincidence: exactly what §6 found in the two typed-date parsers. Z1a points the save paths at the one resolver, which is what lets a chosen zone reach the save without the preview and the save disagreeing about what it means.

**A shipped bug found on the way, fixed on its own (`9ce4801`).** Every `.modal-overlay` carries the same `z-index`, so which dialog paints on top fell to the order they happen to be authored in, and `#confirm-modal` is authored before `#edit-modal`. Measured with `elementFromPoint` at the prompt's own centre: **the overlap prompt the shift editor raises opens behind the editor that raised it**, so the screen looks stuck. It predates this work by a long way, and Z1 cannot function without fixing it, since the zone picker is authored before both edit dialogs. The open-order registry already knew the answer — it tracks which dialog opened last for the keyboard layer, with a comment saying neither DOM order nor z-index can stand in for it. That is equally true of painting, and for the same reason: a dialog nested under one authored earlier is unreachable, there by the keyboard and here by the eye. The rank is recomputed over the dialogs open at that moment rather than counted up forever, so it stays between 1 and the number of overlays and can never climb into the toast layer.

**The shape of it.**

- **`planRefile(record, zone, mode)`** is the one place either reading is worked out. The preview and the re-fill are the same answer rather than two, so a preview cannot promise one thing and the save do another.
- **Keeping the moments carries the instants explicitly**, in the shape `keptTypedInstant` already compares, because reading a re-filled time back out of the text would lose which occurrence of a repeated hour it came from. With a change pending, the record's own instants are never consulted: they belong to the old zone and cannot stand in for text read in the new one.
- **Re-filing is the one thing allowed to move a business date** (P-Z3, the single exception to I2) — and only where a real moment decided it in the first place. An end holding "Manual" or "Entry" never had one, so its date stays.
- **Which records are offered which reading.** "Keep the times as written" needs times that were written, so a record with a placeholder end is offered only the other reading (row 82). That is the only branch in the feature, and it is about what the record contains, not about how it was filed.
- **Already true, asserted rather than built:** `saveEditModal` marks the old month dirty at entry and the new one inside the save, so a record crossing a month marks both (row 76); `rebuildWeeklyCache` clears and refills `dailyAnchorMap` wholesale, so both days' anchors recompute and the record keeps its locked `dayGoal` (row 78); the overlap loop compares instants, so a moved record meets the existing warning (row 77).

**A pre-existing red on the unmodified tree, and it only shows on a Sunday.** The baseline was 26 of 27: `probe-workweek-ui.js`'s transition-week note read empty. The transition week runs from this week's start to the day before the new start day, so it holds _today_ only when the new start day still lies ahead inside the current week — `p < q`, where `p` is today's place in the week and `q` the length of the run the change leaves. With the default Monday start and a Sunday today, `p` is 6 and no allowed start gives `q > 6`: on a Sunday **no** week-start change can leave a short week containing today, whichever one the test picks. It now chooses the pair at run time, and reads 111 of 111.

**Four things the suite found, each a test bug rather than a defect, and each worth writing down.**

- **The save path refuses any date more than two days ahead**, so four seeds were being refused rather than tested. Every seed now sits behind today.
- **A fake server that echoes `last_modified` back as a number applies nothing.** The wire carries integer milliseconds, the column is a timestamptz, and `mergeRows` does `Date.parse(row.last_modified)` — a number parses to `NaN` and the row is skipped in silence. The same crossing of two domains W4 found in the settings stamp.
- **A zone picker row cannot be clicked through a dialog that paints above it**, which is how the stacking bug announced itself: the click landed on the edit dialog's header.
- **Splitting a CSS rule at a prefix takes the rest of the rule with it.** An edit that closed `.modal-overlay` after its `z-index` moved `display: none` into the new selector, so every hidden overlay fell back to a div's default and covered the page. The symptom is that `elementFromPoint` returns the _last_ overlay in the document for every click, and only the suites that click by coordinate notice.

**§7.4 rows asserted:** 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83 and 84, with F1, F3, F4 and P-Z3 each carrying a check of its own.

**Tests.** `probe-refile.js` is new (ports 8892 / 9492 and CDP 9493 for its second device) and is **68 of 68**: fifteen sections on one device, then row 81 against a fake server transcribed from `0004_sync_session.sql` — one upload, the row that goes up carrying the new zone and date, and the other device taking both and drawing the times in the record's zone. The regression list is **28 entries** now and ran **28 of 28 green in chain** (17:07:06–17:18:33, AC at 2419 MHz and md5 `afc90a43` at both ends), with the golden master `compare --expect=w3` at **300 sets, 0 differ** — Z1 changes nothing for a user who touches nothing. None of the three standing in-chain flakes flaked on mains.

**Mutations: 379 in the file, 0 anchor misses, and all twelve new `Z1:` entries GOOD on the first grading.** They include the four §9 names — keep-moments recomputing instants, keep-written reading in the old zone, the date not re-derived, and only the new month marked dirty — plus the two that grade the stacking fix, the placeholder branch, the pending change outliving its dialog, a zone taken on trust, a preview that never says the day moves, and a task re-filed in its old zone. Two existing mutations were re-anchored onto `typedFormZone`, since the save paths no longer name `recordZone` themselves.

### Phase R — Release

- Full mutation run on AC power, with the 9-class triage of `docs/implement.md` Phase 7 (re-grade every BAD alone on the work tree and on the previous commit).
- README and `SYNC-BLUEPRINT.md` (the new preferences and the schedule history).
- Guide sweep.
- An iPhone checklist for the clock, the date order and re-filing.
- This document's status line and table.

**Commit:** `docs: work week, clock and date formats`. Push only on the user's word, then verify production's `index.html` md5.

---

## 10. Decisions

**Confirmed on 2026-09-15:**

| #   | Question                                | Answer                                                                           |
| --- | --------------------------------------- | -------------------------------------------------------------------------------- |
| W1  | How work days are chosen                | Any mix of the seven; no presets (they take too much space)                      |
| W2  | Hours per work day                      | The weekly goal split equally                                                    |
| W3  | Goal on a day off                       | One setting, typed by hand; today's ¾ of a work day by default; 0 = no goal      |
| W4  | Does day-off work count toward the week | A switch, default off (today)                                                    |
| W5  | Week start                              | A setting: Monday, Sunday or Saturday; default Monday                            |
| W6  | Catch-up                                | A setting: next work day (default, today) or spread over the remaining work days |
| W7  | Past weeks after a change               | Keep their schedule; the change applies from the current week                    |
| W8  | Holidays, leave on a day off            | Leave as today; leave on a day off changes no goal and the booking says so       |
| W9  | The weekly bar                          | Work days only                                                                   |
| W10 | Rotating schedules                      | Out of scope; the stored shape leaves room                                       |
| C1  | 24-hour clock                           | A switch, default 12-hour; screens follow; typing accepts both                   |
| C2  | 24-hour clock in exports                | Exports stay 12-hour                                                             |
| D1  | Date order                              | MM/DD/YY, DD/MM/YY, YYYY-MM-DD; screens, typing and exports follow               |
| D2  | JSON backup                             | Keeps the stored form; file names stay year-first                                |
| Z1  | Re-filing                               | Chosen in the edit dialog with a preview; keep moments or keep written times     |
| X1  | More clocks, per-client zones           | Dropped                                                                          |
| P1  | Plan documents                          | One file for all features (this one)                                             |
| P2  | Order                                   | Work week, 24-hour clock, date order, re-filing                                  |

**Confirmed after Phase W0's measurements (2026-09-15):**

- **W11 — An older build erases the schedule from the account** when it wins a settings race. A new build that adopts such a blob sends its own copy back on its next beat (W2a). Rejected: accepting the gap until old builds update; a server-side merge migration.
- **W12 — A goal of 0 is kept.** The reload and sync fallbacks fill in only a missing goal (W2b). Rejected: leaving 0 to become 8 h after a reload.

**Confirmed during Phase W1 (2026-09-15):**

- **W13 — Every week keeps its history.** The weekly cache kept only the newest 60 weeks, so an older week showed empty (measured). W1b's day cache has no limit. Rejected: copying the 60-week limit into the new cache.

**Confirmed during Phase W2 (2026-09-16):**

- **W14 — The 24-hour limit applies only to new choices.** Choosing work days that would make a work day longer than 24 hours is refused with the reason. The weekly goal keeps today's 1–168 h range (on Monday–Friday, 168 h is already a 33.6-hour work day), and a stored, synced or imported schedule is refused only for a broken shape, never for a long day, so no saved history can be thrown away for it. Rejected: the limit everywhere, which would have narrowed the weekly goal to 120 h on Monday–Friday and dropped schedules already saved; no limit at all.

**Confirmed during Phase W3 (2026-09-19):**

- **W15 — The weekly bar keeps one letter per day.** §4.5 proposed a second letter wherever two of the week's work days share an initial. Measured before it shipped: Tuesday and Thursday share one in the default Monday–Friday week, so every existing user's bar would have gone from `M T W T F` to `M Tu W Th F`, and §1 promises it does not. The segments are in week order and each carries a tooltip with its own date, which is what has told Tuesday from Thursday since the bar was first drawn. Rejected: the rule as written; a rule exempting only Monday–Friday, which would have left two nearly identical schedules labelled differently.
- **The day-off-work badge reads "N Days off worked".** P-W11 named it "N Days off", but the badge on the line above already counts leave days as "N Days Off", and two badges a line apart differing only in capitalisation is not a distinction anyone reads. The leave badge is unchanged. Rejected: the plan's wording; renaming the leave badge to "N Leave days", which the plan never named.

**Confirmed during Phase W4 (2026-09-19):**

- **W16 — "No goal" belongs to the day, not to the arithmetic.** P-W16 as W3 shipped it reached every goal of 0, including a work day whose automatic goal lands there because the week is already met, or because the day is on leave. Restricted to days off: a work day with a 0 goal keeps the percentage line, the full bar and the heatmap ladder it has always had. Measured before and after — with the rewrite rule for it removed, the golden master compares 300 sets, 0 differ, so the app is byte-identical to `0ba1bd6` again and W3's only intended difference is the "Day off" wording. Rejected: the wider reading as shipped; extending it to leave days, which would have changed what every existing user sees on a leave day.

**Confirmed during Phase Z1 (2026-09-20):**

- **P-Z4 stands: the default reading is "keep the real moments", for every record.** Measured rather than assumed, because §7.1 made the default conditional on the audit. Nothing on a record says how it was filed: a tracked shift and a typed one carry the same seventeen fields, the milliseconds on `loginEpochMs` identify a timed shift only one way round, and the one marker that exists is erased by the edit dialog itself. Rejected: branching on `loginEpochMs % 1000`, which would read about one timed shift in a thousand as typed; branching on the `searchStr` marker, which the first edit destroys.
- **A dialog opened over another paints above it.** Not a question the plan asked, but one re-filing forced: the zone picker is authored before both edit dialogs, and painting followed authoring order. Fixed for every dialog at once rather than for this one, because the same bug already hid the overlap prompt the shift editor raises. Rejected: raising only the zone picker, which would have left the overlap prompt behind the dialog that raises it.

**Proposed by the plan and confirmed with it on 2026-09-15** (the user approved the plan as written; any of these can still be revisited before the phase named):

| #     | Question                            | Proposed                                                                         | Alternative                                        | Needed by |
| ----- | ----------------------------------- | -------------------------------------------------------------------------------- | -------------------------------------------------- | --------- |
| S1    | Do the new settings sync?           | **Yes**, like the weekly goal and the time zones                                 | Per device                                         | W2, C1    |
| P-W11 | "Weekend" wording                   | **"Day off"** from W3 on                                                         | Keep "Weekend" for Sat / Sun, "Day off" for others | W3        |
| P-W12 | A week-start change mid-week        | **A short transition week** from this week's start to the new start day          | Apply week start from next week only               | W2        |
| P-W13 | Weekly goal ÷ work days above 24 h  | **Refused** with the reason when the work days are chosen (narrowed by W14)      | Allowed                                            | W2        |
| P-W14 | Day-off goal once typed             | **Fixed hours** until "Auto" is pressed; unset follows ¾ of the work-day goal    | Always a ratio                                     | W2        |
| P-W15 | Schedule change during a shift      | **Never retargets the running shift** (F6)                                       | Ask, like "Update Session Goal?"                   | W2        |
| P-W16 | A 0 h day-off goal                  | **"No goal"**, no Overtime, bar empty (narrowed by W16 to days off)              | Show everything as overtime (today's 0 goal)       | W3        |
| P-F1  | Where the clock and date rows live  | **In the Time zones card, renamed "Time and date"** (already on the phone sheet) | A new "Formats" card                               | C1        |
| P-F2  | Typed slash date in YYYY-MM-DD mode | **Device region**, as today                                                      | Month first                                        | D1b       |
| P-F3  | Search in DD/MM or YYYY-MM-DD       | **Accepts dates in the chosen order**                                            | Stored order only                                  | D1b       |
| P-Z2  | Which records can be re-filed       | **Shifts and tasks**                                                             | Shifts only                                        | Z1        |
| P-Z3  | Re-filing moves the business date   | **Yes, shown in the preview** (the one exception to I2)                          | Keep the date always                               | Z1        |
| P-Z4  | Default mode                        | **Keep the real moments** for every record, unless Z1a finds a manual marker     | Keep written times                                 | Z1        |

---

## 11. Out of scope

- More than two clocks; per-client zones (dropped, X1).
- Rotating or alternating schedules (W10). The `v` field and ignored unknown keys leave room.
- Different hours on different work days (the rejected W2 alternative).
- Presets for work days (W1).
- A holiday calendar separate from leave (W8).
- The 24-hour clock in exports (C2); the date order in backups (D2).
- Following the phone's own 12 / 24-hour setting automatically.
- A cap on catch-up goals above 24 h in "next" mode (existing behaviour).
- Recovering weekly-goal changes made before this feature (history starts at the first change after W2).

---

## 12. Risks and rollback

| Risk                                                               | Mitigation                                                                                                                                                     |
| ------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Regressing the one real deployment (Mon–Fri, 40 h, LA, iPhone PWA) | W1 is behaviour-identical, gated on a golden master recorded from `0ba1bd6`; defaults are today (F2); W4 ends on the iPhone checklist                          |
| Week segmentation wrong across schedule changes                    | A pure core with property checks over random schedules; transition weeks asserted explicitly                                                                   |
| A settings race drops a history entry                              | The schedule is one value; the newest wins whole. History is interpretation only: no record changes, so the worst case is a past week re-read, never data lost |
| An old build erases the schedule from the account                  | Measured in W0; guarded in W2 if needed; proven in W4                                                                                                          |
| A display format leaks into storage                                | F1; storage diffs in every format phase; a mutation per save path                                                                                              |
| An ambiguous typed date misread                                    | One parser (F3), every input path tested in all three modes, edit-unchanged byte-identity                                                                      |
| Re-filing moves instants unintentionally                           | Kept instants carried explicitly; byte-identity tests including the repeated hour; the preview                                                                 |
| Tick cost from week lookups                                        | `weekOf` and the schedule cached per (business date, version); measured with the tick probe under 4× throttle                                                  |
| Phone width (seven chips, seven segments)                          | 375 px geometry probes (row 42)                                                                                                                                |
| Mutation anchors detach during the refactor                        | Aliases kept (`getStandardDayGoalSec`); anchors re-run after every format; affected mutations re-anchored in the same phase                                    |

**Rollback:** every phase is its own commit(s) and reverts cleanly.

- **After W2:** a revert leaves `workWeek` unread. Goals return to Mon–Fri, and past weeks follow the current weekly goal again (today's behaviour). No record is touched.
- **After C1 or D1:** a revert ignores the preferences; screens return to 12-hour MM/DD. Stored data was never in another form (F1).
- **After Z1:** records already re-filed stay valid records in their new zone.

---

## Appendix A — call-site inventory at `0ba1bd6`

**Work week — constants and goals:**

- 16381–16420 (`WEEKLY_GOAL_DEFAULT_HOURS`, `WEEKLY_GOAL_WORKDAYS`, `WEEKEND_GOAL_RATIO`, `getWeeklyGoalSec`, `getStandardDayGoalSec`);
- `calculatePeriodGoalStats` 16422 · `calculatePaceRequired` 16445 · `getMonthlyWeeks` 16462;
- state defaults 17315, 17322 · `weeklyCache` 17379 · `dailyAnchorMap` 17382 · `resolveGoalSecForDate` 17384;
- `DOM.weeklyGoalHours` 17611 · `DOM.progressSegments` 17619–17642;
- `getTodayLoggedWorkSeconds` 27441 · `autoPopulateDailyGoal` 27459–27613.

**`autoPopulateDailyGoal` callers:** 23020, 27043, 27361, 29727, 35919, 36155, 36171, 36183, 36432, 38061, 41600, 41627, 44060.

**`getStandardDayGoalSec` callers:** 16438, 17394, 17407, 22951, 27514, 28203, 28445, 28462, 28625, 31929, 32240, 33179, 33200, 33583, 33617, 35928, 44111.

**Weeks and weekdays:**

- worker 27098–27165, fallback 27177–27240;
- `updateLiveWeeklySummary` 28307–28515 · `isViewingCurrentWeek` 28548 · `updateProgress` segments 28670–28717, goal toast 28809–28829;
- filter WEEK 30926–30940;
- logbook row 31723–31850 (tag 31841–31845, fallback 31818);
- heatmap 32209–32602 (columns 32335–32346, leave goal 32240, streak 32578–32602);
- `renderInsights` 32665–33270 (week label 32766, rows 32807–33032, bar 33041–33146, trend 33173–33263);
- `renderMacroInsights` 33275–33700 (week start 33320, weekend 33369–33411, weekdays 33413–33437, remaining 33586–33622, trend 33637–33642).

**Settings, sync, backup:**

- markup 14958–15004;
- `SETTINGS_FIELDS` 21311 · `PREF_KEYS` 21401 · `readPrefs` 21441 · `settingsToWire` 21517 · `adoptSettings` 24207;
- `buildBackupPayload` 34705 · `backupPayloadIsEmpty` 34734 · import validation 34986 · `finalizeImport` 35139;
- `purgeFactoryKeys` 35743 · `onWeeklyGoalChange` 35884;
- `syncSettingsUI` 39193–39240 · `RELOCATIONS` 44750.

**Leave:** `getLeaveDates` 16976 · `getLeaveDateSet` 16984 · `saveLeaveDates` 16999 · add 41540–41603 · remove 41606–41629.

**Goal edits:** state reset 29661–29727 · manual goal paths 40834–40873, 41709–41749, 41788–41829.

**UI and guide:** segmented bar 13778 · `.badge-weekend` 6442 · guide 10528–10561, 10681–10685.

**Clock:**

- STYLES 18135–18190 · `formatTime` 18452;
- `recordEndpointText` 19235 · `recordEndpointView` 19249 · `formatTimeRange` 19274;
- `setClock` 26352 · clock markup 12752–12778 · `.clock-ampm` 1738, 7465 · ETA 28793;
- stored-string parsers 16636–16680 · `secondsToAMPM` 16682 · `minutesToAMPM` 16696;
- `parseClockTimePreview` 42380–42446 · login / logout blur 42448–42461 · `typedTimeInZone` 42486 · `typedGapMessage` 42533;
- `saveEditModal` 34295 (`keptTypedInstant` 34375);
- guide 10631–10661.

**Dates:**

- `_cachedLocaleDayFirst` 18080 · date blur handlers ~41940, ~42250, bindings 42365 · `parseDateStringLocal` 42463;
- labels and placeholders 11388, 11507–11514, 11632, 11781–11787, 12082 · toasts 34572, 39820, 41536, 41549, 41602, 41629;
- logbook 31726–31769 · insights 32814–32999 · heatmap 32487–32540, 32023;
- `businessDayLabel` 26430 · `toLocaleDateString` 29995 · `displayDate` 31100, 39750;
- EOD email 29163–29226 · row copy 35525–35547 · CSV 34633 · tasks CSV 40708;
- file names 34682, 34791, 40720.

**Re-filing:** `recordZone` 18911 · `getDisplayZone` 18916 · `ZonePicker` 19910 · `openZonePickerFor` 26437 · `zoneCityOffset` 26423 · `saveEditModal` 34295–34424 · task edit markup 11388.

**Invalidation:** `onZoneContextChanged` 18939 · `zoneRenderKey` 19127 · logbook row key 31744 · `insightsCacheKey` 32687.

**Harness references to what changes:**

- `harness-progress.js` 39 (`ETA_SHAPE`), 48–97;
- `harness-phase8.js` 175, 388–415;
- `harness-wipe.js` 92–100;
- `probe-leave-rows.js`; `tests-phase5.js` 202;
- `mutation-test.js` 1448, 1461, 1474, 1488, 3530.
