# Cross-device sync with live session handoff

**nodrift — implementation blueprint**

Close the laptop mid-shift, open the phone, and the timer is still running —
same elapsed, to the second, even if the two clocks disagree. This is the full
path from the code as it stands today to that behaviour, in eight phases that
each ship on their own.

|                        |                |
| ---------------------- | -------------- |
| Hook points in the app | **4**          |
| New dependencies       | **0**          |
| Blocking CSP lines     | **1**          |
| Approx. new JS         | **~450 lines** |

Line references are against `index.html` at commit `03ff9cb`. Nothing here has
been built yet — this is the plan, not a report.

---

## Contents

**Design**

1. [Three kinds of data, three different rules](#1-three-kinds-of-data-three-different-rules)
2. [What this codebase will and won't allow](#2-what-this-codebase-will-and-wont-allow)
3. [Don't use supabase-js](#3-dont-use-supabase-js)
4. [One clock domain, converted at the wire](#4-one-clock-domain-converted-at-the-wire)
5. [Four hook points, and no others](#5-four-hook-points-and-no-others)
6. [The whole database, in one script](#6-the-whole-database-in-one-script)
7. [Merge rules, stated precisely](#7-merge-rules-stated-precisely)
8. [The session lease](#8-the-session-lease)

**Build order** 9. [Eight phases, each shippable](#9-eight-phases-each-shippable)

**Reference** 10. [Failure matrix](#10-failure-matrix) 11. [Three existing behaviours that only become bugs once sync exists](#11-three-existing-behaviours-that-only-become-bugs-once-sync-exists) 12. [Test strategy](#12-test-strategy) 13. [Four decisions that are yours](#13-four-decisions-that-are-yours)

---

## 1. Three kinds of data, three different rules

The single biggest mistake available here is treating everything as one synced
blob. nodrift has three data shapes with genuinely different correctness
requirements, and each needs its own merge rule.

| Domain     | What it is                                                    | Rule                                                               | Why                                                                                                                           |
| ---------- | ------------------------------------------------------------- | ------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------- |
| `records`  | Shift logs and task logs — `cachedLogs`, `cachedTaskLogs`     | **Per-record last-writer-wins** on `lastModified`, with tombstones | History is append-mostly and each row is independent. Two devices editing different shifts must both survive.                 |
| `session`  | The live shift — timer anchors, mode, idle lock, running task | **Exclusive lease.** One device may write; everyone else reads     | There is exactly one running timer in the real world. Merging two of them produces a number that is true of neither.          |
| `settings` | Goal, idle threshold, auto-backup, auto-email, timezone       | **Whole-blob LWW**, writable by any device                         | Preferences aren't measurements. Losing the older of two edits costs nothing, and gating them on the lease would be baffling. |

The split matters concretely: today `state` (`index.html:14055`) mixes all three
— `sessionAnchorWall` sits next to `idleThresholdMinutes`. The wire format
separates them; local storage does not have to change.

### Field classification

```js
// Lease-owned. Only the session holder writes these.
const SESSION_FIELDS = [
  "workAccumulated",
  "breakAccumulated",
  "currentMode",
  "sessionAnchorWall",
  "activeSegmentFloorSec",
  "loginTimestamp",
  "activeDate",
  "idleLock",
  "idleStart",
  "idleWakeup",
  "preIdleMode",
  "idleOverlapSec",
  "idleType",
  "goalNotified",
  "lastHeartbeatWall",
  "notes",
  "shiftStartGoalSec",
];

// Any device writes these; newest edit wins.
const SETTINGS_FIELDS = [
  "idleTrackingEnabled",
  "idleThresholdMinutes",
  "autoBackupEnabled",
  "autoEmailEnabled",
  "goalAutopopulateEnabled",
];

// Never leave the device. lastActivity and tabHiddenAt describe THIS
// browser's input and visibility — shipping them would make the phone
// inherit the laptop's idleness the instant it takes over.
const LOCAL_ONLY = ["lastActivity", "tabHiddenAt"];
```

> **Why handoff is even possible**
>
> Because the timers already derive from an anchor rather than incrementing a
> counter. `getActiveSegmentSeconds()` computes
> `(now − sessionAnchorWall) / 1000`. Ship the anchor and the receiving device
> computes the same elapsed with no replay and no tick history. Had the timer
> been a counter incremented on an interval, handoff would need an event log
> and this document would be three times longer.

---

## 2. What this codebase will and won't allow

Four constraints are already baked into the file. Every one of them rules out
the obvious approach, so establish them before writing a line.

### 2.1 The CSP forbids all network access

`index.html:11-14`

```html
<meta
  http-equiv="Content-Security-Policy"
  content="
  default-src 'self';
  script-src 'self' 'unsafe-inline' blob:;
  connect-src 'none';                    <-- this
  ..."
/>
```

`connect-src 'none'` blocks every `fetch`, `XMLHttpRequest`, `WebSocket`, and
`sendBeacon` in the document. Nothing works until it changes. Change it to the
exact project origin, not a wildcard:

```
connect-src https://<project-ref>.supabase.co;
```

Naming one host keeps the property that made `'none'` worth having: if any code
in this file ever tries to phone somewhere else, the browser stops it.
`script-src` stays as it is — see section 3.

### 2.2 Single file, no build step

`index.html` is 31,417 lines and about 1.17 MB, with no `package.json`, no
bundler, and no `node_modules`. Anything added has to be hand-written inline
JavaScript that a person can read in place. That is a real constraint, not a
preference, and it drives section 3.

### 2.3 Storage is already three-layered

IndexedDB `WorkTrackerDB` v3 holds `logs`, `logs_chunked` (keyed `YYYY-MM`), and
`snapshots`. localStorage holds `state`, task state, task logs, and an emergency
mirror of the whole logbook. Sync metadata goes in IndexedDB — a **v4 bump
adding one `sync_meta` store** — because localStorage's 5 MB budget is already
carrying the mirror.

The version bump is safe: `db.onversionchange` (`index.html:15128`) already
closes the connection and reloads so other tabs can't block the upgrade.

### 2.4 CRLF line endings, enforced

Every edit must preserve CRLF. Run `prettier --end-of-line crlf` or the diff
becomes all 31k lines and the review is worthless.

---

## 3. Don't use supabase-js

Every tutorial starts with `<script src="...@supabase/supabase-js">`. In this
file that line is dead on arrival, and the workaround is worse than the
alternative.

`script-src 'self' 'unsafe-inline' blob:` means no CDN script will load. The
only ways around it are relaxing `script-src` to a third-party origin — giving a
remote host the right to execute arbitrary code against all of your data — or
pasting the ~120 KB minified bundle into a file you maintain by hand.

Neither is necessary. Supabase is Postgres behind two ordinary REST APIs, and
everything this design needs is a handful of JSON calls:

| Need                     | Endpoint                                       | Notes                            |
| ------------------------ | ---------------------------------------------- | -------------------------------- |
| Request a sign-in code   | `POST /auth/v1/otp`                            | GoTrue                           |
| Exchange code for tokens | `POST /auth/v1/verify`                         | Returns access + refresh         |
| Refresh access token     | `POST /auth/v1/token?grant_type=refresh_token` | Rotating refresh                 |
| Pull changed records     | `GET /rest/v1/records?updated_at=gt....`       | PostgREST; RLS scopes it         |
| Push records             | `POST /rest/v1/rpc/push_records`               | Server-side LWW guard            |
| Claim / renew lease      | `POST /rest/v1/rpc/claim_session`              | Atomic; also returns server time |

That is one `fetch` wrapper and six call sites — call it 90 lines. It is
readable, it is debuggable in the Network tab, and it adds nothing to the file
that you didn't write.

### Skip Realtime too

Supabase Realtime speaks the Phoenix channel protocol over WebSockets.
Implementing that by hand is real work, and it would put `wss:` back in the CSP.
Poll instead — the latency budget here is human-scale:

- Immediately after any local write (debounced ~800 ms)
- Every 15 s while a session is live — the same tick as the lease heartbeat
- Every 60 s while signed in but idle
- On `visibilitychange` -> visible, and on the `online` event

Picking up the phone fires a visibility poll, so handoff feels instantaneous
where it actually matters. The steady-state cost is four requests a minute
during an active shift.

---

## 4. One clock domain, converted at the wire

Two devices' clocks differ. If a raw `Date.now()` anchor crosses between them,
the elapsed time jumps by exactly that difference — and last-writer-wins
silently becomes fastest-clock-wins.

### The rule

**Local storage is always in local wall-clock domain. Conversion happens in
exactly two functions.** Nothing in the app changes how it stamps or reads
timestamps; only the serializer and deserializer know the offset exists.

```js
// serverOffsetMs = how far AHEAD this device's clock runs.
// Zero when signed out, so every path below is identity.
let serverOffsetMs = 0;

const toWire = (t) => t - serverOffsetMs; // local -> server
const fromWire = (t) => t + serverOffsetMs; // server -> local
```

### Measuring the offset

Not from the HTTP `Date` header — `Date` is not CORS-safelisted, so a
cross-origin `fetch` cannot read it without the server opting in, and it only
has second precision anyway. Get it from Postgres, where you control the
response:

```js
const t0 = Date.now();
const serverMs = await rpc("server_now");
const rtt = Date.now() - t0;
const sample = Date.now() - (serverMs + rtt / 2);

// Median of the last 5 samples, and only adopt a change > 2s.
// Otherwise network jitter walks the offset around and every
// pull rewrites anchors that were already correct.
offsetSamples.push(sample);
if (offsetSamples.length > 5) offsetSamples.shift();
const next = median(offsetSamples);
if (Math.abs(next - serverOffsetMs) > 2000) serverOffsetMs = next;
```

`claim_session` returns `now_ms` in its payload, so the 15-second lease
heartbeat re-measures the offset for free. The lease and the clock discipline
ride the same request.

### The transform already exists

This is the payoff from the timer work already in the file.
`rebaseTimestampBag(bag, deltaMs)` (`index.html:14738`) shifts every in-flight
wall timestamp in an object by a delta — which is exactly what domain conversion
is. Generalise it to take a key list:

```js
// index.html:14738 — add the third parameter, default preserves
// today's behaviour for applyClockStep's three call sites.
function rebaseTimestampBag(bag, deltaMs, keys = CLOCK_REBASE_STATE_KEYS) {
  if (!bag || typeof bag !== "object") return;
  for (let i = 0; i < keys.length; i++) {
    const v = bag[keys[i]];
    if (typeof v === "number" && isFinite(v)) bag[keys[i]] = v + deltaMs;
  }
}

// The instants that must convert. Note this is NOT the same list as
// CLOCK_REBASE_STATE_KEYS: lastActivity and tabHiddenAt are local-only.
const SYNC_INSTANT_KEYS = [
  "sessionAnchorWall",
  "loginTimestamp",
  "idleStart",
  "idleWakeup",
  "lastHeartbeatWall",
];
```

Durations — `activeSegmentFloorSec`, `taskFloorSec`, `workAccumulated` — cross
unchanged. They are seconds elapsed, not instants, so they have no clock domain.

### The one place that needs true time locally

`getPSTDate()` (`index.html:16501`) decides which calendar day a shift belongs
to. Two devices near midnight whose clocks differ by ten minutes will disagree
about the date and file the same shift under two different days. Fix by feeding
it corrected time:

```js
function trueNow() {
  return Date.now() - serverOffsetMs;
}

// index.html:16501-16507 — swap the two Date.now() calls for trueNow().
// Identical behaviour signed out (offset is 0). Keep it a bare
// subtraction: this runs on every tick.
```

> **Guard the adoption**
>
> Never adopt a remote anchor when the offset has not been measured this
> session, and reject any adopted session whose computed elapsed is negative or
> exceeds 24 hours. A single bad offset applied to an anchor produces a timer
> reading of days, and the ratchet floors will happily preserve that number
> forever.

---

## 5. Four hook points, and no others

Every mutation in the app already funnels through one of four save functions.
Hook those and you have instrumented the entire application — including paths
that don't exist yet.

| Function                  | Line  | Marks dirty            |
| ------------------------- | ----- | ---------------------- |
| `saveLogs(logs, options)` | 16115 | `records:log`          |
| `saveTaskLogs()`          | 26564 | `records:task`         |
| `saveState(forceSync)`    | 29883 | `session` + `settings` |
| `saveTaskState()`         | 26550 | `session`              |

Each insertion is one guarded line, so removing the sync block leaves a working
app:

```js
if (window.Sync) window.Sync.markDirty("logs");
```

### The shadow map: an outbox you don't have to maintain

The naive approach instruments every delete site to write a tombstone —
`deleteSingleShift`, the task delete, snapshot restore, import-overwrite,
factory reset — and then forgets one, and a deleted shift comes back a week
later. Don't do that. **Derive the change set instead.**

Keep a `Map<id, lastModified>` of what the server has confirmed. On every save,
diff the incoming array against it:

```js
function deriveOutbox(kind, records, shadow) {
  const out = [],
    seen = new Set();

  for (const r of records) {
    if (!r || !r.id) continue;
    seen.add(r.id);
    const lm = lastModifiedOf(r);
    if (shadow.get(r.id) !== lm) {
      out.push({
        kind,
        id: r.id,
        payload: r,
        deleted: false,
        last_modified: toWire(lm),
      });
    }
  }

  // Anything the server confirmed that is no longer in the array
  // was deleted — by ANY path, including ones written later.
  for (const id of shadow.keys()) {
    if (!seen.has(id)) {
      out.push({
        kind,
        id,
        payload: null,
        deleted: true,
        last_modified: toWire(Date.now()),
      });
    }
  }
  return out;
}
```

Three properties fall out of this for free:

- **Deletes are caught structurally.** Snapshot restore, factory reset,
  import-overwrite and any future delete path are all covered without being
  touched, because absence _is_ the signal.
- **The queue survives a crash.** The shadow is the queue. Kill the browser
  mid-push and the next boot re-derives exactly the same pending set from
  durable state — there is no separate outbox to lose.
- **Retries are free.** The shadow only advances on a confirmed 2xx, so a failed
  push simply reappears in the next diff.

Cost is one `O(n)` pass over the logs array per save. `saveLogs` already does an
`O(n)` index pass, a weekly-cache rebuild, and a full `JSON.stringify` for the
emergency mirror — a map walk is noise beside that.

### Backfilling lastModified

Records predating the field have no `lastModified`. Two devices must resolve it
identically, so normalise once at load rather than at comparison time.
`hydrateLogsInChunks` (`index.html:30291`) already backfills `id`, `searchStr`
and `status`, sets a `mutated` flag, and saves — add one more clause:

```js
if (!Number.isFinite(l.lastModified)) {
  l.lastModified = l.logoutEpochMs || l.epochMs || 0;
  mutated = true;
}
```

For tasks the ladder is `t.lastModified ?? t.endMs ?? t.startMs ?? 0`. Manual
task creation (`index.html:22858`) currently omits `lastModified` altogether
while the timer path (`index.html:26689`) sets it — add it there.

---

## 6. The whole database, in one script

Three tables, three policies, three functions. Paste it into the Supabase SQL
editor once.

### Tables

```sql
create extension if not exists pgcrypto;

-- One row per signed-in device. Only used to label the takeover prompt.
create table public.devices (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users on delete cascade,
  label        text not null default 'Unnamed device',
  last_seen_at timestamptz not null default now()
);

-- Singleton per user: the live session, the settings blob, the lease.
create table public.session_state (
  user_id           uuid primary key references auth.users on delete cascade,
  payload           jsonb  not null default '{}'::jsonb,  -- SESSION_FIELDS
  task_payload      jsonb  not null default '{}'::jsonb,  -- taskState
  settings          jsonb  not null default '{}'::jsonb,  -- SETTINGS_FIELDS
  settings_modified timestamptz not null default now(),
  generation        bigint not null default 1,
  owner_device      uuid,
  owner_expires_at  timestamptz,
  updated_at        timestamptz not null default now()
);

-- Logs and tasks in one table with a discriminator: one policy,
-- one pull query, one push function.
create table public.records (
  user_id       uuid not null references auth.users on delete cascade,
  kind          text not null check (kind in ('log', 'task')),
  id            text not null,                    -- the app's own "log_xxx"
  payload       jsonb,                            -- null when deleted
  deleted       boolean not null default false,
  last_modified timestamptz not null,             -- author's edit time -> LWW
  updated_at    timestamptz not null default now(), -- server receipt -> cursor
  primary key (user_id, kind, id)
);

create index records_pull_idx on public.records (user_id, kind, updated_at);
```

> **Two timestamps, two jobs — do not merge them**
>
> `last_modified` is when the user edited the record; it decides conflicts.
> `updated_at` is when the server learned about it; it drives the delta cursor.
> Using one field for both loses data: device A edits offline at 09:00 and syncs
> at 14:00, while device B's cursor sits at 11:00 — B queries `> 11:00`, A's
> record says 09:00, and B never sees it. Ever.

### Row-level security

```sql
alter table public.records       enable row level security;
alter table public.session_state enable row level security;
alter table public.devices       enable row level security;

-- FORCE also applies the policy to the table owner. Without it a
-- misconfigured service role reads every user's data.
alter table public.records       force row level security;
alter table public.session_state force row level security;
alter table public.devices       force row level security;

create policy own_records on public.records for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy own_session on public.session_state for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy own_devices on public.devices for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

revoke all on public.records, public.session_state, public.devices from anon;
```

### Server receipt stamp

```sql
-- clock_timestamp(), not now(): now() returns TRANSACTION START time,
-- so two overlapping writes can be stamped in the opposite order to
-- the one they commit in, and a cursor steps straight over one.
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := clock_timestamp();
  return new;
end $$;

create trigger records_touch before insert or update on public.records
  for each row execute function public.touch_updated_at();
create trigger session_touch before insert or update on public.session_state
  for each row execute function public.touch_updated_at();
```

`clock_timestamp()` narrows the commit-ordering window but does not close it —
the stamp is still assigned before the commit lands. The client closes the
remainder by rewinding its cursor five seconds on every pull; because LWW merge
is idempotent, re-seeing a record costs one comparison.

### Push with a server-side LWW guard

PostgREST's built-in upsert overwrites unconditionally, which lets a device that
has been offline for a week clobber newer data. Guard it in SQL so the rule
holds no matter what the client does:

```sql
create or replace function public.push_records(p_rows jsonb)
returns integer language plpgsql security invoker set search_path = public as $$
declare n integer;
begin
  with incoming as (
    select auth.uid()                        as user_id,
           e->>'kind'                        as kind,
           e->>'id'                          as id,
           case when (e->>'deleted')::boolean
                then null else e->'payload' end as payload,
           coalesce((e->>'deleted')::boolean, false) as deleted,
           to_timestamp((e->>'last_modified')::bigint / 1000.0) as last_modified
    from jsonb_array_elements(p_rows) e
  ), ins as (
    insert into public.records as r
      (user_id, kind, id, payload, deleted, last_modified)
    select * from incoming
    on conflict (user_id, kind, id) do update
       set payload       = excluded.payload,
           deleted       = excluded.deleted,
           last_modified = excluded.last_modified
     where excluded.last_modified > r.last_modified
    returning 1
  )
  select count(*) into n from ins;
  return n;
end $$;

grant execute on function public.push_records to authenticated;
```

### Server clock

```sql
create or replace function public.server_now() returns bigint
language sql stable as $$
  select (extract(epoch from clock_timestamp()) * 1000)::bigint
$$;
grant execute on function public.server_now to authenticated;
```

---

## 7. Merge rules, stated precisely

### Pull, then merge, then push

Order matters. Pull first so local edits are compared against current server
state rather than a stale view; push second so a local edit that genuinely is
newer still wins. A pull that arrives mid-push is fine — the server guard makes
both directions idempotent.

```
GET /rest/v1/records
    ?select=id,kind,payload,deleted,last_modified,updated_at
    &kind=eq.log
    &updated_at=gt.<cursor - 5s>
    &order=updated_at.asc
    &limit=500
```

Page until fewer than 500 rows come back, then store the highest `updated_at`
seen as the new cursor. Per record:

- **Incoming newer** -> replace locally (or remove, if `deleted`).
- **Local newer** -> keep local; the next push corrects the server.
- **Equal** -> no-op. Ties are frequent and must be cheap.

After applying, mark the touched `YYYY-MM` keys in `window.dirtyChunks` before
calling `saveLogs`, so only the affected chunks are rewritten instead of the
whole store.

### Edit-versus-delete resolves as an edit

Device A deletes a shift; device B, offline, edits the same shift afterwards.
B's `lastModified` is newer, so the record comes back. That is the honest
reading of last-writer-wins — someone touched it more recently than someone else
removed it — and it errs toward keeping data. Worth knowing it is a choice
rather than an accident.

### Tombstone lifetime

Tombstones can't live forever, and pruning them opens a hole: a device offline
longer than the retention window still holds the deleted record and never learns
it went away. Close it on the client:

```sql
-- server: prune after 90 days (pg_cron, weekly)
delete from public.records
 where deleted and updated_at < now() - interval '90 days';
```

```js
// client: a cursor older than the retention window can no longer be
// trusted to produce a complete delta. Full resync instead.
if (Date.now() - cursorMs > 60 * 864e5) return fullResync(kind);
```

A full resync pulls every row, then treats _local records that are absent from
the complete server set but present in the shadow_ as remote deletes. Sixty days
against ninety leaves a month of slack.

### First sign-in on a device that already has data

The most dangerous moment in the whole system. Three cases, and one of them must
never be "overwrite":

| Situation          | Action                                                                                                                                                                                                                                                             |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Server empty       | Full upload. Set the cursor from the push response.                                                                                                                                                                                                                |
| Local empty        | Full download. Seed the shadow from what arrives.                                                                                                                                                                                                                  |
| **Both have data** | **Union by id, LWW per record. Never replace.** Report the outcome plainly — _"Merged 214 shifts from your other device, uploaded 9."_ Nothing is deleted on a first sync: with an empty shadow the outbox derivation emits no tombstones, which is exactly right. |

---

## 8. The session lease

The app already solves this problem between tabs, with `LEASE_KEY`, a staging
key, randomised backoff and Web Locks (`index.html:15381-15802`). The
cross-device version is the same shape, moved to Postgres where the
compare-and-swap can actually be atomic.

```sql
create or replace function public.claim_session(
  p_device uuid,
  p_force  boolean default false,
  p_ttl_seconds int default 45
) returns jsonb language plpgsql security invoker set search_path = public as $$
declare
  r   public.session_state;
  ttl interval := make_interval(secs => p_ttl_seconds);
begin
  insert into public.session_state as s (user_id, owner_device, owner_expires_at)
  values (auth.uid(), p_device, clock_timestamp() + ttl)
  on conflict (user_id) do update
     set owner_device     = p_device,
         owner_expires_at = clock_timestamp() + ttl,
         generation       = s.generation
           + case when s.owner_device is distinct from p_device then 1 else 0 end
   where s.owner_device = p_device                -- renewing our own
      or s.owner_expires_at is null               -- never claimed
      or s.owner_expires_at < clock_timestamp()   -- holder went away
      or p_force                                  -- user said take it
  returning * into r;

  -- WHERE suppressed the update: a live holder that isn't us.
  if r.user_id is null then
    select * into r from public.session_state where user_id = auth.uid();
  end if;

  return jsonb_build_object(
    'held',         (r.owner_device = p_device),
    'owner',        r.owner_device,
    'generation',   r.generation,
    'payload',      r.payload,
    'task_payload', r.task_payload,
    'settings',     r.settings,
    'now_ms',       (extract(epoch from clock_timestamp()) * 1000)::bigint
  );
end $$;

grant execute on function public.claim_session to authenticated;
```

One statement, so two devices claiming simultaneously cannot both win. One call
every 15 seconds does four jobs at once: renew the lease, detect a takeover,
pull the session, and re-measure the clock offset.

### What the user sees

| Moment                        | Wire                       | Experience                                                                                                                    |
| ----------------------------- | -------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| Start a shift on the laptop   | `held: true, gen 5`        | Nothing visible. It is just the app.                                                                                          |
| Open the phone                | `held: false, owner != me` | Timer shows live elapsed, read-only, with a line: _"Running on MacBook."_ and a **Continue here** button.                     |
| Tap Continue here             | `force -> gen 6`           | Controls come alive within one round trip. The elapsed number never moves — the anchor didn't change, only who may write it.  |
| Laptop's next beat            | `gen 6, owner != me`       | Within 15 s: _"This session moved to iPhone."_ Demotes to read-only, keeps rendering the true elapsed from the pulled anchor. |
| Laptop goes offline mid-shift | expires after 45 s         | The phone can claim without forcing. No prompt, no orphaned session.                                                          |

### Adoption checklist

When a device takes ownership, before rendering anything:

- Convert every `SYNC_INSTANT_KEYS` field with `fromWire`.
- Set `lastActivity = Date.now()` — the user is demonstrably here. Inheriting the
  other device's idle timestamp would trip the idle lock instantly.
- Clear `tabHiddenAt`; it described a different browser.
- Adopt the incoming `activeSegmentFloorSec` as-is. It is a duration, it is a
  maximum, and it is the whole reason a backward clock step can't erase worked
  time.
- Reject and re-pull if elapsed computes negative or over 24 h.
- Refuse adoption entirely if `serverOffsetMs` has never been measured this
  session.

### The two lease layers stay separate

The existing tab lease is not replaced. Local tabs still elect one leader per
browser; that leader is the only one that talks to the network. This keeps the
invariant already enforced at `index.html:29884` — `if (isTabConflict) return;`
— and means three open tabs produce one poller, not three.

---

## 9. Eight phases, each shippable

Phases are numbered because they are genuinely sequential — each depends on the
one before, and each ends at a state you could commit and leave for a month.
Every phase names its exit test; if the test doesn't pass, don't start the next
one.

### Phase 0 — Preflight _(no code)_

Create the Supabase project. Run the schema script from section 6 in the SQL
editor. Record the project URL and the `anon` key — the anon key is designed to
ship in a client, and RLS is what actually protects the data, which is why
`force row level security` is not optional.

Enable email auth. Decide the sign-in method now (see section 13) because it
changes phase 1.

**Exit test.** From the SQL editor, insert a row into `records` with a different
`user_id` than yours, then query the table as your own user through the REST
endpoint. You must get zero rows back. If you get one, RLS is not on and nothing
else in this document is safe to build.

---

### Phase 1 — Transport and auth _(no data yet)_

Change the CSP `connect-src`. Add the `Sync` module skeleton: a `net()` wrapper
that attaches `apikey` and `Authorization` headers, token storage in
localStorage, proactive refresh at 80% of token lifetime, and a 401 handler that
refreshes once and retries once. Add the account card to Settings. Measure
`serverOffsetMs`.

Refresh tokens rotate — persist the new one in the same tick you receive it, or
a crash between the response and the write signs the user out permanently.

**Touches.** `index.html:11-14` (CSP), new module before `initApp`, Settings
panel markup.

**Exit test.** Sign in, reload, still signed in. Offset reads within a couple of
seconds of zero on a healthy machine, and within ~300 s of the truth after you
deliberately set the OS clock five minutes fast. Sign out and confirm the app
behaves exactly as it does today.

---

### Phase 2 — Sync metadata _(still no network)_

IndexedDB v3 -> v4 with a `sync_meta` store. Shadow maps for both record kinds,
the cursor, and the device id. The four `markDirty` hooks. `deriveOutbox`. The
`lastModified` backfill in `hydrateLogsInChunks`. The wire serializers,
including the `rebaseTimestampBag` key-list parameter.

Nothing transmits. This phase is purely about being able to answer "what
changed?" correctly, which is the part that is easy to get subtly wrong and hard
to notice.

**Touches.** 15108 (DB version), 14738 (`rebaseTimestampBag`), 16115, 26550,
26564, 29883, 30291.

**Exit test.** Headless: seed 50 logs, snapshot the shadow, edit two, delete one,
add one. Assert the outbox is exactly four entries with the right ids and exactly
one `deleted: true`. Negative control — restore the pre-derivation version and
assert the delete is _missed_, proving the test observes what it claims to.

---

### Phase 3 — History sync _(first real sync)_

Wire the outbox to `push_records`, advancing the shadow only on 2xx. Delta pull
with the cursor and the five-second rewind. LWW merge with chunk-targeted saves.
First-sign-in reconciliation with the three cases. Full-resync fallback for
stale cursors.

At the end of this phase the app is genuinely useful across devices — history is
shared. Live handoff is not there yet, and that is a fine place to stop and use
it for a week.

**Touches.** Sync module only, plus the merge path calling `saveLogs` /
`saveTaskLogs`.

**Exit test.** Two Chrome profiles as two devices. Edit a shift on A, see it on
B. Delete on A; after B pushes its own unrelated change, the shift stays deleted
— this is the test that catches a missing tombstone. Edit different shifts on
both while B is offline; reconnect; both survive.

---

### Phase 4 — Session lease _(ownership only)_

`claim_session`, the 15-second heartbeat, generation-based demotion, the takeover
modal, and device labels. No session payload crosses yet — this phase is purely
about who is allowed to write.

Splitting ownership from payload is deliberate: lease bugs and serialization
bugs look identical from the outside, and debugging them together is miserable.

**Touches.** Sync module, takeover modal markup (mirror the existing
tab-conflict modal).

**Exit test.** A claims. B is refused and shows the prompt. B forces; A demotes
within one heartbeat. Kill A's network with the lease held; B claims cleanly
after 45 s with no prompt. Two devices forcing within the same second produce one
winner and one clean refusal.

---

### Phase 5 — Live handoff _(the feature)_

Push and pull `payload` / `task_payload` under the lease. Domain conversion on
both edges. The adoption checklist. Read-only rendering for non-holders —
controls disabled, timer live, a line saying where the session actually is.

Settings sync rides along here, on its own LWW timestamp, independent of the
lease.

**Touches.** 16780 `getActiveSegmentSeconds` (read-only guard), 16501
`getPSTDate` (`trueNow`), render paths.

**Exit test.** Start a shift on A. Set B's OS clock four minutes fast. Hand off.
Assert B's displayed elapsed matches A's within 2 seconds — not four minutes.
Repeat with B four minutes slow. Then hand off with a running task timer and
confirm both the session and the task continue. Confirm B does not immediately
idle-lock.

---

### Phase 6 — Hardening _(the long tail)_

Exponential backoff with jitter on failure. Pause polling while offline and
resume on the `online` event. Restamp `lastModified` on snapshot restore.
Stabilise ids on import. Factory reset offers a remote wipe. Sign-out asks
whether to keep or clear the local copy. Quota-exceeded degrades to pull-only
rather than failing silently.

**Touches.** 23726 (import ids), 26030 (snapshot restore), 23948 (factory reset),
Sync module.

**Exit test.** Every row of the failure matrix (section 10), reproduced
deliberately, each producing the stated behaviour and a message a person could
act on.

---

### Phase 7 — The sync panel _(not optional)_

A block in Settings showing: signed-in email, this device's label, last
successful push and pull, pending record count, measured clock offset, current
lease owner and generation, and the last error with its timestamp.

A sync system without a status view is a system you cannot debug from a user's
description. When something goes wrong six months from now, this panel is the
difference between a five-minute diagnosis and a weekend.

**Exit test.** Break something on purpose — revoke the token server-side — and
confirm the panel says something true and specific about it.

---

## 10. Failure matrix

Each of these will happen. Decide the behaviour now, while it is a design
question rather than a bug report.

| Failure                    | Behaviour                                                                                                             | User sees                                                                             |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| Offline                    | Local-first continues untouched. Polling pauses; the shadow accrues the backlog.                                      | A quiet "Offline — N changes pending" in the sync panel. No toast; it isn't an error. |
| Access token expired       | Refresh once, retry once. Sign out only if the refresh itself is rejected.                                            | Nothing, in the normal case.                                                          |
| Refresh token rejected     | Clear tokens. **Never clear local data.**                                                                             | "Signed out — sign in again to resume syncing." App keeps working.                    |
| Lease held elsewhere       | Read-only session. History sync continues normally — it isn't lease-gated.                                            | "Running on MacBook" plus **Continue here**.                                          |
| Clock offset unmeasured    | Refuse to adopt a remote session. History sync still runs.                                                            | "Checking clock..." for the one round trip it takes.                                  |
| Clock suspect locally      | Existing guard already stops the ratchets banking. Also skip pushing the session until it clears.                     | The existing clock-change toast.                                                      |
| Cursor older than 60 days  | Full resync, with local-absent-from-server treated as deletes.                                                        | "Rebuilding from cloud..." once.                                                      |
| Server 5xx                 | Exponential backoff with jitter, capped at 5 minutes. Shadow untouched, so nothing is lost.                           | Silent for the first three attempts, then the panel shows it.                         |
| IndexedDB write fails      | `isDatabaseHealthy` already blocks writes. Sync must degrade to pull-only — never push a view built on a failed read. | The existing storage error, plus "Sync paused".                                       |
| Project paused (free tier) | All calls fail. Treated as offline, indefinitely.                                                                     | "Cloud unreachable since \<date\>". This one needs to be loud after a day.            |

---

## 11. Three existing behaviours that only become bugs once sync exists

All three are correct today. Each turns into silent data loss the day a second
device appears, so they are listed as work, not as trivia.

### Snapshot restore doesn't restamp

`index.html:26030` calls `saveLogs(target.logs)` with the snapshot's original
records, whose `lastModified` values are old by definition. Under LWW the
cloud's newer copies win the next pull and the restore silently undoes itself.

**Fix.** Stamp every restored record with `lastModified = Date.now()` before
saving. The shadow derivation then handles the removals automatically — records
absent from the snapshot but present in the shadow become tombstones without any
extra code.

### Import reassigns ids on collision

`index.html:23726` mints a fresh id when two records collide. Locally that is
correct. To a sync layer keyed on id it reads as a delete plus a create, so the
record duplicates across devices.

**Fix.** Keep the original id when the colliding record is recognisably the same
shift, and reserve reassignment for genuinely distinct entries.

### Factory reset is local only

`index.html:23948` clears both object stores and the lease. With sync on, the
next pull restores everything from the cloud — which is either a delightful
safety net or a catastrophic failure to honour an explicit instruction,
depending entirely on what the button said it would do.

**Fix.** Make it an explicit choice: _"Erase on this device"_ versus _"Erase
everywhere"_.

---

## 12. Test strategy

The existing harness extends directly: a static server over the repo root,
headless Chrome over raw CDP, `Runtime.evaluate` for app globals. Two additions
make it a multi-device rig:

- **Two profiles, two ports.** Separate `--user-data-dir` values give two
  independent storage origins on one machine — two real devices as far as the
  lease is concerned.
- **Fake the clock, don't set it.** `Emulation.setVirtualTimePolicy` or an
  injected `Date.now` shim lets you skew device B by four minutes without
  touching the OS clock. Skew must be applied before the app boots, so use
  `Page.addScriptToEvaluateOnNewDocument`.

Pair every assertion with a negative control that re-injects the old behaviour at
runtime and asserts the probe _fails_. The task-timer proof already does this in
five places, and it is what makes a passing run mean something. The
highest-value controls here:

1. Outbox derivation without the shadow -> the delete is missed.
2. Handoff without domain conversion -> elapsed jumps by the skew.
3. Pull cursor keyed on `last_modified` -> the offline edit is never seen.
4. Push without the SQL LWW guard -> the stale device clobbers newer data.

Test 4 is worth building even though it duplicates a client-side check, because
it is the one that proves the invariant holds against a client that is simply
wrong.

---

## 13. Four decisions that are yours

### Sign-in method

**Recommended: email plus a six-digit code.** No password to manage or reset, and
critically no redirect — this app runs from the home screen in standalone mode,
where OAuth redirect flows are genuinely fragile. One `POST /auth/v1/otp`, one
`POST /auth/v1/verify`, done.

The catch: Supabase's built-in SMTP is rate-limited to a handful of messages an
hour, which is fine for two devices but will infuriate you while testing. Either
configure custom SMTP in phase 0, or use email + password, which is one call and
no email dependency at all.

### What sign-out does to local data

Recommended: keep it, and ask. "Sign out" clearing a year of history because the
button was ambiguous is unrecoverable. Offer a separate, clearly-worded "Sign out
and erase this device".

### Device labels

The takeover prompt is only useful if it names something you recognise.
Auto-generate from the user agent — "Chrome on Windows" — and let it be renamed
in Settings. A prompt reading "Running on device a7f3c1e2" is a prompt nobody can
act on.

### Free tier

500 MB and 5 GB egress are far beyond what this app will ever use — a decade of
logs is a few megabytes. The relevant limit is that free projects **pause after
7 days of inactivity**. For an app you use daily that never triggers, but a
two-week holiday will pause it, and the phone will report the cloud as
unreachable until you un-pause. Budget for the paid tier if that matters, and
make sure the error message names the real cause.

---

_Phases 0-3 deliver shared history; phases 4-5 deliver live handoff; 6-7 are what
make it survivable._
