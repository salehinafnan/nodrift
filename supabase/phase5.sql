-- Phase 5: one call per heartbeat that claims/renews the lease, writes the
-- live session only if the caller actually holds it, and applies settings
-- last-writer-wins regardless of the lease. Merging the claim and the write
-- into one statement is the point: they cannot be separated by another
-- device's takeover landing in between.
--
-- Idempotent. claim_session is left deployed and untouched.
create or replace function public.sync_session(
  p_device            uuid,
  p_claim             boolean default true,
  p_force             boolean default false,
  p_ttl_seconds       int     default 45,
  p_payload           jsonb   default null,
  p_task_payload      jsonb   default null,
  p_settings          jsonb   default null,
  p_settings_modified bigint  default null
) returns jsonb language plpgsql security invoker set search_path = public as $$
declare
  r     public.session_state;
  ttl   interval := make_interval(secs => p_ttl_seconds);
  mine  boolean;
  wr    boolean;
  smod  timestamptz := case when p_settings_modified is null then null
                       else to_timestamp(p_settings_modified / 1000.0) end;
begin
  if p_claim then
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
  end if;

  -- Either we did not claim, or the WHERE suppressed the update because a
  -- live holder that is not us owns the row.
  if r.user_id is null then
    insert into public.session_state (user_id) values (auth.uid())
    on conflict (user_id) do nothing;
    select * into r from public.session_state where user_id = auth.uid();
  end if;

  mine := coalesce(r.owner_device = p_device
                   and r.owner_expires_at > clock_timestamp(), false);
  -- A call that is not claiming never touches the live session, even from a
  -- device that happens to still hold the lease.
  wr := p_claim and mine;

  update public.session_state s
     set payload      = case when wr and p_payload is not null
                             then p_payload else s.payload end,
         task_payload = case when wr and p_task_payload is not null
                             then p_task_payload else s.task_payload end,
         -- Deliberately not lease-gated. Preferences are not measurements;
         -- losing the older of two edits costs nothing.
         settings          = case when smod is not null and smod > s.settings_modified
                                  then p_settings else s.settings end,
         settings_modified = case when smod is not null and smod > s.settings_modified
                                  then smod else s.settings_modified end
   where s.user_id = auth.uid()
   returning * into r;

  return jsonb_build_object(
    'held',              mine,
    'owner',             r.owner_device,
    -- Returned alongside now_ms so a watching device can tell a live holder
    -- from a stale one by comparing two readings of the SAME clock, with no
    -- offset entering the comparison at all.
    'owner_expires_ms',  (extract(epoch from r.owner_expires_at) * 1000)::bigint,
    'generation',        r.generation,
    'payload',           r.payload,
    'task_payload',      r.task_payload,
    'settings',          r.settings,
    'settings_modified', (extract(epoch from r.settings_modified) * 1000)::bigint,
    'now_ms',            (extract(epoch from clock_timestamp()) * 1000)::bigint
  );
end $$;

grant execute on function public.sync_session to authenticated;
