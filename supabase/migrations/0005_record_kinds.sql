-- Phase 8 — full cross-device parity.
--
-- Leave dates and saved filter views become record kinds, so that signing in
-- on a new device reproduces the app exactly rather than only its logbook.
-- Everything else about the records table already works for any kind: the
-- pull query, the pull index, push_records and the RLS policies are all
-- written against the discriminator rather than against its values. The only
-- thing standing in the way is the CHECK that enumerates them.
--
-- RUN THIS BEFORE DEPLOYING THE MATCHING index.html.
--
-- Widening a CHECK is backward compatible in the strict sense: the currently
-- deployed client never sends 'leave' or 'view', so nothing about its
-- behaviour changes when they become legal. Deploying the client first,
-- however, breaks sync outright for every device until this runs — the push
-- fails with 23514, the whole cycle throws, and the panel reports a server it
-- cannot reach. Expand the schema first, then ship the code.
--
-- Idempotent: safe to run twice.

alter table public.records
  drop constraint if exists records_kind_check;

alter table public.records
  add constraint records_kind_check
  check (kind in ('log', 'task', 'leave', 'view'));

-- Verification. Expect one row, listing all four kinds.
--
-- select conname, pg_get_constraintdef(oid)
--   from pg_constraint
--  where conrelid = 'public.records'::regclass
--    and conname = 'records_kind_check';


-- ---------------------------------------------------------------------------
-- A phase 5 bug, found while testing the above: the FIRST settings write
-- against a missing session_state row was always discarded.
--
-- sync_session creates the row when it does not exist, and neither insert
-- names settings_modified, so it took the column default of now(). That is
-- LATER than the edit stamp the very same call is presenting, so the guard
--
--     settings = case when smod > s.settings_modified then p_settings ...
--
-- compared the caller's edit against a row stamped a few milliseconds into
-- its own future and threw the settings away, keeping the empty default.
-- The stamp still advanced, so the device believed it had synced and every
-- other device adopted an empty blob.
--
-- Intermittent in the wild - it needs the row to be absent, which is only
-- true before the first ever beat on an account, or after a factory reset -
-- and invisible until preferences that matter started travelling this way.
--
-- Epoch is the honest default: "this row has never carried a settings edit",
-- which is exactly true of a row that was just created, and it loses to any
-- real edit stamp instead of beating all of them.

alter table public.session_state
  alter column settings_modified set default 'epoch'::timestamptz;

-- Existing rows need no repair: they self-heal on the next edit, because any
-- real edit made from here on carries a stamp newer than they hold.
--
-- Verification. Expect 'epoch'::timestamp with time zone.
--
-- select column_default
--   from information_schema.columns
--  where table_name = 'session_state'
--    and column_name = 'settings_modified';
