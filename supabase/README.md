# Supabase schema

Everything the sync backend consists of: three tables, three policies, five
functions, two triggers. Apply `migrations/` in filename order.

| File                                                      | What it creates                                                              | Blueprint |
| :-------------------------------------------------------- | :--------------------------------------------------------------------------- | :-------- |
| [0001_schema.sql](migrations/0001_schema.sql)             | `devices`, `session_state`, `records`, `records_pull_idx`                    | §6        |
| [0002_rls.sql](migrations/0002_rls.sql)                   | RLS enabled + forced, three `own_*` policies                                 | §6        |
| [0003_functions.sql](migrations/0003_functions.sql)       | `touch_updated_at` + triggers, `push_records`, `server_now`, `claim_session` | §6, §8    |
| [0004_sync_session.sql](migrations/0004_sync_session.sql) | `sync_session` — lease, live session and settings in one call                | Phase 5   |
| [0005_record_kinds.sql](migrations/0005_record_kinds.sql) | widens `kind` to `leave`/`view`; fixes a `settings_modified` default         | Phase 8   |

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
