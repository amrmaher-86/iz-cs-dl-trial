-- 001 Academy calendar (IADB first; DLC fits the same tables)
-- Tables, session generator, clash view, student timetable, access rules.
-- Design source: architecture-spec.md v0.1 section 3 (acad_* tables) + specs/zoom-schedule-spec.md.
--
-- Runs as-is on the trial Supabase and on the CRM Supabase.
-- It needs two access functions to exist first (each side writes its own):
--   acad_is_staff()  -> true when the signed-in user is academy staff (may read)
--   acad_can_edit()  -> true when the signed-in user may change the calendar
-- Trial version: db/trial/00_access_helpers.sql. CRM: back them with the CRM's users and roles.
--
-- Deviations from the architecture spec, on purpose:
--   * acad_people stands in for "CRM users + acad_staff_roles" so outsource instructors
--     who never log in still have a record. In the CRM, add user_id (FK to CRM users) or map it.
--   * acad_cohort_weeks keeps two AI hosts (ai_host_id, ai_host2_id): the sheet allows "A/G".
--   * acad_program_units.deadline_days stands in for deadline_rule until G6 is decided.

create table if not exists acad_people (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,                 -- stable short id, e.g. 'gazia'
  name text not null,
  initial text,                              -- letter used in the D&L sheet for AI hosts
  email text,
  team text check (team in ('CS','D&L','Sales','Finance','Management')),
  roles text[] not null default '{}',        -- instructor, ai_host, psp_host, cs_agent, ...
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid default auth.uid()
);

create table if not exists acad_programs (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,                 -- iadb / dlc / ai_mastery
  name_ar text,
  name_en text not null,
  operating_model text not null check (operating_model in ('cohort_weekly','cohort_phased','subscription')),
  status text not null default 'active' check (status in ('active','sunsetting','archived')),
  default_session_pattern jsonb,
  subscription_months int,
  deferral_policy jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid default auth.uid()
);

create table if not exists acad_program_units (
  id uuid primary key default gen_random_uuid(),
  program_id uuid not null references acad_programs(id) on delete cascade,
  seq int not null,
  kind text not null check (kind in ('foundation','content','catch_up','phase','bootcamp')),
  code text not null,                        -- iadb-u01, dlc-3ds-max
  title_en text,
  title_ar text,
  schedule_title text,                       -- the team's sheet name, e.g. 'Colors & Styles' across 2 weeks
  part text,                                 -- '1 of 2'
  duration_weeks int not null default 1,
  default_instructor_id uuid references acad_people(id) on delete set null,
  ai_topic text,
  deliverables_en text[] not null default '{}',
  deliverables_ar text[] not null default '{}',
  weight_pct numeric,
  deadline_days int,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid default auth.uid(),
  unique (program_id, code)
);

create table if not exists acad_zoom_accounts (
  id uuid primary key default gen_random_uuid(),
  label text not null unique,
  email text,
  capacity int,
  is_active boolean not null default true,
  credentials_ref text,                      -- a pointer only; never the password
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid default auth.uid()
);

create table if not exists acad_cohorts (
  id uuid primary key default gen_random_uuid(),
  program_id uuid not null references acad_programs(id),
  code text not null unique,                 -- stable id, e.g. 'iadb-2026-10'
  name text not null,                        -- 'R45', 'DLC R35 Sep'
  start_date date,
  end_date date,
  status text not null default 'planned' check (status in ('planned','onboarding','running','closing','closed')),
  zoom_account_id uuid references acad_zoom_accounts(id) on delete set null,
  -- IADB: {"recap":{"day":"Sun","time":"19:00"},"qa":{...},"ai":{...}}
  -- DLC:  {"sessions":[{"label":"...","day":"Mon","time":"19:00"}]}
  session_pattern jsonb not null default '{}',
  links jsonb not null default '{}',         -- {"zoom": "...", "whatsapp": "...", "classroom": "..."}
  student_timetable_token text not null unique default replace(gen_random_uuid()::text, '-', ''),
  capacity int,
  sort_order int,
  color int,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid default auth.uid()
);

create table if not exists acad_cohort_weeks (
  id uuid primary key default gen_random_uuid(),
  cohort_id uuid not null references acad_cohorts(id) on delete cascade,
  seq int not null,
  week_start date not null check (extract(dow from week_start) = 0),   -- always a Sunday
  kind text not null check (kind in ('foundation','content','catch_up','phase')),
  unit_id uuid references acad_program_units(id) on delete set null,
  module_week int,                           -- DLC: week n of the module
  instructor_id uuid references acad_people(id) on delete set null,
  instructor2_id uuid references acad_people(id) on delete set null,
  ai_host_id uuid references acad_people(id) on delete set null,
  ai_host2_id uuid references acad_people(id) on delete set null,
  content_open_at timestamptz,
  note text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid default auth.uid(),
  unique (cohort_id, seq)
);

create table if not exists acad_sessions (
  id uuid primary key default gen_random_uuid(),
  cohort_id uuid references acad_cohorts(id) on delete cascade,   -- null for program-wide sessions (PSP, AI Mastery)
  week_id uuid references acad_cohort_weeks(id) on delete cascade,
  program_id uuid references acad_programs(id),
  type text not null check (type in ('recap','qa','ai','ai_application','onboarding','psp','workshop','aim_qa','bootcamp','phase_session')),
  label text,
  starts_at timestamptz not null,
  duration_min int not null default 120,
  host_id uuid references acad_people(id) on delete set null,
  backup_host_id uuid references acad_people(id) on delete set null,
  zoom_account_id uuid references acad_zoom_accounts(id) on delete set null,
  join_url text,
  status text not null default 'scheduled' check (status in ('scheduled','done','cancelled','moved')),
  is_manual_override boolean not null default false,   -- the generator never overwrites these
  generated_key text unique,                           -- makes the generator idempotent
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid default auth.uid()
);
create index if not exists acad_sessions_starts_at on acad_sessions (starts_at);
create index if not exists acad_sessions_cohort on acad_sessions (cohort_id);

create table if not exists acad_settings (
  key text primary key,     -- timezone, duration_min, psp, recurring, dlc_template
  value jsonb not null,
  updated_at timestamptz not null default now()
);

-- keep updated_at current
create or replace function acad_touch() returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;

do $$ declare t text; begin
  foreach t in array array['acad_people','acad_programs','acad_program_units','acad_zoom_accounts',
                           'acad_cohorts','acad_cohort_weeks','acad_sessions','acad_settings'] loop
    execute format('drop trigger if exists touch on %I; create trigger touch before update on %I for each row execute function acad_touch()', t, t);
  end loop;
end $$;

-- ---------- session generator ----------

create or replace function acad_day_offset(d text) returns int language sql immutable as $$
  select array_position(array['Sun','Mon','Tue','Wed','Thu','Fri','Sat'], d) - 1
$$;

create or replace function acad_setting(k text) returns jsonb language sql stable as $$
  select value from acad_settings where key = k
$$;

-- Wall-clock day + time in the academy timezone -> timestamptz
create or replace function acad_at(week_start date, d text, t text) returns timestamptz language sql stable as $$
  select ((week_start + acad_day_offset(d)) + t::time)
         at time zone coalesce(acad_setting('timezone') #>> '{}', 'Africa/Cairo')
$$;

-- Rebuilds the generated sessions of one cohort from its weeks and session pattern.
-- Safe to run any number of times. Sessions marked is_manual_override are left alone.
create or replace function acad_generate_sessions(p_cohort uuid) returns int
language plpgsql security definer set search_path = public as $$
declare
  c acad_cohorts; w acad_cohort_weeks; s jsonb; n int := 0; i int;
  dur int := coalesce((acad_setting('duration_min') #>> '{}')::int, 120);
  keys text[] := '{}'; k text;
begin
  select * into c from acad_cohorts where id = p_cohort;
  if not found then return 0; end if;

  for w in select * from acad_cohort_weeks where cohort_id = p_cohort order by seq loop
    -- what this week produces: type, pattern slot, host, backup, label
    for s in
      select x from jsonb_array_elements(case w.kind
        when 'foundation' then jsonb_build_array(jsonb_build_object('type','onboarding','slot','recap','host',w.instructor_id))
        when 'content' then jsonb_build_array(
          jsonb_build_object('type','recap','slot','recap','host',w.instructor_id),
          jsonb_build_object('type','qa','slot','qa','host',w.instructor_id),
          jsonb_build_object('type','ai','slot','ai','host',w.ai_host_id,'backup',w.ai_host2_id))
        when 'catch_up' then jsonb_build_array(jsonb_build_object('type','ai','slot','ai','host',w.ai_host_id,'backup',w.ai_host2_id))
        when 'phase' then (
          select coalesce(jsonb_agg(jsonb_build_object('type','phase_session','day',e->>'day','time',e->>'time',
                   'label',e->>'label','host',w.instructor_id,'backup',w.instructor2_id,'n',o)), '[]')
          from jsonb_array_elements(coalesce(c.session_pattern->'sessions','[]')) with ordinality as t(e, o))
        else '[]' end) as x
    loop
      -- day/time come from the slot in the cohort pattern (IADB) or from the entry itself (DLC)
      if s ? 'slot' then
        s := s || jsonb_build_object('day', c.session_pattern #>> array[s->>'slot','day'],
                                     'time', c.session_pattern #>> array[s->>'slot','time']);
      end if;
      continue when s->>'day' is null or s->>'time' is null;   -- days not set yet (e.g. R46)

      k := w.id || ':' || (s->>'type') || ':' || coalesce(s->>'n', '1');
      keys := keys || k;
      insert into acad_sessions as a (cohort_id, week_id, program_id, type, label, starts_at, duration_min,
                                      host_id, backup_host_id, zoom_account_id, join_url, generated_key)
      values (c.id, w.id, c.program_id, s->>'type', s->>'label', acad_at(w.week_start, s->>'day', s->>'time'), dur,
              (s->>'host')::uuid, (s->>'backup')::uuid, c.zoom_account_id, c.links->>'zoom', k)
      on conflict (generated_key) do update set
        starts_at = excluded.starts_at, duration_min = excluded.duration_min, label = excluded.label,
        host_id = excluded.host_id, backup_host_id = excluded.backup_host_id,
        zoom_account_id = excluded.zoom_account_id, join_url = excluded.join_url
      where not a.is_manual_override;
      n := n + 1;
    end loop;
  end loop;

  -- remove generated sessions that no longer follow from the weeks (kind changed, week deleted, day cleared)
  delete from acad_sessions
   where cohort_id = p_cohort and generated_key is not null
     and not is_manual_override and generated_key <> all (keys);
  return n;
end $$;

-- Program-wide weekly sessions (PSP, AI Mastery workshop and Q&A) for a date range.
-- Reads acad_settings 'psp' {day,time,host,account} and 'recurring' [{id,label,program,day,time,host,account}].
-- host = acad_people.slug, account = acad_zoom_accounts.label.
create or replace function acad_generate_program_sessions(p_from date, p_to date) returns int
language plpgsql security definer set search_path = public as $$
declare e jsonb; wk date; n int := 0; k text; typ text;
  dur int := coalesce((acad_setting('duration_min') #>> '{}')::int, 120);
begin
  for e in
    select acad_setting('psp') || jsonb_build_object('id','psp','type','psp','label','PSP')
    where acad_setting('psp') is not null
    union all
    select r || jsonb_build_object('type', case when r->>'label' ilike '%q&a%' then 'aim_qa' else 'workshop' end)
    from jsonb_array_elements(coalesce(acad_setting('recurring'), '[]')) r
  loop
    continue when e->>'day' is null or e->>'time' is null;
    for wk in select generate_series(p_from - extract(dow from p_from)::int, p_to, interval '7 days')::date loop
      k := 'program:' || (e->>'id') || ':' || wk;
      insert into acad_sessions as a (program_id, type, label, starts_at, duration_min, host_id, zoom_account_id, generated_key)
      values ((select id from acad_programs where code = case when e->>'program' ilike '%mastery%' then 'ai_mastery' else 'iadb' end),
              e->>'type', e->>'label', acad_at(wk, e->>'day', e->>'time'), dur,
              (select id from acad_people where slug = e->>'host'),
              (select id from acad_zoom_accounts where label = nullif(e->>'account','')), k)
      on conflict (generated_key) do update set
        starts_at = excluded.starts_at, label = excluded.label, host_id = excluded.host_id,
        zoom_account_id = excluded.zoom_account_id, duration_min = excluded.duration_min
      where not a.is_manual_override;
      n := n + 1;
    end loop;
  end loop;
  return n;
end $$;

-- regenerate automatically when a week or a cohort's pattern changes
create or replace function acad_regen_from_week() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform acad_generate_sessions(coalesce(new.cohort_id, old.cohort_id));
  return null;
end $$;

create or replace function acad_regen_from_cohort() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform acad_generate_sessions(new.id);
  return null;
end $$;

drop trigger if exists regen on acad_cohort_weeks;
create trigger regen after insert or update or delete on acad_cohort_weeks
  for each row execute function acad_regen_from_week();
drop trigger if exists regen on acad_cohorts;
create trigger regen after update of session_pattern, zoom_account_id, links on acad_cohorts
  for each row execute function acad_regen_from_cohort();

-- ---------- clashes ----------
-- Two live sessions that overlap in time and share a person or a Zoom account.
create or replace view acad_session_clashes with (security_invoker = true) as
select a.id as session_a, b.id as session_b,
       case when a.zoom_account_id = b.zoom_account_id then 'zoom_account' else 'person' end as reason,
       a.starts_at
from acad_sessions a
join acad_sessions b on a.id < b.id
 and tstzrange(a.starts_at, a.starts_at + make_interval(mins => a.duration_min))
  && tstzrange(b.starts_at, b.starts_at + make_interval(mins => b.duration_min))
where a.status not in ('cancelled','moved') and b.status not in ('cancelled','moved')
  and ( a.zoom_account_id = b.zoom_account_id
     or array_remove(array[a.host_id, a.backup_host_id], null) && array_remove(array[b.host_id, b.backup_host_id], null));

-- Weeks with nobody assigned (content week without instructor, AI session without host)
create or replace view acad_missing_people with (security_invoker = true) as
select w.id as week_id, w.cohort_id, w.week_start,
       case when w.kind = 'content' and w.instructor_id is null then 'no_instructor' else 'no_ai_host' end as problem
from acad_cohort_weeks w
where (w.kind = 'content' and w.instructor_id is null)
   or (w.kind in ('content','catch_up') and w.ai_host_id is null);

-- ---------- student timetable ----------
-- The only thing a student link can read: one cohort, student fields only, by its unguessable token.
-- Leaves out notes, Zoom accounts, other cohorts and anything about staff beyond names.
create or replace function acad_student_timetable(p_token text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'cohort', jsonb_build_object('name', c.name, 'program', p.code, 'program_name_ar', p.name_ar, 'program_name_en', p.name_en,
                                 'start_date', c.start_date, 'end_date', c.end_date, 'zoom_link', c.links->>'zoom'),
    'timezone', coalesce(acad_setting('timezone') #>> '{}', 'Africa/Cairo'),
    'weeks', coalesce((select jsonb_agg(jsonb_build_object(
        'seq', w.seq, 'week_start', w.week_start, 'kind', w.kind, 'module_week', w.module_week,
        'title_en', u.title_en, 'title_ar', u.title_ar, 'schedule_title', u.schedule_title, 'part', u.part,
        'ai_topic', u.ai_topic, 'deliverables_en', u.deliverables_en, 'deliverables_ar', u.deliverables_ar,
        'deadline_days', u.deadline_days,
        'instructor', i.name, 'ai_hosts', array_remove(array[h1.name, h2.name], null)) order by w.seq)
      from acad_cohort_weeks w
      left join acad_program_units u on u.id = w.unit_id
      left join acad_people i on i.id = w.instructor_id
      left join acad_people h1 on h1.id = w.ai_host_id
      left join acad_people h2 on h2.id = w.ai_host2_id
      where w.cohort_id = c.id), '[]'),
    'sessions', coalesce((select jsonb_agg(jsonb_build_object(
        'type', s.type, 'label', s.label, 'starts_at', s.starts_at, 'duration_min', s.duration_min,
        'host', h.name, 'status', s.status) order by s.starts_at)
      from acad_sessions s left join acad_people h on h.id = s.host_id
      where s.cohort_id = c.id or (s.cohort_id is null and s.type = 'psp')), '[]'))
  from acad_cohorts c join acad_programs p on p.id = c.program_id
  where c.student_timetable_token = p_token
$$;

-- ---------- access rules ----------
do $$ declare t text; begin
  foreach t in array array['acad_people','acad_programs','acad_program_units','acad_zoom_accounts',
                           'acad_cohorts','acad_cohort_weeks','acad_sessions','acad_settings'] loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists staff_read on %I', t);
    execute format('drop policy if exists editor_write on %I', t);
    execute format('create policy staff_read on %I for select to authenticated using (acad_is_staff())', t);
    execute format('create policy editor_write on %I for all to authenticated using (acad_can_edit()) with check (acad_can_edit())', t);
    execute format('grant select, insert, update, delete on %I to authenticated', t);
    execute format('revoke all on %I from anon', t);
  end loop;
end $$;

grant select on acad_session_clashes, acad_missing_people to authenticated;
revoke execute on function acad_generate_sessions(uuid), acad_generate_program_sessions(date, date) from public, anon;
grant execute on function acad_generate_sessions(uuid), acad_generate_program_sessions(date, date) to authenticated;
grant execute on function acad_student_timetable(text) to anon, authenticated;
