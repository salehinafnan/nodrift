-- Phase 9: let the server say "something changed" instead of being asked.
--
-- The client polls perfectly well without this. What it buys is latency: a
-- watching device otherwise learns that a shift ended on its next watch beat
-- (up to 60s) and picks up a filed log on its next poll (up to 60s). With the
-- tables published, both arrive in well under a second.
--
-- Nothing in the app depends on it. SyncLive is an accelerator with no data
-- path of its own -- it only calls the same beat() and syncOnce() the timers
-- already call, earlier. If this file is never run, the subscription is
-- refused, the socket retires itself, and the app behaves exactly as it did
-- before it existed.
--
-- Idempotent: adding a table already in the publication raises
-- 42710 duplicate_object, which is caught per table rather than around the
-- whole block so the second table is still attempted.

do $$
begin
  begin
    alter publication supabase_realtime add table public.session_state;
  exception when duplicate_object then null;
  end;

  begin
    alter publication supabase_realtime add table public.records;
  exception when duplicate_object then null;
  end;
end $$;

-- Row-level security still applies to realtime. The policies in
-- 0002_rls.sql are what stop one account being told about another's changes,
-- and they are evaluated against the access token the socket joins with --
-- which is why SyncLive pushes a rotated token into the channel rather than
-- letting the old one lapse.
--
-- replica identity is deliberately left at its default. Postgres sends the
-- primary key on a delete, which is all the client needs: every change here
-- is a nudge to re-read, never a payload the app applies. Setting it to full
-- would put the whole row -- a live session, a whole log entry -- into the
-- WAL and out over the socket for no reader.

-- Verify:
--   select tablename from pg_publication_tables
--    where pubname = 'supabase_realtime' and schemaname = 'public';
--   -- expect: records, session_state
