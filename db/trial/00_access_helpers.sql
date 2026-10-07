-- TRIAL ONLY. Run before migrations/20261007_001_acad_calendar.sql.
-- In the trial, everyone on the public.team allowlist (see public.is_team()) reads and edits.
-- The CRM writes its own versions of these two functions from its users and roles.
create or replace function acad_is_staff() returns boolean
language sql stable security definer set search_path = public as $$ select public.is_team() $$;

create or replace function acad_can_edit() returns boolean
language sql stable security definer set search_path = public as $$ select public.is_team() $$;
