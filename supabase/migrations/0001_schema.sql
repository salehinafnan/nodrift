-- 0001 - tables and indexes.
--
-- Extracted verbatim from section 6 of docs/SYNC-BLUEPRINT.md, which was the
-- only record of this schema until now. Guards were added so the file can be
-- re-run (see supabase/README.md); nothing else differs from what is deployed.
--
-- The kind check here allows only 'log' and 'task'. 0005 widens it. Applying
-- these in order on a fresh project reproduces the current database.

create extension if not exists pgcrypto;

-- One row per signed-in device. Only used to label the takeover prompt.
create table if not exists public.devices (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users on delete cascade,
  label        text not null default 'Unnamed device',
  last_seen_at timestamptz not null default now()
);

-- Singleton per user: the live session, the settings blob, the lease.
create table if not exists public.session_state (
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
--
-- Two timestamps, two jobs -- do not merge them. last_modified is when the
-- user edited the record and decides conflicts; updated_at is when the server
-- learned about it and drives the delta cursor. Using one field for both
-- loses data: device A edits offline at 09:00 and syncs at 14:00 while
-- device B's cursor sits at 11:00, so B queries > 11:00, A's record says
-- 09:00, and B never sees it. Ever.
create table if not exists public.records (
  user_id       uuid not null references auth.users on delete cascade,
  kind          text not null check (kind in ('log', 'task')),
  id            text not null,                      -- the app's own "log_xxx"
  payload       jsonb,                              -- null when deleted
  deleted       boolean not null default false,
  last_modified timestamptz not null,               -- author's edit time -> LWW
  updated_at    timestamptz not null default now(), -- server receipt -> cursor
  primary key (user_id, kind, id)
);

create index if not exists records_pull_idx
  on public.records (user_id, kind, updated_at);
