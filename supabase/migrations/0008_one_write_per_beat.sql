-- 0008 - one row write per beat, not two.
--
-- Measured first, with probe-beat-cost.js against this database:
--
--     idle device  (p_claim=false)   6 beats -> 6 realtime events   (1.00/beat)
--     owner        (p_claim=true)    6 beats -> 12 realtime events  (2.00/beat)
--
-- Every one of those events came back to the device that caused it, was
-- recognised by sessionFingerprint() as a renewal, and was thrown away. The
-- heartbeatEvents counter caught 18 of 18. So the app pays for eighteen
-- messages to learn nothing.
--
-- WHERE THE SECOND WRITE COMES FROM
--
-- 0004 ends with an UPDATE that has no condition beyond the row's own
-- primary key:
--
--     update public.session_state s
--        set payload = case when wr and p_payload is not null
--                           then p_payload else s.payload end,
--            ...
--      where s.user_id = auth.uid();
--
-- The CASE arms decide what is written, never whether. On a beat that
-- changes nothing the statement still sets four columns to the values they
-- already hold, the session_touch trigger from 0003 still stamps
-- updated_at, and Postgres still writes a new tuple version -- it has no
-- no-op-UPDATE elimination, and the trigger would defeat one if it did.
-- That tuple is decoded, lands in the WAL, and is broadcast. 0007 records
-- the same fact from the other end: "a column list filters columns, not
-- statements: every UPDATE that produced an event before produces one now."
--
-- So a claiming beat writes the row twice -- once for the lease, once for
-- nothing -- and a watching beat, which claims nothing and changes nothing,
-- writes it once for nothing.
--
-- WHAT THIS FILE DOES
--
-- The lease renewal is irreducible: owner_expires_at genuinely advances
-- every beat, and that write is the whole point of a lease. The other one
-- is not. So the payload, the task and the settings are folded into the
-- claim statement that was already writing, and the statement that used to
-- run unconditionally is left only to the one case the claim cannot cover.
--
-- Reaching the DO UPDATE means the WHERE passed, and that is exactly the
-- condition that used to make `mine` true and therefore `wr` true. The gate
-- is the same gate; it has just moved into the statement it was gating.
--
--     owner:  2 writes -> 1   (the lease renewal, carrying the session)
--     idle:   1 write  -> 0   (nothing changed, so nothing is written)
--
-- The measured ceiling goes from about 21 concurrent users against the 2M
-- free-tier allowance to about 47, with no change to any client, any
-- cadence, or any timing the user can perceive.
--
-- WHAT IT DELIBERATELY DOES NOT CHANGE
--
-- Settings stay un-lease-gated. A device that cannot claim must still be
-- able to land a newer preferences blob, so the fallback UPDATE below still
-- exists -- but it now carries a condition, so on the overwhelming majority
-- of beats it matches no row and writes nothing.
--
-- The insert path is reproduced exactly rather than improved. On a brand
-- new row 0004 wrote the payload (via the second statement, where `wr` was
-- true) and did NOT write the settings (smod is a past instant and the
-- fresh row's settings_modified defaults to now(), so `smod > s.settings_
-- modified` was false). Both behaviours are preserved here. Changing the
-- second one looks like an improvement and is a separate decision with its
-- own LWW consequences; it is not smuggled in with a performance fix.
--
-- One event now carries both the renewal and the session change that used
-- to arrive as two. sessionFingerprint() reads owner_device, generation,
-- currentMode, idleLock, workAccumulated, breakAccumulated, the task's
-- isRunning and settings_modified -- all of them columns of the one tuple
-- that is now written. Nothing a watcher acted on before can be missed.
--
-- Idempotent: create or replace, same signature. Reverting is re-running
-- 0004, which is left deployed and untouched for exactly that reason.
--
-- Verify by re-running probe-beat-cost.js: the two ratios must read 0.00
-- and 1.00. Then harness-lease.js, harness-handoff.js and harness-phase7.js,
-- which are what prove the lease still means what it meant.

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
  smod  timestamptz := case when p_settings_modified is null then null
                       else to_timestamp(p_settings_modified / 1000.0) end;
begin
  if p_claim then
    -- The claim and the session write, in one statement and one tuple.
    insert into public.session_state as s
           (user_id, owner_device, owner_expires_at, payload, task_payload)
    values (auth.uid(), p_device, clock_timestamp() + ttl,
            coalesce(p_payload, '{}'::jsonb),
            coalesce(p_task_payload, '{}'::jsonb))
    on conflict (user_id) do update
       set owner_device     = p_device,
           owner_expires_at = clock_timestamp() + ttl,
           generation       = s.generation
             + case when s.owner_device is distinct from p_device then 1 else 0 end,
           -- Folded in from 0004's second statement. No `wr` test is needed:
           -- the WHERE below is what made `wr` true, and if it fails this
           -- SET never runs.
           payload      = case when p_payload is not null
                               then p_payload else s.payload end,
           task_payload = case when p_task_payload is not null
                               then p_task_payload else s.task_payload end,
           settings          = case when smod is not null and smod > s.settings_modified
                                    then p_settings else s.settings end,
           settings_modified = case when smod is not null and smod > s.settings_modified
                                    then smod else s.settings_modified end
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

    -- The only write left outside the claim, and the reason it survives:
    -- preferences are not lease-gated, so a device that could not claim must
    -- still be able to land a newer blob. Unlike the statement it replaces
    -- it is conditional, so on every beat that carries no newer settings --
    -- which is every beat but the one after a preference changes -- it
    -- matches no row, writes nothing, and produces no realtime event.
    update public.session_state s
       set settings          = p_settings,
           settings_modified = smod
     where s.user_id = auth.uid()
       and smod is not null
       and smod > s.settings_modified
    returning * into r;

    -- Nothing was newer. RETURNING .. INTO leaves r all-NULL when no row
    -- matched, so the row the caller is about to be told about has to be
    -- read rather than assumed.
    if r.user_id is null then
      select * into r from public.session_state where user_id = auth.uid();
    end if;
  end if;

  mine := coalesce(r.owner_device = p_device
                   and r.owner_expires_at > clock_timestamp(), false);

  return jsonb_build_object(
    'held',              mine,
    -- Returned alongside now_ms so a watching device can tell a live holder
    -- from a stale one by comparing two readings of the SAME clock, with no
    -- offset entering the comparison at all.
    'owner',             r.owner_device,
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
