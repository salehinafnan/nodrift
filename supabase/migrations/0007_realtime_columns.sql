-- 0007 - stop shipping row bodies to a reader that never opens them.
--
-- 0006 published `records` and `session_state` whole. Its note about replica
-- identity is right as far as it goes, but it only governs the OLD tuple on a
-- delete. The NEW tuple on every insert and update is decoded in full, lands
-- in the WAL in full, and is delivered over the socket in full. For `records`
-- that is the entire log entry -- including `notes`, which on this install
-- carries patient surnames and dates of service.
--
-- Nothing reads it. The postgres_changes handler in index.html dispatches on
-- the table name and, for a record, calls nudge("sync") and returns; the row
-- is never touched. The beat that follows re-reads through the ordinary
-- authenticated REST path under the ordinary policies. So the payload crossing
-- the socket buys exactly nothing, and costs a copy of the most sensitive
-- field in the app passing through a service that no other part of this
-- feature depends on.
--
-- A column list (PG15+) cuts it off at the source rather than at the client:
-- an unlisted column is never decoded, so it is not in the replication stream,
-- not in Realtime's memory, and not on the wire. `records` is narrowed to its
-- primary key, which the handler ignores and which is here only because
-- Postgres requires a published table's replica identity columns to be listed.
--
-- ---------------------------------------------------------------------------
-- WHY session_state IS NOT NARROWED HERE
--
-- It was, in the first version of this file, down to the six columns
-- sessionFingerprint() reads. Postgres accepted it and the catalog showed
-- exactly the requested list. Supabase Realtime then stopped delivering
-- session_state events altogether -- not a truncated record, no events.
--
-- Measured, not reasoned about. harness-realtime.js went from 13/13 to two
-- failures, both of them about session_state: the poke that changes
-- owner_device and generation produced no lease nudge, and the negative
-- control that checks renewals really were arriving and being ignored counted
-- zero of them in twenty seconds. Reverting session_state alone -- with
-- `records` left narrowed -- put the suite straight back to green, which is
-- also what rules out a flaky twenty-second window as the cause.
--
-- So the rule this file encodes is empirical: Supabase Realtime tolerates a
-- column list on a table nobody subscribes to the *contents* of, and does not
-- tolerate one on a table whose contents drive a decision. Do not narrow
-- session_state without re-running harness-realtime.js and watching those two
-- checks specifically -- everything else in that suite passes either way,
-- which is exactly how this would slip through.
--
-- The saving forgone is the `settings` blob, about 150 bytes an event. The
-- saving kept is the whole of every log entry, notes included.
-- ---------------------------------------------------------------------------
--
-- Note what this does NOT change. A column list filters columns, not
-- statements: every UPDATE that produced an event before produces one now. The
-- thing that stops a heartbeat renewal becoming a nudge is the fingerprint,
-- exactly as it was, and the feedback loop 0006's note describes stays closed
-- for the same reason it already did.
--
-- Why this is safe to run. If a column list is mishandled anywhere in the
-- chain the worst case is a refused subscription or a fingerprint that stops
-- varying, and both end in SyncLive retiring itself and the app falling back
-- to WATCH_ACTIVE_MS / WATCH_IDLE_MS polling -- which is what it did before
-- 0006 existed. No data path runs through the socket; it is an accelerator
-- with no state of its own. That is what made the session_state attempt above
-- a measurable disappointment rather than an outage.
--
-- RLS is unaffected. own_records compares user_id, which is published.
--
-- Idempotent. Changing a column list means dropping the table from the
-- publication and re-adding it -- ALTER PUBLICATION has no "alter the columns
-- of an already-published table" form, and SET TABLE would replace the
-- publication's entire table list rather than one entry. The drop is guarded
-- by a catalog lookup rather than an exception handler so that a genuine
-- failure still raises.
--
-- Requires 0006 to have been run: session_state is left exactly as that file
-- published it, and this file never mentions it.

do $$
begin
  if exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime'
       and schemaname = 'public'
       and tablename = 'records'
  ) then
    alter publication supabase_realtime drop table public.records;
  end if;

  alter publication supabase_realtime
    add table public.records (user_id, kind, id);
end $$;

-- Verification. attnames exists on pg_publication_tables from PG15, which is
-- also the version that introduced column lists.
--
-- select tablename, attnames
--   from pg_publication_tables
--  where pubname = 'supabase_realtime' and schemaname = 'public'
--  order by tablename;
--
-- -- expect exactly two rows:
-- --   records        {user_id,kind,id}
-- --   session_state  all nine columns -- see the block above
