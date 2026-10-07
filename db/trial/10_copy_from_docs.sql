-- TRIAL ONLY, one time. Copies the live schedule from the old generic table (public.docs, app 'schedule')
-- into the acad_* tables. Safe to re-run: it upserts by the old ids (slug / code / cohort+seq).
-- Program names come from programs.json (Programs hub); units come from the schedule settings.

-- programs
insert into acad_programs (code, name_en, name_ar, operating_model, status, subscription_months) values
  ('iadb', 'Interior AI Design & Business', 'دبلومة التصميم الداخلي والذكاء الاصطناعي والبيزنس', 'cohort_weekly', 'active', null),
  ('dlc', 'Design Like Crazy', null, 'cohort_phased', 'sunsetting', null),
  ('ai_mastery', 'Design AI Mastery', null, 'subscription', 'active', 3)
on conflict (code) do nothing;

-- people
insert into acad_people (slug, name, initial)
select d.id, d.data->>'name', nullif(d.data->>'initial', '')
from public.docs d where d.app = 'schedule' and d.collection = 'people'
on conflict (slug) do update set name = excluded.name, initial = excluded.initial;

-- settings
with s as (select data from public.docs where app = 'schedule' and collection = 'settings' and id = 'main')
insert into acad_settings (key, value)
select k, v from s, lateral (values
  ('timezone', to_jsonb(coalesce(s.data->>'timezone', 'Africa/Cairo'))),
  ('duration_min', coalesce(s.data->'duration_min', '120')),
  ('psp', s.data->'technical'),
  ('recurring', coalesce(s.data->'recurring', '[]')),
  ('dlc_template', s.data#>'{dlc,template}')) as t(k, v)
where v is not null
on conflict (key) do update set value = excluded.value;

-- Zoom accounts named on rounds or recurring sessions
insert into acad_zoom_accounts (label)
select distinct a from (
  select nullif(data->>'zoom_account', '') a from public.docs where app = 'schedule' and collection = 'rounds'
  union select nullif(r->>'account', '') from public.docs d, jsonb_array_elements(coalesce(d.data->'recurring','[]')) r
   where d.app = 'schedule' and d.collection = 'settings'
  union select nullif(data#>>'{technical,account}', '') from public.docs where app = 'schedule' and collection = 'settings') x
where a is not null
on conflict (label) do nothing;

-- IADB units (from settings.units)
insert into acad_program_units (program_id, seq, kind, code, title_en, title_ar, schedule_title, part, ai_topic,
                                deliverables_en, deliverables_ar, weight_pct, deadline_days)
select (select id from acad_programs where code = 'iadb'), u.ord, 'content', u.e->>'id', u.e->>'title', u.e->>'title_ar',
       u.e->>'short', u.e->>'part', u.e->>'ai_unit',
       coalesce(array(select jsonb_array_elements_text(u.e->'deliverables')), '{}'),
       coalesce(array(select jsonb_array_elements_text(u.e->'deliverables_ar')), '{}'),
       (u.e->>'weight_pct')::numeric, (u.e->>'deadline_days')::int
from public.docs d, jsonb_array_elements(d.data->'units') with ordinality as u(e, ord)
where d.app = 'schedule' and d.collection = 'settings' and d.id = 'main'
on conflict (program_id, code) do update set title_en = excluded.title_en, title_ar = excluded.title_ar,
  schedule_title = excluded.schedule_title, part = excluded.part, ai_topic = excluded.ai_topic,
  deliverables_en = excluded.deliverables_en, deliverables_ar = excluded.deliverables_ar,
  weight_pct = excluded.weight_pct, deadline_days = excluded.deadline_days;

-- DLC modules (from the DLC template, plus any module name used in a week)
insert into acad_program_units (program_id, seq, kind, code, title_en, schedule_title, duration_weeks)
select (select id from acad_programs where code = 'dlc'), row_number() over (order by min(ord)), 'phase',
       'dlc-' || trim(both '-' from regexp_replace(lower(name), '[^a-z0-9]+', '-', 'g')), name, name, max(weeks)
from (
  select t.e->>0 as name, (t.e->>1)::int as weeks, t.ord
  from acad_settings s, jsonb_array_elements(s.value) with ordinality as t(e, ord) where s.key = 'dlc_template'
  union all
  select distinct data->>'module', null::int, 1000::bigint from public.docs
  where app = 'schedule' and collection = 'weeks' and data->>'kind' = 'module' and data->>'module' is not null
) m group by name
on conflict (program_id, code) do nothing;

-- cohorts (rounds)
insert into acad_cohorts (program_id, code, name, session_pattern, links, zoom_account_id, sort_order, color, status)
select (select id from acad_programs where code = d.data->>'program_id'), d.id, d.data->>'name',
       case when d.data->>'program_id' = 'dlc' then jsonb_build_object('sessions', coalesce(d.data->'sessions', '[]'))
            else jsonb_strip_nulls(jsonb_build_object(
              'recap', case when d.data->>'recap_day' is not null then jsonb_build_object('day', d.data->>'recap_day', 'time', coalesce(d.data#>>'{times,recap}', '19:00')) end,
              'qa',    case when d.data->>'qa_day'    is not null then jsonb_build_object('day', d.data->>'qa_day',    'time', coalesce(d.data#>>'{times,qa}', '19:00')) end,
              'ai',    case when d.data->>'ai_day'    is not null then jsonb_build_object('day', d.data->>'ai_day',    'time', coalesce(d.data#>>'{times,ai}', '19:00')) end)) end,
       jsonb_strip_nulls(jsonb_build_object('zoom', nullif(d.data->>'zoom_link', ''))),
       (select id from acad_zoom_accounts where label = nullif(d.data->>'zoom_account', '')),
       (d.data->>'order')::int, (d.data->>'color')::int, 'running'
from public.docs d where d.app = 'schedule' and d.collection = 'rounds'
on conflict (code) do update set name = excluded.name, session_pattern = excluded.session_pattern, links = excluded.links,
  zoom_account_id = excluded.zoom_account_id, sort_order = excluded.sort_order, color = excluded.color;

-- weeks
insert into acad_cohort_weeks (cohort_id, seq, week_start, kind, unit_id, module_week,
                               instructor_id, instructor2_id, ai_host_id, ai_host2_id, note)
select c.id, (w.data->>'seq')::int, (w.data->>'week_start')::date,
       case w.data->>'kind' when 'module' then 'phase' else w.data->>'kind' end,
       case when w.data->>'kind' = 'module'
            then (select u.id from acad_program_units u where u.program_id = c.program_id and u.title_en = w.data->>'module')
            else (select u.id from acad_program_units u where u.program_id = c.program_id and u.code = w.data->>'unit_id') end,
       (w.data->>'module_week')::int,
       (select id from acad_people where slug = w.data->>'instructor'),
       (select id from acad_people where slug = w.data->>'instructor2'),
       (select id from acad_people where slug = w.data#>>'{ai_by,0}'),
       (select id from acad_people where slug = w.data#>>'{ai_by,1}'),
       coalesce(w.data->>'note', '')
from public.docs w join acad_cohorts c on c.code = w.data->>'round_id'
where w.app = 'schedule' and w.collection = 'weeks'
on conflict (cohort_id, seq) do update set week_start = excluded.week_start, kind = excluded.kind, unit_id = excluded.unit_id,
  module_week = excluded.module_week, instructor_id = excluded.instructor_id, instructor2_id = excluded.instructor2_id,
  ai_host_id = excluded.ai_host_id, ai_host2_id = excluded.ai_host2_id, note = excluded.note;

-- cohort dates from their weeks (end = Saturday of the last week)
update acad_cohorts c set start_date = x.s, end_date = x.e
from (select cohort_id, min(week_start) s, max(week_start) + 6 e from acad_cohort_weeks group by 1) x
where x.cohort_id = c.id;

-- sessions: the week triggers already built each cohort's sessions; add PSP and AI Mastery for the span
select acad_generate_program_sessions(min(week_start), max(week_start) + 6) from acad_cohort_weeks;
