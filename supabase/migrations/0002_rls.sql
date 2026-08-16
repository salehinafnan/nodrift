-- 0002 - row level security.
--
-- Extracted from section 6 of docs/SYNC-BLUEPRINT.md. The policies are dropped
-- before being recreated so the file can be re-run; the definitions are
-- unchanged.
--
-- This file is the entire reason the publishable key can sit in index.html in
-- a public repository. The key identifies the project, it does not grant
-- anything: every policy below is scoped `to authenticated` and compares
-- user_id against auth.uid(), so a caller holding nothing but the key has no
-- row it is allowed to see. Weakening anything here is what would turn that
-- key into a leak.

alter table public.records       enable row level security;
alter table public.session_state enable row level security;
alter table public.devices       enable row level security;

-- FORCE also applies the policy to the table owner. Without it a
-- misconfigured service role reads every user's data.
alter table public.records       force row level security;
alter table public.session_state force row level security;
alter table public.devices       force row level security;

drop policy if exists own_records on public.records;
create policy own_records on public.records for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists own_session on public.session_state;
create policy own_session on public.session_state for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists own_devices on public.devices;
create policy own_devices on public.devices for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

revoke all on public.records, public.session_state, public.devices from anon;

-- Verification. Expect three rows, all with forcerowsecurity = true.
--
-- select relname, relrowsecurity, relforcerowsecurity
--   from pg_class
--  where relname in ('records', 'session_state', 'devices');
