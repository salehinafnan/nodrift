-- 0003 - functions and triggers.
--
-- Extracted from sections 6 and 8 of docs/SYNC-BLUEPRINT.md. Every function
-- is already `create or replace`; the triggers are dropped before being
-- recreated so the file can be re-run. Definitions are unchanged.
--
-- claim_session is superseded by sync_session in 0004 but is deliberately
-- left deployed and untouched, as 0004 records.

-- ---------------------------------------------------------------------------
-- Server receipt stamp.

-- clock_timestamp(), not now(): now() returns TRANSACTION START time, so two
-- overlapping writes can be stamped in the opposite order to the one they
-- commit in, and a cursor steps straight over one.
--
-- This narrows the commit-ordering window but does not close it -- the stamp
-- is still assigned before the commit lands. The client closes the remainder
-- by rewinding its cursor five seconds on every pull; because the merge is
-- last-writer-wins and therefore idempotent, re-seeing a record costs one
-- comparison.
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := clock_timestamp();
  return new;
end $$;

drop trigger if exists records_touch on public.records;
create trigger records_touch before insert or update on public.records
  for each row execute function public.touch_updated_at();

drop trigger if exists session_touch on public.session_state;
create trigger session_touch before insert or update on public.session_state
  for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------------------
-- Push, with a server-side last-writer-wins guard.
--
-- PostgREST's built-in upsert overwrites unconditionally, which lets a device
-- that has been offline for a week clobber newer data. The guard lives in SQL
-- so the rule holds no matter what the client does.

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

-- ---------------------------------------------------------------------------
-- Server clock. The client measures its offset against this rather than
-- trusting the host wall clock for anything that crosses devices.

create or replace function public.server_now() returns bigint
language sql stable as $$
  select (extract(epoch from clock_timestamp()) * 1000)::bigint
$$;

grant execute on function public.server_now to authenticated;

-- ---------------------------------------------------------------------------
-- The session lease.
--
-- One statement, so two devices claiming simultaneously cannot both win.

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
