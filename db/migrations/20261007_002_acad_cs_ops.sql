-- 002 Customer Support operations: students, follow-up call survey, tasks, tickets, QC alerts
-- Builds on 001 (calendar). Design sources:
--   architecture-spec.md v0.1 sections 3.3, 3.7-3.10 (acad_* tables)
--   specs/cs-tasks-spec.md (task rules and due times)
--   brainstorm/followup-calls-and-complaints.md (traffic-light survey, red rules, paths, tickets), agreed by Amr 2026-10-07
--
-- Needs one more access function besides acad_is_staff() / acad_can_edit():
--   acad_can_manage_followup() -> QC, top management and mega admins: may change questions and red rules.
-- Trial version: db/trial/01_followup_admin_helper.sql.
--
-- Deviations from the architecture spec, on purpose:
--   * Follow-up answers are a jsonb map keyed by question code, so QC can change questions without a migration.
--     Question sets are versioned and locked once used, so old calls keep the questions they were filled with.
--   * Ticket statuses follow the agreed path: new -> acknowledged -> assigned -> resolved -> confirmed -> closed.
--   * Ticket type 'payment' added for money blockers (routed to Sales / Finance).

-- ---------- students and enrollments ----------

create sequence if not exists acad_student_uid_seq;

create table if not exists acad_students (
  id uuid primary key default gen_random_uuid(),
  student_uid text not null unique default 'IZ-' || lpad(nextval('acad_student_uid_seq')::text, 6, '0'),
  full_name_ar text,
  full_name_en text,
  phones text[] not null default '{}',       -- international format, first = main
  emails text[] not null default '{}',       -- first = main
  country text,
  timezone text,
  crm_contact_id text,
  funnel_fusion_member_id text,
  classroom_email text,
  merged_into uuid references acad_students(id),
  is_sample boolean not null default false,  -- trial/demo rows; never real people
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid default auth.uid()
);

create table if not exists acad_enrollments (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references acad_students(id) on delete cascade,
  program_id uuid not null references acad_programs(id),
  cohort_id uuid references acad_cohorts(id),
  source text check (source in ('sales_handoff','renewal','transfer','deferral_move')),
  sales_owner_id uuid references acad_people(id) on delete set null,
  status text not null default 'pending_onboarding'
    check (status in ('pending_onboarding','active','deferred','completed','dropped','expired','refunded')),
  enrolled_at timestamptz not null default now(),
  activated_at timestamptz,
  access_until date,
  lifetime_content boolean not null default false,
  deferral_count int not null default 0,
  followup_owner_id uuid references acad_people(id) on delete set null,
  access_status text not null default 'not_granted' check (access_status in ('not_granted','granted','revoked')),
  autodesk_status text not null default 'not_needed' check (autodesk_status in ('not_needed','pending','created')),
  previous_enrollment_id uuid references acad_enrollments(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid default auth.uid(),
  unique (student_id, cohort_id)
);
create index if not exists acad_enrollments_cohort on acad_enrollments (cohort_id);

-- Who follows each round. The first by sort_order gets round tasks; every follow-up owner gets call tasks.
create table if not exists acad_cohort_owners (
  cohort_id uuid not null references acad_cohorts(id) on delete cascade,
  person_id uuid not null references acad_people(id) on delete cascade,
  role text not null default 'followup_owner' check (role in ('primary_owner','followup_owner')),
  sort_order int not null default 0,
  followup_share numeric,
  created_at timestamptz not null default now(),
  primary key (cohort_id, person_id)
);

-- ---------- follow-up survey configuration (editable by QC / management) ----------

create sequence if not exists acad_question_set_version_seq;

create table if not exists acad_followup_question_sets (
  id uuid primary key default gen_random_uuid(),
  version int not null unique default nextval('acad_question_set_version_seq'),
  effective_from date not null,              -- applies to weeks starting on/after this Sunday
  published_at timestamptz,                  -- null = draft, not used by calls yet
  note text,
  created_at timestamptz not null default now(),
  created_by uuid default auth.uid()
);

-- options (single / multi / yes_no):
--   [{"value":"reached","label_ar":"رد","color":"green","done":true,"ends_call":false,
--     "ticket":{"type":"technical","resolver_team":"Tech support"}}, ...]
-- options (stars): [{"min":4,"max":5,"color":"green"}, {"min":3,"max":3,"color":"yellow"}, {"min":1,"max":2,"color":"red"}]
create table if not exists acad_followup_questions (
  id uuid primary key default gen_random_uuid(),
  set_id uuid not null references acad_followup_question_sets(id) on delete cascade,
  seq int not null,
  code text not null,                        -- stable key used in answers and rules: outcome, studied, rating...
  text_ar text not null,
  text_en text,
  kind text not null check (kind in ('single','multi','stars','yes_no','text')),
  options jsonb not null default '[]',
  required boolean not null default true,
  is_active boolean not null default true,
  unique (set_id, code)
);

-- "Instant red" rules. kind + params:
--   open_complaint     {}                                   student has a complaint ticket not closed
--   no_answer_streak   {"weeks":2,"outcomes":["no_answer"]}  that outcome N weeks in a row
--   answer_in          {"question":"intent","values":["stop"]}
--   rating_at_most     {"question":"rating","max":2}
create table if not exists acad_red_rules (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  label_ar text not null,
  kind text not null check (kind in ('open_complaint','no_answer_streak','answer_in','rating_at_most')),
  params jsonb not null default '{}',
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid default auth.uid()
);

create table if not exists acad_message_templates (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,                 -- e.g. followup.yellow.tech, followup.no_answer
  title_ar text not null,
  body_ar text not null,                     -- placeholders: {{student_name}} {{cohort}} {{week}}
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---------- follow-up calls ----------
-- One row per attempt. The staff member fills it while talking to the student.
create table if not exists acad_followup_calls (
  id uuid primary key default gen_random_uuid(),
  enrollment_id uuid not null references acad_enrollments(id) on delete cascade,
  cohort_week_id uuid not null references acad_cohort_weeks(id) on delete cascade,
  caller_id uuid references acad_people(id) on delete set null,
  called_at timestamptz not null default now(),
  question_set_id uuid references acad_followup_question_sets(id),
  answers jsonb not null default '{}',       -- {"outcome":"reached","studied":"part","blockers":["tech"],"rating":4,...}
  note text,                                 -- free note, or the Meqsem summary
  outcome text,                              -- copy of answers.outcome, for reports
  is_done boolean not null default false,    -- the call counts as made (outcome option has "done": true)
  color text check (color in ('green','yellow','red')),
  red_reasons text[] not null default '{}',
  yellow_reasons text[] not null default '{}',
  source text not null default 'manual' check (source in ('manual','meqsem')),
  external_call_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid default auth.uid()
);
create index if not exists acad_calls_enrollment_week on acad_followup_calls (enrollment_id, cohort_week_id, called_at desc);

-- ---------- tasks ----------

create table if not exists acad_task_templates (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,                 -- cs.followup_calls, cs.zoom_reminder, ... (generator rules are keyed by code)
  title_ar text not null,
  title_en text,
  team text not null default 'CS',
  trigger_type text not null check (trigger_type in ('cohort_lifecycle','cohort_weekly','per_session','per_enrollment','phase_change','recurring','event','manual')),
  offset_days int not null default 0,        -- added to the anchor date (see generator)
  due_time time,                             -- Cairo wall-clock time; null = keep the anchor's time
  due_hours int,                             -- event tasks: due this many hours after the event
  assignee_rule text not null default 'cohort_primary_owner'
    check (assignee_rule in ('cohort_primary_owner','followup_owner','caller','ticket_assignee','psp_owner','aim_owner','fixed_user','none')),
  fixed_assignee_id uuid references acad_people(id) on delete set null,
  steps jsonb not null default '[]',         -- ["step 1", "step 2"]
  evidence_type text not null default 'none' check (evidence_type in ('none','link','text','form','checklist')),
  message_template_code text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists acad_tasks (
  id uuid primary key default gen_random_uuid(),
  template_id uuid references acad_task_templates(id) on delete set null,
  dedupe_key text unique,                    -- template + entity + period; null for manual tasks
  program_id uuid references acad_programs(id),
  cohort_id uuid references acad_cohorts(id) on delete cascade,
  week_id uuid references acad_cohort_weeks(id) on delete cascade,
  session_id uuid references acad_sessions(id) on delete cascade,
  enrollment_id uuid references acad_enrollments(id) on delete cascade,
  ticket_id uuid,                            -- FK added after acad_tickets
  call_id uuid references acad_followup_calls(id) on delete set null,
  title_ar text not null,
  title_en text,
  type text,                                 -- template code or a manual type (inquiry, payment, ...)
  team text not null default 'CS',
  assignee_id uuid references acad_people(id) on delete set null,
  due_at timestamptz,
  status text not null default 'todo' check (status in ('todo','in_progress','done','skipped','blocked')),
  steps jsonb not null default '[]',         -- [{"label":"...","done":false}]
  notes text not null default '',
  evidence_text text,
  evidence_url text,
  completed_at timestamptz,
  completed_by uuid references acad_people(id) on delete set null,
  skip_reason text,
  origin text not null default 'manual' check (origin in ('generated','event','manual')),
  is_due_locked boolean not null default false,       -- a person moved the due date; the generator keeps it
  is_assignee_locked boolean not null default false,  -- a person reassigned it; the generator keeps it
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid default auth.uid()
);
create index if not exists acad_tasks_assignee_due on acad_tasks (assignee_id, due_at);
create index if not exists acad_tasks_due on acad_tasks (due_at);

create table if not exists acad_task_events (
  id bigint generated always as identity primary key,
  task_id uuid not null references acad_tasks(id) on delete cascade,
  at timestamptz not null default now(),
  actor uuid default auth.uid(),
  field text not null,
  old_value text,
  new_value text
);

-- ---------- tickets ----------

create sequence if not exists acad_ticket_seq;

create table if not exists acad_tickets (
  id uuid primary key default gen_random_uuid(),
  number text not null unique default 'T-' || to_char(now(), 'YYYY') || '-' || lpad(nextval('acad_ticket_seq')::text, 4, '0'),
  student_id uuid references acad_students(id) on delete set null,
  enrollment_id uuid references acad_enrollments(id) on delete set null,
  cohort_id uuid references acad_cohorts(id) on delete set null,
  week_id uuid references acad_cohort_weeks(id) on delete set null,
  call_id uuid references acad_followup_calls(id) on delete set null,
  type text not null check (type in ('complaint','technical','access','deferral','refund','one_on_one','inquiry','payment','other')),
  channel text not null default 'call' check (channel in ('whatsapp','call','followup_call','instructor','management','sales','other')),
  received_by uuid references acad_people(id) on delete set null,   -- who got it first, even outside CS
  assignee_id uuid references acad_people(id) on delete set null,   -- always someone in CS (CS is the single door, D5)
  resolver_team text,                        -- Tech support / D&L / CS / Sales / Finance / Management
  resolver_id uuid references acad_people(id) on delete set null,
  priority text not null default 'normal' check (priority in ('normal','important','urgent')),
  status text not null default 'new' check (status in ('new','acknowledged','assigned','resolved','confirmed','closed')),
  title text not null,
  description text,
  sla_due_at timestamptz,
  acknowledged_at timestamptz,
  resolved_at timestamptz,
  confirmed_at timestamptz,                  -- confirmed with the student that it is solved
  closed_at timestamptz,
  resolution_ar text,
  satisfaction int check (satisfaction between 1 and 5),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid default auth.uid(),
  -- no ticket closes without confirming with the student
  constraint confirm_before_close check (status <> 'closed' or confirmed_at is not null),
  constraint resolve_before_confirm check (status not in ('confirmed','closed') or resolved_at is not null)
);
create index if not exists acad_tickets_student_open on acad_tickets (student_id) where status <> 'closed';

do $$ begin
  alter table acad_tasks add constraint acad_tasks_ticket_fk foreign key (ticket_id) references acad_tickets(id) on delete cascade;
exception when duplicate_object then null; end $$;

create table if not exists acad_ticket_events (
  id bigint generated always as identity primary key,
  ticket_id uuid not null references acad_tickets(id) on delete cascade,
  at timestamptz not null default now(),
  actor uuid default auth.uid(),
  kind text not null,                        -- created, status, assignee, priority, note
  old_value text,
  new_value text,
  note text
);

-- ---------- alerts (QC and others) ----------

create table if not exists acad_alerts (
  id uuid primary key default gen_random_uuid(),
  audience text not null default 'qc',       -- qc / management / cs
  kind text not null,                        -- student_red, ticket_overdue, ...
  enrollment_id uuid references acad_enrollments(id) on delete cascade,
  call_id uuid references acad_followup_calls(id) on delete cascade,
  ticket_id uuid references acad_tickets(id) on delete cascade,
  message_ar text not null,
  dedupe_key text unique,
  created_at timestamptz not null default now(),
  read_at timestamptz,
  read_by uuid
);

do $$ declare t text; begin
  foreach t in array array['acad_students','acad_enrollments','acad_red_rules','acad_message_templates','acad_followup_calls',
                           'acad_task_templates','acad_tasks','acad_tickets'] loop
    execute format('drop trigger if exists touch on %I; create trigger touch before update on %I for each row execute function acad_touch()', t, t);
  end loop;
end $$;

-- ======================================================================
-- Follow-up survey logic
-- ======================================================================

-- Question set in force for a week (latest published set whose effective_from <= that Sunday)
create or replace function acad_question_set_for(p_week_start date) returns uuid language sql stable as $$
  select id from acad_followup_question_sets
  where published_at is not null and effective_from <= p_week_start
  order by effective_from desc, version desc limit 1
$$;

-- A set that calls already used is locked: edit a copy instead (acad_clone_question_set).
create or replace function acad_lock_used_questions() returns trigger language plpgsql as $$
declare sid uuid := coalesce(new.set_id, old.set_id);
begin
  if exists (select 1 from acad_followup_calls where question_set_id = sid) then
    raise exception 'Question set % is already used by calls. Clone it with acad_clone_question_set() and edit the copy.', sid;
  end if;
  return coalesce(new, old);
end $$;
drop trigger if exists lock_used on acad_followup_questions;
create trigger lock_used before insert or update or delete on acad_followup_questions
  for each row execute function acad_lock_used_questions();

-- Copy a set into a new draft. Default start: next Sunday ("changes apply from next week").
create or replace function acad_clone_question_set(p_from uuid, p_effective_from date default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare nid uuid;
begin
  if not acad_can_manage_followup() then raise exception 'Only QC or management can change the follow-up questions'; end if;
  insert into acad_followup_question_sets (effective_from, note)
  values (coalesce(p_effective_from, current_date + (7 - extract(dow from current_date)::int)),
          'Copy of version ' || (select version from acad_followup_question_sets where id = p_from))
  returning id into nid;
  insert into acad_followup_questions (set_id, seq, code, text_ar, text_en, kind, options, required, is_active)
  select nid, seq, code, text_ar, text_en, kind, options, required, is_active from acad_followup_questions where set_id = p_from;
  return nid;
end $$;

-- Colour of one answer: green / yellow / red / null (no colour, e.g. text)
create or replace function acad_answer_color(q acad_followup_questions, a jsonb) returns text language sql immutable as $$
  select case
    when a is null or a = 'null'::jsonb then null
    when q.kind in ('single','yes_no') then (select o->>'color' from jsonb_array_elements(q.options) o where o->>'value' = a #>> '{}' limit 1)
    when q.kind = 'multi' then (
      select case when bool_or(o->>'color' = 'red') then 'red' when bool_or(o->>'color' = 'yellow') then 'yellow'
                  when bool_or(o->>'color' = 'green') then 'green' end
      from jsonb_array_elements(q.options) o
      where jsonb_typeof(a) = 'array' and a ? (o->>'value'))
    when q.kind = 'stars' then (
      select o->>'color' from jsonb_array_elements(q.options) o
      where (a #>> '{}')::numeric between (o->>'min')::numeric and (o->>'max')::numeric limit 1)
    end
$$;

-- Before saving a call: pick the question set, check required answers, work out the colour and reasons.
create or replace function acad_call_evaluate() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  w acad_cohort_weeks; q acad_followup_questions; r acad_red_rules; c text; a jsonb;
  ended boolean := false; worst int := 0; prev_week uuid; streak int; o jsonb;
  rank constant jsonb := '{"green":1,"yellow":2,"red":3}';
begin
  select * into w from acad_cohort_weeks where id = new.cohort_week_id;
  new.question_set_id := coalesce(new.question_set_id, acad_question_set_for(w.week_start));
  if new.question_set_id is null then raise exception 'No published follow-up question set for the week of %', w.week_start; end if;
  new.outcome := new.answers->>'outcome';
  new.red_reasons := '{}'; new.yellow_reasons := '{}';

  -- does the outcome end the call (no answer, wrong number)?
  select o2 into o from acad_followup_questions q2, jsonb_array_elements(q2.options) o2
   where q2.set_id = new.question_set_id and q2.code = 'outcome' and o2->>'value' = new.outcome;
  ended := coalesce((o->>'ends_call')::boolean, false);
  new.is_done := coalesce((o->>'done')::boolean, false);

  for q in select * from acad_followup_questions where set_id = new.question_set_id and is_active order by seq loop
    continue when ended and q.code <> 'outcome';
    a := new.answers -> q.code;
    if (a is null or a = 'null'::jsonb or a = '""'::jsonb or a = '[]'::jsonb) and q.required and q.kind <> 'text' then
      raise exception 'Missing answer: %', q.text_ar;
    end if;
    c := acad_answer_color(q, a);
    continue when c is null;
    worst := greatest(worst, (rank->>c)::int);
    if c = 'red' then new.red_reasons := new.red_reasons || q.code;
    elsif c = 'yellow' then new.yellow_reasons := new.yellow_reasons || q.code; end if;
  end loop;

  -- instant-red rules
  for r in select * from acad_red_rules where is_active loop
    if r.kind = 'open_complaint' and exists (
         select 1 from acad_tickets t join acad_enrollments e on e.student_id = t.student_id
         where e.id = new.enrollment_id and t.type = 'complaint' and t.status <> 'closed') then
      new.red_reasons := new.red_reasons || r.code;
    elsif r.kind = 'answer_in' and new.answers ? (r.params->>'question')
          and (new.answers->>(r.params->>'question')) in (select jsonb_array_elements_text(r.params->'values')) then
      new.red_reasons := new.red_reasons || r.code;
    elsif r.kind = 'rating_at_most' and jsonb_typeof(new.answers->(r.params->>'question')) = 'number'
          and (new.answers->>(r.params->>'question'))::numeric <= (r.params->>'max')::numeric then
      new.red_reasons := new.red_reasons || r.code;
    elsif r.kind = 'no_answer_streak' and new.outcome in (select jsonb_array_elements_text(r.params->'outcomes')) then
      -- count earlier content weeks of this round, newest first, whose latest call had one of these outcomes
      streak := 1;
      for prev_week in
        select pw.id from acad_cohort_weeks pw
        where pw.cohort_id = w.cohort_id and pw.seq < w.seq and pw.kind = 'content'
        order by pw.seq desc limit greatest(coalesce((r.params->>'weeks')::int, 2) - 1, 0)
      loop
        exit when not exists (
          select 1 from (select outcome from acad_followup_calls x
                         where x.enrollment_id = new.enrollment_id and x.cohort_week_id = prev_week
                         order by called_at desc limit 1) l
          where l.outcome in (select jsonb_array_elements_text(r.params->'outcomes')));
        streak := streak + 1;
      end loop;
      if streak >= coalesce((r.params->>'weeks')::int, 2) then new.red_reasons := new.red_reasons || r.code; end if;
    end if;
  end loop;

  new.red_reasons := array(select distinct x from unnest(new.red_reasons) x);
  new.color := case when cardinality(new.red_reasons) > 0 then 'red'
                    when worst = 2 then 'yellow' else 'green' end;
  return new;
end $$;
drop trigger if exists evaluate on acad_followup_calls;
create trigger evaluate before insert or update of answers, enrollment_id, cohort_week_id on acad_followup_calls
  for each row execute function acad_call_evaluate();

-- Render a message template for one enrollment and week
create or replace function acad_render_message(p_code text, p_enrollment uuid, p_week uuid) returns text
language sql stable security definer set search_path = public as $$
  select replace(replace(replace(m.body_ar,
           '{{student_name}}', coalesce(s.full_name_ar, s.full_name_en, '')),
           '{{cohort}}', coalesce(c.name, '')),
           '{{week}}', coalesce(w.seq::text, ''))
  from acad_message_templates m, acad_enrollments e
  join acad_students s on s.id = e.student_id
  left join acad_cohorts c on c.id = e.cohort_id
  left join acad_cohort_weeks w on w.id = p_week
  where m.code = p_code and m.is_active and e.id = p_enrollment
$$;

-- Upsert a task created by an event (red student, no answer, ticket...). Keeps people's edits.
create or replace function acad_event_task(p_template text, p_key text, p_assignee uuid, p_due timestamptz,
  p_title_suffix text, p_enrollment uuid default null, p_week uuid default null, p_call uuid default null,
  p_ticket uuid default null, p_evidence text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare t acad_task_templates; tid uuid; e acad_enrollments;
begin
  select * into t from acad_task_templates where code = p_template and is_active;
  if not found then return null; end if;
  select * into e from acad_enrollments where id = p_enrollment;
  insert into acad_tasks as k (template_id, dedupe_key, program_id, cohort_id, week_id, enrollment_id, call_id, ticket_id,
                               title_ar, title_en, type, team, assignee_id, due_at, steps, evidence_text, origin)
  values (t.id, p_key, e.program_id, e.cohort_id, p_week, p_enrollment, p_call, p_ticket,
          t.title_ar || coalesce(': ' || p_title_suffix, ''), t.title_en, t.code, t.team, p_assignee, p_due,
          (select coalesce(jsonb_agg(jsonb_build_object('label', s, 'done', false)), '[]') from jsonb_array_elements_text(t.steps) s),
          p_evidence, 'event')
  on conflict (dedupe_key) do update set
    call_id = excluded.call_id, evidence_text = coalesce(excluded.evidence_text, k.evidence_text),
    due_at = case when k.is_due_locked then k.due_at else excluded.due_at end,
    assignee_id = case when k.is_assignee_locked then k.assignee_id else excluded.assignee_id end,
    status = case when k.status in ('skipped') then 'todo' else k.status end
  returning id into tid;
  return tid;
end $$;

-- After saving a call: follow the colour's path.
--   red    -> at-risk task for the caller (48h) + QC alert
--   yellow -> task with a ready WhatsApp message for the reason
--   no answer twice in the same week -> task with the no-answer WhatsApp message
-- and close the caller's weekly follow-up task when every student on their list is done.
create or replace function acad_call_paths() returns trigger
language plpgsql security definer set search_path = public as $$
declare s acad_students; wk acad_cohort_weeks; reason text; msg text; attempts int; total int; done int;
begin
  select st.* into s from acad_students st join acad_enrollments e on e.student_id = st.id where e.id = new.enrollment_id;
  select * into wk from acad_cohort_weeks where id = new.cohort_week_id;

  if new.color = 'red' then
    perform acad_event_task('cs.student_at_risk', 'at_risk:' || new.enrollment_id || ':' || new.cohort_week_id,
      new.caller_id, new.called_at + make_interval(hours => coalesce((select due_hours from acad_task_templates where code = 'cs.student_at_risk'), 48)),
      coalesce(s.full_name_ar, s.full_name_en), new.enrollment_id, new.cohort_week_id, new.id);
    insert into acad_alerts (audience, kind, enrollment_id, call_id, message_ar, dedupe_key)
    values ('qc', 'student_red', new.enrollment_id, new.id,
            'طالب في خطر: ' || coalesce(s.full_name_ar, s.full_name_en, '') || ' (' || array_to_string(new.red_reasons, '، ') || ')',
            'red:' || new.enrollment_id || ':' || new.cohort_week_id)
    on conflict (dedupe_key) do update set call_id = excluded.call_id, message_ar = excluded.message_ar, read_at = null, read_by = null;
  elsif new.color = 'yellow' then
    reason := coalesce((select b from jsonb_array_elements_text(case when jsonb_typeof(new.answers->'blockers') = 'array'
                                                                     then new.answers->'blockers' else '[]' end) b
                        where b <> 'none' limit 1), new.yellow_reasons[1]);
    msg := coalesce(acad_render_message('followup.yellow.' || reason, new.enrollment_id, new.cohort_week_id),
                    acad_render_message('followup.yellow', new.enrollment_id, new.cohort_week_id));
    perform acad_event_task('cs.followup_whatsapp', 'yellow:' || new.enrollment_id || ':' || new.cohort_week_id,
      new.caller_id, new.called_at + interval '1 day', coalesce(s.full_name_ar, s.full_name_en),
      new.enrollment_id, new.cohort_week_id, new.id, null, msg);
  end if;

  if new.outcome = 'no_answer' then
    select count(*) into attempts from acad_followup_calls
     where enrollment_id = new.enrollment_id and cohort_week_id = new.cohort_week_id and outcome = 'no_answer';
    if attempts >= coalesce((select (value #>> '{}')::int from acad_settings where key = 'followup_no_answer_attempts'), 2) then
      perform acad_event_task('cs.followup_no_answer', 'no_answer:' || new.enrollment_id || ':' || new.cohort_week_id,
        new.caller_id, new.called_at + interval '4 hours', coalesce(s.full_name_ar, s.full_name_en),
        new.enrollment_id, new.cohort_week_id, new.id, null,
        acad_render_message('followup.no_answer', new.enrollment_id, new.cohort_week_id));
    end if;
  end if;

  -- weekly follow-up task progress for this caller's list
  select count(*), count(*) filter (where exists (
           select 1 from acad_followup_calls x where x.enrollment_id = e.id and x.cohort_week_id = new.cohort_week_id and x.is_done))
    into total, done
  from acad_enrollments e
  where e.cohort_id = wk.cohort_id and e.status = 'active' and e.followup_owner_id = new.caller_id;
  update acad_tasks set status = case when total > 0 and done >= total then 'done' else status end,
                        completed_at = case when total > 0 and done >= total then coalesce(completed_at, now()) else completed_at end,
                        evidence_text = done || '/' || total || ' calls'
   where dedupe_key = 'followup:' || new.cohort_week_id || ':' || new.caller_id and status <> 'skipped';
  return null;
end $$;
drop trigger if exists paths on acad_followup_calls;
create trigger paths after insert or update of answers on acad_followup_calls
  for each row execute function acad_call_paths();

-- Each student's latest call per week (the week's result)
create or replace view acad_followup_week_results with (security_invoker = true) as
select distinct on (c.enrollment_id, c.cohort_week_id)
       c.enrollment_id, c.cohort_week_id, c.id as call_id, c.called_at, c.caller_id, c.outcome, c.is_done,
       c.color, c.red_reasons, c.yellow_reasons, c.answers, c.note,
       (select count(*) from acad_followup_calls x where x.enrollment_id = c.enrollment_id and x.cohort_week_id = c.cohort_week_id) as attempts
from acad_followup_calls c
order by c.enrollment_id, c.cohort_week_id, c.called_at desc;

-- Each active student's state now: last result, flag to ask about this week (last week's yellow reasons),
-- open complaint, and the overall colour (an open complaint keeps them red until it closes).
create or replace view acad_enrollment_followup with (security_invoker = true) as
select e.id as enrollment_id, e.student_id, e.cohort_id, e.followup_owner_id,
       last.cohort_week_id as last_week_id, last.color as last_color, last.red_reasons as last_red_reasons,
       last.yellow_reasons as ask_about_this_week,
       exists (select 1 from acad_tickets t where t.student_id = e.student_id and t.type = 'complaint' and t.status <> 'closed') as open_complaint,
       case when exists (select 1 from acad_tickets t where t.student_id = e.student_id and t.type = 'complaint' and t.status <> 'closed')
            then 'red' else last.color end as risk
from acad_enrollments e
left join lateral (
  select r.* from acad_followup_week_results r join acad_cohort_weeks w on w.id = r.cohort_week_id
  where r.enrollment_id = e.id order by w.seq desc limit 1) last on true
where e.status = 'active';

-- ======================================================================
-- Tickets
-- ======================================================================

create or replace function acad_ticket_before() returns trigger language plpgsql as $$
declare hours int;
begin
  if tg_op = 'INSERT' then
    hours := coalesce((acad_setting('ticket_sla_hours') ->> new.priority)::int, 48);
    new.sla_due_at := coalesce(new.sla_due_at, now() + make_interval(hours => hours));
    if new.student_id is null and new.enrollment_id is not null then
      select student_id, cohort_id into new.student_id, new.cohort_id from acad_enrollments where id = new.enrollment_id;
    end if;
  end if;
  if tg_op = 'INSERT' or new.status is distinct from old.status then
    if new.status = 'acknowledged' then new.acknowledged_at := coalesce(new.acknowledged_at, now()); end if;
    if new.status = 'resolved' then new.resolved_at := coalesce(new.resolved_at, now()); end if;
    if new.status = 'confirmed' then new.confirmed_at := coalesce(new.confirmed_at, now()); end if;
    if new.status = 'closed' then new.closed_at := coalesce(new.closed_at, now()); end if;
  end if;
  return new;
end $$;
drop trigger if exists before_save on acad_tickets;
create trigger before_save before insert or update on acad_tickets for each row execute function acad_ticket_before();

-- Log every ticket change, keep a task for the CS owner, close it when the ticket closes.
create or replace function acad_ticket_after() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into acad_ticket_events (ticket_id, kind, new_value) values (new.id, 'created', new.status);
  else
    if new.status is distinct from old.status then
      insert into acad_ticket_events (ticket_id, kind, old_value, new_value) values (new.id, 'status', old.status, new.status); end if;
    if new.assignee_id is distinct from old.assignee_id then
      insert into acad_ticket_events (ticket_id, kind, old_value, new_value) values (new.id, 'assignee', old.assignee_id::text, new.assignee_id::text); end if;
    if new.priority is distinct from old.priority then
      insert into acad_ticket_events (ticket_id, kind, old_value, new_value) values (new.id, 'priority', old.priority, new.priority); end if;
  end if;

  if new.status = 'closed' then
    update acad_tasks set status = 'done', completed_at = coalesce(completed_at, now())
     where dedupe_key = 'ticket:' || new.id and status <> 'done';
  else
    perform acad_event_task('cs.ticket', 'ticket:' || new.id, new.assignee_id, new.sla_due_at,
                            new.number || ' ' || new.title, new.enrollment_id, new.week_id, new.call_id, new.id);
  end if;
  return null;
end $$;
drop trigger if exists after_save on acad_tickets;
create trigger after_save after insert or update on acad_tickets for each row execute function acad_ticket_after();

-- One click from a call to a ticket: filled from the call and the blocker's routing in the question options.
create or replace function acad_ticket_from_call(p_call uuid, p_blocker text) returns uuid
language plpgsql security definer set search_path = public as $$
declare c acad_followup_calls; route jsonb; label text; tid uuid; e acad_enrollments;
begin
  if not acad_is_staff() then raise exception 'Not allowed'; end if;
  select * into c from acad_followup_calls where id = p_call;
  if not found then raise exception 'Call not found'; end if;
  select * into e from acad_enrollments where id = c.enrollment_id;
  select o->'ticket', o->>'label_ar' into route, label
  from acad_followup_questions q, jsonb_array_elements(q.options) o
  where q.set_id = c.question_set_id and q.code = 'blockers' and o->>'value' = p_blocker;
  if route is null then raise exception 'No ticket routing for blocker %', p_blocker; end if;

  select id into tid from acad_tickets where call_id = p_call and title = label;   -- one ticket per blocker per call
  if tid is not null then return tid; end if;
  insert into acad_tickets (student_id, enrollment_id, cohort_id, week_id, call_id, type, channel, received_by, assignee_id,
                            resolver_team, title, description)
  values (e.student_id, e.id, e.cohort_id, c.cohort_week_id, c.id, route->>'type', 'followup_call', c.caller_id, c.caller_id,
          route->>'resolver_team', label, c.note)
  returning id into tid;
  return tid;
end $$;

-- ======================================================================
-- Task generator (scheduled work from the calendar)
-- ======================================================================

create or replace function acad_cohort_primary(p_cohort uuid) returns uuid language sql stable as $$
  select person_id from acad_cohort_owners where cohort_id = p_cohort order by (role = 'primary_owner') desc, sort_order limit 1
$$;

create or replace function acad_person_by_setting(p_key text) returns uuid language sql stable as $$
  select p.id from acad_people p where p.slug = acad_setting('cs') ->> p_key
$$;

-- Creates or updates the scheduled tasks due between p_from and p_to. Idempotent.
-- Open generated tasks in that window that no longer follow from the calendar become 'skipped'.
create or replace function acad_generate_tasks(p_from date default current_date - 7, p_to date default current_date + 14) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
  tz text := coalesce(acad_setting('timezone') #>> '{}', 'Africa/Cairo');
begin
  create temp table if not exists _acad_gen (code text, key text, anchor timestamp, cohort uuid, week uuid, session uuid,
                                             assignee uuid, suffix text) on commit drop;
  truncate _acad_gen;

  -- weekly follow-up calls: every IADB content week, one task per follow-up owner of the round
  insert into _acad_gen
  select 'cs.followup_calls', 'followup:' || w.id || ':' || o.person_id, w.week_start::timestamp, c.id, w.id, null, o.person_id,
         c.name || ' · ' || coalesce(u.schedule_title, 'week ' || w.seq)
  from acad_cohort_weeks w join acad_cohorts c on c.id = w.cohort_id join acad_programs p on p.id = c.program_id
  join acad_cohort_owners o on o.cohort_id = c.id
  left join acad_program_units u on u.id = w.unit_id
  where p.code = 'iadb' and w.kind = 'content';

  -- per Zoom: link & reminder, recording check
  insert into _acad_gen
  select t.code, t.code || ':' || s.id, (s.starts_at at time zone tz), s.cohort_id, s.week_id, s.id,
         case when s.cohort_id is not null then acad_cohort_primary(s.cohort_id)
              when s.type = 'psp' then acad_person_by_setting('psp_owner')
              else acad_person_by_setting('aim_owner') end,
         coalesce(c.name, s.label, s.type) || ' · ' || s.type
  from acad_sessions s left join acad_cohorts c on c.id = s.cohort_id
  cross join (values ('cs.zoom_reminder'), ('cs.recording_check')) t(code)
  where s.status not in ('cancelled','moved');

  -- open next week's content (IADB): on the week before each content week
  insert into _acad_gen
  select 'cs.open_content', 'content:' || nw.id, w.week_start::timestamp, c.id, nw.id, null, acad_cohort_primary(c.id),
         c.name || ' · ' || coalesce(u.schedule_title, 'week ' || nw.seq)
  from acad_cohort_weeks w join acad_cohort_weeks nw on nw.cohort_id = w.cohort_id and nw.seq = w.seq + 1
  join acad_cohorts c on c.id = w.cohort_id join acad_programs p on p.id = c.program_id
  left join acad_program_units u on u.id = nw.unit_id
  where p.code = 'iadb' and nw.kind = 'content';

  -- onboard a new round (Foundation week)
  insert into _acad_gen
  select 'cs.onboard_round', 'onboard:' || c.id, w.week_start::timestamp, c.id, w.id, null, acad_cohort_primary(c.id), c.name
  from acad_cohort_weeks w join acad_cohorts c on c.id = w.cohort_id
  where w.kind = 'foundation';

  -- Classroom submissions check: unit weeks with deliverables
  insert into _acad_gen
  select 'cs.classroom_check', 'classroom:' || w.id, w.week_start::timestamp, c.id, w.id, null, acad_cohort_primary(c.id),
         c.name || ' · ' || coalesce(u.schedule_title, '')
  from acad_cohort_weeks w join acad_cohorts c on c.id = w.cohort_id join acad_program_units u on u.id = w.unit_id
  where w.kind = 'content' and cardinality(u.deliverables_en) > 0;

  -- feedback survey & certificate: last week of an IADB round
  insert into _acad_gen
  select 'cs.certificate', 'certificate:' || c.id, w.week_start::timestamp, c.id, w.id, null, acad_cohort_primary(c.id), c.name
  from acad_cohorts c join acad_programs p on p.id = c.program_id
  join lateral (select * from acad_cohort_weeks x where x.cohort_id = c.id order by seq desc limit 1) w on true
  where p.code = 'iadb';

  -- DLC phase change: announce, then start
  insert into _acad_gen
  select t.code, t.code || ':' || w.id, w.week_start::timestamp, c.id, w.id, null, acad_cohort_primary(c.id),
         c.name || ' · ' || coalesce(u.title_en, '')
  from acad_cohort_weeks w join acad_cohorts c on c.id = w.cohort_id
  left join acad_program_units u on u.id = w.unit_id
  cross join (values ('cs.dlc_phase_announce'), ('cs.dlc_phase_start')) t(code)
  where w.kind = 'phase' and w.module_week = 1 and w.seq > 0;

  -- upsert
  insert into acad_tasks as k (template_id, dedupe_key, program_id, cohort_id, week_id, session_id, title_ar, title_en, type, team,
                               assignee_id, due_at, steps, origin)
  select t.id, g.key, c.program_id, g.cohort, g.week, g.session,
         t.title_ar || coalesce(': ' || g.suffix, ''), t.title_en, t.code, t.team, g.assignee,
         case when t.due_time is null then (g.anchor + make_interval(days => t.offset_days)) at time zone tz
              else ((g.anchor::date + t.offset_days) + t.due_time) at time zone tz end,
         (select coalesce(jsonb_agg(jsonb_build_object('label', s, 'done', false)), '[]') from jsonb_array_elements_text(t.steps) s),
         'generated'
  from _acad_gen g join acad_task_templates t on t.code = g.code and t.is_active
  left join acad_cohorts c on c.id = g.cohort
  where (g.anchor::date + t.offset_days) between p_from and p_to
  on conflict (dedupe_key) do update set
    title_ar = excluded.title_ar, week_id = excluded.week_id, session_id = excluded.session_id,
    due_at = case when k.is_due_locked then k.due_at else excluded.due_at end,
    assignee_id = case when k.is_assignee_locked then k.assignee_id else excluded.assignee_id end,
    status = case when k.status = 'skipped' and k.skip_reason = 'no longer in the calendar' then 'todo' else k.status end,
    skip_reason = case when k.status = 'skipped' and k.skip_reason = 'no longer in the calendar' then null else k.skip_reason end
  where k.status in ('todo','in_progress','blocked','skipped');
  get diagnostics n = row_count;

  -- skip open generated tasks in the window that the calendar no longer produces
  update acad_tasks k set status = 'skipped', skip_reason = 'no longer in the calendar'
  where k.origin = 'generated' and k.status in ('todo','blocked')
    and (k.due_at at time zone tz)::date between p_from and p_to
    and not exists (select 1 from _acad_gen g join acad_task_templates t on t.code = g.code and t.is_active
                    where g.key = k.dedupe_key and (g.anchor::date + t.offset_days) between p_from and p_to);
  return n;
end $$;

-- Task history
create or replace function acad_task_log() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status is distinct from old.status then
    insert into acad_task_events (task_id, field, old_value, new_value) values (new.id, 'status', old.status, new.status); end if;
  if new.assignee_id is distinct from old.assignee_id then
    insert into acad_task_events (task_id, field, old_value, new_value) values (new.id, 'assignee', old.assignee_id::text, new.assignee_id::text); end if;
  if new.due_at is distinct from old.due_at then
    insert into acad_task_events (task_id, field, old_value, new_value) values (new.id, 'due_at', old.due_at::text, new.due_at::text); end if;
  return null;
end $$;
drop trigger if exists log on acad_tasks;
create trigger log after update on acad_tasks for each row execute function acad_task_log();

-- A person who moves a due date or reassigns a task locks it against the generator.
-- Generator and event functions run as the table owner (security definer), so their writes don't lock.
create or replace function acad_task_lock_edits() returns trigger language plpgsql as $$
begin
  if current_user in ('authenticated', 'anon') then
    if new.due_at is distinct from old.due_at then new.is_due_locked := true; end if;
    if new.assignee_id is distinct from old.assignee_id then new.is_assignee_locked := true; end if;
  end if;
  if new.status = 'done' and old.status <> 'done' then new.completed_at := coalesce(new.completed_at, now()); end if;
  return new;
end $$;
drop trigger if exists lock_edits on acad_tasks;
create trigger lock_edits before update on acad_tasks for each row execute function acad_task_lock_edits();

-- ======================================================================
-- Access rules
-- ======================================================================
do $$
declare t text; spec text[];
begin
  -- table, read rule, write rule
  foreach spec slice 1 in array array[
    ['acad_students',               'acad_is_staff()', 'acad_is_staff()'],
    ['acad_enrollments',            'acad_is_staff()', 'acad_is_staff()'],
    ['acad_cohort_owners',          'acad_is_staff()', 'acad_can_edit()'],
    ['acad_followup_question_sets', 'acad_is_staff()', 'acad_can_manage_followup()'],
    ['acad_followup_questions',     'acad_is_staff()', 'acad_can_manage_followup()'],
    ['acad_red_rules',              'acad_is_staff()', 'acad_can_manage_followup()'],
    ['acad_message_templates',      'acad_is_staff()', 'acad_can_manage_followup()'],
    ['acad_followup_calls',         'acad_is_staff()', 'acad_is_staff()'],
    ['acad_task_templates',         'acad_is_staff()', 'acad_can_edit()'],
    ['acad_tasks',                  'acad_is_staff()', 'acad_is_staff()'],
    ['acad_tickets',                'acad_is_staff()', 'acad_is_staff()'],
    ['acad_alerts',                 'acad_is_staff()', 'acad_is_staff()'],
    ['acad_task_events',            'acad_is_staff()', 'false'],
    ['acad_ticket_events',          'acad_is_staff()', 'false']]
  loop
    t := spec[1];
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists staff_read on %I', t);
    execute format('drop policy if exists staff_write on %I', t);
    execute format('create policy staff_read on %I for select to authenticated using (%s)', t, spec[2]);
    execute format('create policy staff_write on %I for all to authenticated using (%s) with check (%s)', t, spec[3], spec[3]);
    execute format('grant select, insert, update, delete on %I to authenticated', t);
    execute format('revoke all on %I from anon', t);
  end loop;
end $$;

-- calls are never deleted by CS (history); only follow-up managers can
drop policy if exists staff_write on acad_followup_calls;
drop policy if exists staff_insert on acad_followup_calls;
drop policy if exists staff_update on acad_followup_calls;
drop policy if exists manager_delete on acad_followup_calls;
create policy staff_insert on acad_followup_calls for insert to authenticated with check (acad_is_staff());
create policy staff_update on acad_followup_calls for update to authenticated using (acad_is_staff()) with check (acad_is_staff());
create policy manager_delete on acad_followup_calls for delete to authenticated using (acad_can_manage_followup());
-- tickets are closed, never deleted
drop policy if exists staff_write on acad_tickets;
drop policy if exists staff_insert on acad_tickets;
drop policy if exists staff_update on acad_tickets;
create policy staff_insert on acad_tickets for insert to authenticated with check (acad_is_staff());
create policy staff_update on acad_tickets for update to authenticated using (acad_is_staff()) with check (acad_is_staff());

grant usage on sequence acad_student_uid_seq, acad_ticket_seq, acad_question_set_version_seq to authenticated;
grant select on acad_followup_week_results, acad_enrollment_followup to authenticated;
revoke execute on function acad_generate_tasks(date, date), acad_ticket_from_call(uuid, text),
  acad_clone_question_set(uuid, date), acad_event_task(text, text, uuid, timestamptz, text, uuid, uuid, uuid, uuid, text),
  acad_render_message(text, uuid, uuid) from public, anon;
grant execute on function acad_generate_tasks(date, date), acad_ticket_from_call(uuid, text),
  acad_clone_question_set(uuid, date) to authenticated;
