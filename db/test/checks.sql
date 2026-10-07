-- Checks for 001_acad_calendar + the trial copy. Every block raises an error if a rule breaks.
\set ON_ERROR_STOP 1

-- 1. the copy brought everything over
do $$ begin
  assert (select count(*) from acad_people) = 13, 'people';
  assert (select count(*) from acad_cohorts) = 11, 'cohorts';
  assert (select count(*) from acad_cohort_weeks) = 164, 'weeks';
  assert (select count(*) from acad_cohort_weeks where kind = 'phase' and unit_id is null) = 0, 'every DLC week has its module';
  assert (select count(*) from acad_cohort_weeks w join acad_cohorts c on c.id = w.cohort_id
          where c.code like 'iadb%' and w.kind = 'content' and w.unit_id is null) = 0, 'every IADB content week has its unit';
end $$;

-- 2. R45 week 1: Recap Sunday, Q&A Tuesday, AI Thursday, all 19:00 Cairo, right people
do $$ declare r record; begin
  for r in select s.type, to_char(s.starts_at at time zone 'Africa/Cairo', 'Dy YYYY-MM-DD HH24:MI') t, p.slug
           from acad_sessions s join acad_cohort_weeks w on w.id = s.week_id join acad_cohorts c on c.id = w.cohort_id
           left join acad_people p on p.id = s.host_id
           where c.code = 'iadb-2026-10' and w.seq = 1 loop
    assert (r.type, r.t, r.slug) in (('recap','Sun 2026-10-11 19:00','mayar'), ('qa','Tue 2026-10-13 19:00','mayar'),
                                     ('ai','Thu 2026-10-15 19:00','gazia')), format('R45 week 1: %s', r);
  end loop;
  assert (select count(*) from acad_sessions s join acad_cohort_weeks w on w.id = s.week_id
          join acad_cohorts c on c.id = w.cohort_id where c.code = 'iadb-2026-10' and w.seq = 1) = 3, 'R45 week 1 has 3 Zooms';
end $$;

-- 3. Foundation = onboarding only; catch-up = AI only; R45 has 1 + 12*3 + 2*1 = 39 Zooms
do $$ begin
  assert (select array_agg(type) from acad_sessions s join acad_cohort_weeks w on w.id = s.week_id
          join acad_cohorts c on c.id = w.cohort_id where c.code = 'iadb-2026-10' and w.seq = 0) = '{onboarding}', 'foundation';
  assert (select array_agg(type) from acad_sessions s join acad_cohort_weeks w on w.id = s.week_id
          join acad_cohorts c on c.id = w.cohort_id where c.code = 'iadb-2026-10' and w.seq = 5) = '{ai}', 'catch-up';
  assert (select count(*) from acad_sessions s join acad_cohorts c on c.id = s.cohort_id where c.code = 'iadb-2026-10') = 39, 'R45 total';
end $$;

-- 4. Rounds without days (R41, R46, R47) and DLC rounds without Zoom days get no Zooms yet
do $$ begin
  assert (select count(*) from acad_sessions s join acad_cohorts c on c.id = s.cohort_id
          where c.code in ('iadb-r41','iadb-r46','iadb-r47') or c.code like 'dlc%') = 0, 'no days, no Zooms';
  assert (select count(*) from acad_sessions where type = 'psp') > 0, 'PSP generated';
  assert (select count(*) from acad_sessions where type in ('workshop','aim_qa')) > 0, 'AI Mastery generated';
end $$;

-- 5. Running the generator again changes nothing
do $$ declare before int; begin
  before := (select count(*) from acad_sessions);
  perform acad_generate_sessions(id) from acad_cohorts;
  perform acad_generate_program_sessions('2026-05-03', '2027-03-13');
  assert (select count(*) from acad_sessions) = before, 'idempotent';
end $$;

-- 6. Push a week back: its Zooms move with it
do $$ declare wid uuid; begin
  select w.id into wid from acad_cohort_weeks w join acad_cohorts c on c.id = w.cohort_id where c.code = 'iadb-2026-10' and w.seq = 14;
  update acad_cohort_weeks set week_start = week_start + 7 where id = wid;
  assert (select min(starts_at at time zone 'Africa/Cairo')::date from acad_sessions where week_id = wid) = '2027-01-17', 'moved';
  update acad_cohort_weeks set week_start = week_start - 7 where id = wid;
end $$;

-- 7. A hand-edited Zoom survives regeneration; turning a content week into catch-up drops Recap and Q&A
do $$ declare wid uuid; sid uuid; begin
  select w.id into wid from acad_cohort_weeks w join acad_cohorts c on c.id = w.cohort_id where c.code = 'iadb-2026-10' and w.seq = 2;
  select id into sid from acad_sessions where week_id = wid and type = 'ai';
  update acad_sessions set is_manual_override = true, starts_at = starts_at + interval '1 hour' where id = sid;
  update acad_cohorts set session_pattern = jsonb_set(session_pattern, '{ai,time}', '"20:00"') where code = 'iadb-2026-10';
  assert (select to_char(starts_at at time zone 'Africa/Cairo', 'HH24:MI') from acad_sessions where id = sid) = '20:00', 'override kept (19:00 + 1h)';
  update acad_cohort_weeks set kind = 'catch_up' where id = wid;
  assert (select array_agg(type order by type) from acad_sessions where week_id = wid) = '{ai}', 'catch-up drops recap/qa';
  update acad_cohort_weeks set kind = 'content' where id = wid;
  update acad_cohorts set session_pattern = jsonb_set(session_pattern, '{ai,time}', '"19:00"') where code = 'iadb-2026-10';
  update acad_sessions set is_manual_override = false where id = sid;
  perform acad_generate_sessions(cohort_id) from acad_cohort_weeks where id = wid;
end $$;

-- 8. Clash: same person, two rounds, same evening
do $$ declare a uuid; b uuid; before int; begin
  before := (select count(*) from acad_session_clashes);
  select s.id into a from acad_sessions s join acad_cohorts c on c.id = s.cohort_id where c.code = 'iadb-2026-10' and s.type = 'recap' order by starts_at limit 1;
  select s.id into b from acad_sessions s join acad_cohorts c on c.id = s.cohort_id where c.code = 'iadb-r44' order by starts_at desc limit 1;
  update acad_sessions set is_manual_override = true, starts_at = (select starts_at from acad_sessions where id = a),
         host_id = (select host_id from acad_sessions where id = a) where id = b;
  assert (select count(*) from acad_session_clashes) = before + 1, 'clash found';
  delete from acad_sessions where id = b;
  perform acad_generate_sessions(id) from acad_cohorts where code = 'iadb-r44';
end $$;

-- 9. Access: anon reads nothing; a signed-in stranger reads nothing; a team member reads all
insert into auth.users values ('00000000-0000-0000-0000-000000000001', 'amr@example.com', now()),
                              ('00000000-0000-0000-0000-000000000002', 'stranger@example.com', now());
insert into public.team values ('amr@example.com', 'Amr', 'admin');

select student_timetable_token as tok from acad_cohorts where code = 'iadb-2026-10' \gset
set role anon;
set test.tok = :'tok';
do $$ begin
  begin perform 1 from acad_cohorts; raise exception 'anon could read'; exception when insufficient_privilege then null; end;
end $$;
-- the student link works with the right token only, and carries no notes or Zoom account
do $$ declare tok text; j jsonb; begin
  tok := current_setting('test.tok');
  j := acad_student_timetable(tok);
  assert j #>> '{cohort,name}' = 'R45', 'student link works';
  assert jsonb_array_length(j->'weeks') = 15, 'student link has 15 weeks';
  assert j::text not like '%note%' and j::text not like '%zoom_account%' and j::text not like '%AI host to confirm%', 'no internal fields';
  assert acad_student_timetable('wrong') is null, 'wrong token';
end $$;
reset role;

set role authenticated;
set request.uid = '00000000-0000-0000-0000-000000000002';
do $$ begin
  assert (select count(*) from acad_cohorts) = 0, 'stranger sees nothing';
  update acad_cohort_weeks set note = 'x';
  assert (select count(*) from acad_cohort_weeks where note = 'x') = 0, 'stranger cannot write';
end $$;
set request.uid = '00000000-0000-0000-0000-000000000001';
do $$ begin
  assert (select count(*) from acad_cohorts) = 11, 'team member sees all';
  update acad_cohort_weeks set note = 'checked' where seq = 0 and cohort_id = (select id from acad_cohorts where code = 'iadb-2026-10');
  assert (select count(*) from acad_cohort_weeks where note = 'checked') = 1, 'team member can write';
end $$;
reset role;

select 'all checks passed' as result,
  (select count(*) from acad_sessions) as sessions,
  (select count(*) from acad_session_clashes) as clashes_in_live_data,
  (select count(*) from acad_missing_people) as weeks_missing_people;
