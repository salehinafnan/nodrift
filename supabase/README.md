# Supabase schema

Everything the sync backend consists of: three tables, three policies, five
functions, two triggers. Apply `migrations/` in filename order.

| File                                                                  | What it creates                                                                 | Blueprint |
| :-------------------------------------------------------------------- | :------------------------------------------------------------------------------ | :-------- |
| [0001_schema.sql](migrations/0001_schema.sql)                         | `devices`, `session_state`, `records`, `records_pull_idx`                       | §6        |
| [0002_rls.sql](migrations/0002_rls.sql)                               | RLS enabled + forced, three `own_*` policies                                    | §6        |
| [0003_functions.sql](migrations/0003_functions.sql)                   | `touch_updated_at` + triggers, `push_records`, `server_now`, `claim_session`    | §6, §8    |
| [0004_sync_session.sql](migrations/0004_sync_session.sql)             | `sync_session` — lease, live session and settings in one call                   | Phase 5   |
| [0005_record_kinds.sql](migrations/0005_record_kinds.sql)             | widens `kind` to `leave`/`view`; fixes a `settings_modified` default            | Phase 8   |
| [0006_realtime.sql](migrations/0006_realtime.sql)                     | publishes `session_state` and `records` for realtime — **optional**             | Phase 9   |
| [0007_realtime_columns.sql](migrations/0007_realtime_columns.sql)     | narrows both publications to the columns actually read — **optional**           | Phase 9   |
| [0008_one_write_per_beat.sql](migrations/0008_one_write_per_beat.sql) | folds the session write into the claim so a beat writes the row once, not twice | Scaling   |

0001–0003 were extracted from [../docs/SYNC-BLUEPRINT.md](../docs/SYNC-BLUEPRINT.md)
after the fact. Until then the schema of the deployed database existed only as
fenced code blocks inside a design document, which meant rebuilding production
would have started with reading prose.

0004 and 0005 are the files previously named `phase5.sql` and `phase8.sql`,
moved unchanged.

## Re-running is safe

Every file is idempotent. The blueprint's original script used bare
`create table` and `create policy`, which fail on the second run; the
extracted files add `if not exists` and `drop policy if exists` guards.
That is the **only** difference from the blueprint text — no definition was
altered, so these files still describe exactly what is deployed.

Each file ends with a commented-out verification query.

## Order matters in one place

0001 declares `kind in ('log', 'task')` and 0005 widens it to include
`'leave'` and `'view'`. A fresh project must therefore run both. Deploying a
current `index.html` against a database that stopped at 0001 breaks sync
outright for every device: the push fails with `23514`, the whole cycle
throws, and the panel reports a server it cannot reach. Expand the schema
first, then ship the client.

## One thing these files deliberately do not carry

§7 of the blueprint proposes pruning tombstones after 90 days on a weekly
`pg_cron` schedule:

```sql
delete from public.records
 where deleted and updated_at < now() - interval '90 days';
```

That is a recurring job rather than a schema object, so it does not belong in
a migration, and **whether it is scheduled on the project is not recorded
here** — check the dashboard rather than assuming either way. It also has a
client-side half that must ship with it: a device offline longer than the
retention window still holds the deleted record and never learns it went
away, so a cursor older than the window has to force a full resync instead of
a delta. Enabling the prune without that half loses deletions silently.

Aside from this, `migrations/` is the complete database. Verified
mechanically: every statement in the extracted files appears in the
blueprint, and the only blueprint statement not extracted is the one above.

## The migrations the app does not need

[0006_realtime.sql](migrations/0006_realtime.sql) and its follow-up
[0007_realtime_columns.sql](migrations/0007_realtime_columns.sql) are the only
files here that are optional, and it is worth knowing why before deciding
whether to run them.

Without 0006, cross-device latency is whatever the polling intervals are: a
device watching somebody else's shift beats every 20 seconds, and records are
pulled every 60. So finishing a shift on the laptop clears the phone within
about twenty seconds, and the log lands within a minute. With it, both
happen in well under a second.

`SyncLive` in `index.html` is an accelerator with no data path of its own. It
subscribes, and when a row changes it calls the same `beat()` and
`syncOnce()` the timers already call — earlier. If the tables are not
published the server refuses the subscription, the socket retires itself for
the rest of the page's life, and the app behaves exactly as it did before
realtime existed. **A refused subscription is not a failure state**; it is
reported on the panel as `live off — …` and nothing else changes.

Two consequences of that design worth keeping:

- Nothing may ever be delivered _only_ over the socket. The moment something
  is, an unpublished project silently loses a feature instead of losing some
  speed.
- Running the migration on a project whose users have the app open does not
  reach them until they reload — the socket retires per page load, so the
  refusal is remembered until the page is next opened.

0007 narrows what one of those publications carries. 0006 published both
tables whole, which put the full body of every row into the replication
stream — for `records` that is the whole log entry, `notes` included,
delivered to every connected device on every edit. The handler never opens it:
a record event calls `nudge("sync")` and the beat that follows re-reads over
REST. So 0007 publishes the primary key alone for `records`. Run 0006 first;
0007 assumes the table is already published and re-adds it with a column list.

**`session_state` is deliberately left whole, and that is a measured result
rather than a preference.** Narrowing it to the six columns
`sessionFingerprint()` reads is accepted by Postgres and visible in the
catalog, and Supabase Realtime then stops delivering its events entirely.
`harness-realtime.js` catches it — the lease nudge and the "renewals really
were arriving and being ignored" control both fail — and reverting that table
alone restores 13/13. The apparent rule is that Realtime tolerates a column
list on a table nobody reads the contents of, and not on one whose contents
drive a decision. The full reasoning is in the migration's header.

Same failure mode as 0006 throughout, which is what made that safe to find out
the hard way: a column list the chain mishandles ends in a refused
subscription or a fingerprint that stops varying, and both are just the
fallback to polling.

The CSP has to name the socket separately. `connect-src` lists the Supabase
host twice, once as `https://` and once as `wss://`, because Chrome does not
accept an `https://` source expression as covering `wss://` to the same host.
Measured, not assumed: without the second origin the socket is blocked with
`connect-src blocked wss://…` and the app quietly falls back to polling.

## Why the key in `index.html` is not a leak

`SUPABASE_ANON_KEY` is a publishable key and is public by design — it names
the project, it does not authorise anything. The app is static, so the browser
downloads every byte it runs; there is no server-side place to keep a secret
and nothing here is trying to.

What actually protects the data is [0002_rls.sql](migrations/0002_rls.sql):
RLS is `enable`d **and** `force`d on all three tables, and every policy is
scoped `to authenticated` with `user_id = auth.uid()`. A caller holding only
the publishable key has no row it is permitted to read. `force` matters as
much as `enable` — without it the policies do not apply to the table owner,
and a misconfigured service role reads every user's data.

The keys that must never appear in this repository are the **service role**
key and the database password. Neither has ever been committed.

## The one thing the app cannot do for itself

[`functions/delete-account`](functions/delete-account/index.ts) exists because
deleting a row from `records` is an ordinary authenticated request, but
deleting the _account_ means deleting from `auth.users`, and only the service
role may do that. Since the app is static and its source is public, that key
cannot be in the page — so this is the one piece of nodrift that runs
somewhere other than the browser.

It is not part of `migrations/` and is not applied by running the SQL. Deploy
it separately, once:

```
npx supabase functions deploy delete-account --project-ref <project-ref>
```

or paste the file into **Edge Functions → Deploy a new function** in the
dashboard. `SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY`
are injected by the platform; **nothing has to be pasted into a settings
field, and the service-role key never leaves Supabase.**

Until it is deployed the Delete account button answers "Account deletion is
not set up on this server yet." — a 404 from the function gateway, named
specifically so an undeployed feature cannot be mistaken for a failed
deletion.

The property the file exists to hold: **the user id being deleted comes from
the verified JWT, never from the request body.** Accepting an id from the
caller would make it delete anyone's account for anyone who asks, since
authentication would then prove only that the caller is _a_ user rather than
_that_ user. The cascade in [0001_schema.sql](migrations/0001_schema.sql) does
the rest — all three tables reference `auth.users on delete cascade`, so
removing the user removes the data with it.

### Do not remove the function's own token check

It looks redundant. Edge Functions are deployed with `verify_jwt` on, so the
platform gateway rejects a bad token before the function runs, and the
`GET /auth/v1/user` call inside looks like the same work done twice.

It is not. Measured against the deployed function on 2026-08-17:

| Sent as `Authorization`      | Answered by      | Status                        |
| :--------------------------- | :--------------- | :---------------------------- |
| nothing                      | the function     | 401 `Not signed in`           |
| a forged JWT                 | the **gateway**  | 401 `UNAUTHORIZED_LEGACY_JWT` |
| **the publishable anon key** | the **function** | 401 `Not signed in`           |

The third row is the point. The publishable key is a real JWT signed by this
project, so it satisfies `verify_jwt` and reaches the function body — and it
is printed in `index.html` in a public repository. The gateway answers "is
this a token from this project?"; only the `/auth/v1/user` call answers "is
this a signed-in user, and which one?". Delete that call and holding a key
anyone can read becomes enough to reach the deletion path.

`probe-delete-gate.js` in the harness asserts all three rows and needs no
account to run.
