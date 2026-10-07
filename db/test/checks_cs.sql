-- Checks for 002_acad_cs_ops + seed/cs_config + trial sample data.
\set ON_ERROR_STOP 1

create or replace function pg_temp.enr(n int) returns uuid language sql as $$
  select e.id from acad_enrollments e join acad_students s on s.id = e.student_id where s.full_name_en = (array['Ahmed','Menna','Youssef','Salma','Omar','Nour','Karim','Laila','Mazen','Hana','Khaled','Reem'])[n] || ' Sample' $$;
create or replace function pg_temp.wk(p_seq int) returns uuid language sql as $$
  select w.id from acad_cohort_weeks w join acad_cohorts c on c.id = w.cohort_id where c.code = 'iadb-2026-10' and w.seq = p_seq $$;
create or replace function pg_temp.person(p_slug text) returns uuid language sql as $$ select id from acad_people where slug = p_slug $$;
create or replace function pg_temp.green() returns jsonb language sql as $$
  select '{"outcome":"reached","studied":"all","current_week":"on_track","task_submitted":"yes","blockers":["none"],"rating":5,"intent":"continue"}'::jsonb $$;

-- 1. generator: R45 week 1 (Sun 11 Oct) -> 3 follow-up tasks due Tue 13 Oct 20:00; content for week 2 due Thu 15 Oct 14:00
do $$ declare n1 int; n2 int; begin
  perform acad_generate_tasks('2026-10-04', '2026-10-24');
  assert (select count(*) from acad_tasks where dedupe_key like 'followup:' || pg_temp.wk(1) || ':%') = 3, 'one follow-up task per CS person';
  assert (select to_char(due_at at time zone 'Africa/Cairo', 'Dy DD HH24:MI') from acad_tasks
          where dedupe_key = 'followup:' || pg_temp.wk(1) || ':' || pg_temp.person('heba')) = 'Tue 13 20:00', 'follow-up due Tuesday 20:00';
  assert (select to_char(due_at at time zone 'Africa/Cairo', 'Dy DD HH24:MI') from acad_tasks
          where dedupe_key = 'content:' || pg_temp.wk(2)) = 'Thu 15 14:00', 'content due Thursday 14:00';
  assert (select assignee_id from acad_tasks where dedupe_key = 'content:' || pg_temp.wk(2)) = pg_temp.person('mariam'), 'round tasks go to the first owner';
  assert (select count(*) from acad_tasks t join acad_sessions s on s.id = t.session_id
          where t.type = 'cs.zoom_reminder' and s.cohort_id = (select id from acad_cohorts where code = 'iadb-2026-10')) >= 6, 'Zoom reminders';
  assert exists (select 1 from acad_tasks where type = 'cs.zoom_reminder' and title_ar like '%psp%'), 'PSP reminders exist';
  n1 := (select count(*) from acad_tasks);
  perform acad_generate_tasks('2026-10-04', '2026-10-24');
  n2 := (select count(*) from acad_tasks);
  assert n1 = n2, 'generator is idempotent';
end $$;

-- 2. a full green call
do $$ declare cid uuid; begin
  insert into acad_followup_calls (enrollment_id, cohort_week_id, caller_id, answers)
  values (pg_temp.enr(1), pg_temp.wk(1), pg_temp.person('mariam'), pg_temp.green()) returning id into cid;
  assert (select color from acad_followup_calls where id = cid) = 'green', 'green';
  assert (select is_done from acad_followup_calls where id = cid), 'reached = done';
end $$;

-- 3. a missing required answer is refused
do $$ begin
  begin
    insert into acad_followup_calls (enrollment_id, cohort_week_id, caller_id, answers)
    values (pg_temp.enr(4), pg_temp.wk(1), pg_temp.person('mariam'), '{"outcome":"reached","studied":"all"}');
    raise exception 'should have failed';
  exception when raise_exception then
    if sqlerrm not like 'Missing answer%' then raise; end if;
  end;
end $$;

-- 4. no answer: the rest is skipped; on the 2nd attempt a WhatsApp task appears
do $$ begin
  insert into acad_followup_calls (enrollment_id, cohort_week_id, caller_id, answers)
  values (pg_temp.enr(4), pg_temp.wk(1), pg_temp.person('mariam'), '{"outcome":"no_answer"}');
  assert not exists (select 1 from acad_tasks where dedupe_key = 'no_answer:' || pg_temp.enr(4) || ':' || pg_temp.wk(1)), 'not after 1 attempt';
  insert into acad_followup_calls (enrollment_id, cohort_week_id, caller_id, answers, called_at)
  values (pg_temp.enr(4), pg_temp.wk(1), pg_temp.person('mariam'), '{"outcome":"no_answer"}', now() + interval '3 hours');
  assert (select evidence_text from acad_tasks where dedupe_key = 'no_answer:' || pg_temp.enr(4) || ':' || pg_temp.wk(1)) like '%سلمى تجريبي%', 'no-answer message ready';
  assert (select attempts from acad_followup_week_results where enrollment_id = pg_temp.enr(4) and cohort_week_id = pg_temp.wk(1)) = 2, 'attempts counted';
end $$;

-- 5. red: wants to stop -> 48h task for the caller + QC alert
do $$ declare cid uuid; begin
  insert into acad_followup_calls (enrollment_id, cohort_week_id, caller_id, answers, called_at)
  values (pg_temp.enr(2), pg_temp.wk(1), pg_temp.person('sohaila'), pg_temp.green() || '{"intent":"stop"}', '2026-10-12 10:00+00') returning id into cid;
  assert (select color from acad_followup_calls where id = cid) = 'red', 'red';
  assert (select red_reasons from acad_followup_calls where id = cid) @> '{wants_to_stop}', 'reason recorded';
  assert (select due_at from acad_tasks where dedupe_key = 'at_risk:' || pg_temp.enr(2) || ':' || pg_temp.wk(1)) = '2026-10-14 10:00+00', 'due in 48h';
  assert (select assignee_id from acad_tasks where dedupe_key = 'at_risk:' || pg_temp.enr(2) || ':' || pg_temp.wk(1)) = pg_temp.person('sohaila'), 'to the caller';
  assert exists (select 1 from acad_alerts where audience = 'qc' and call_id = cid), 'QC alerted';
end $$;

-- 6. yellow with a tech blocker -> WhatsApp task with the tech message; 7. one click to a ticket
do $$ declare cid uuid; tid uuid; begin
  insert into acad_followup_calls (enrollment_id, cohort_week_id, caller_id, answers, note)
  values (pg_temp.enr(3), pg_temp.wk(1), pg_temp.person('heba'), pg_temp.green() || '{"blockers":["tech"],"rating":3}', '3ds Max won''t open')
  returning id into cid;
  assert (select color from acad_followup_calls where id = cid) = 'yellow', 'yellow';
  assert (select evidence_text from acad_tasks where dedupe_key = 'yellow:' || pg_temp.enr(3) || ':' || pg_temp.wk(1)) like '%مشكلة البرامج%', 'tech message';
  tid := acad_ticket_from_call(cid, 'tech');
  assert acad_ticket_from_call(cid, 'tech') = tid, 'one ticket per blocker';
  assert (select type = 'technical' and resolver_team = 'Tech support' and assignee_id = pg_temp.person('heba')
          and description = '3ds Max won''t open' from acad_tickets where id = tid), 'ticket filled from the call';
  assert (select number from acad_tickets where id = tid) like 'T-____-0001', 'readable number';
  assert (select status from acad_tasks where dedupe_key = 'ticket:' || tid) = 'todo', 'ticket task for the CS owner';
  begin
    update acad_tickets set status = 'closed' where id = tid;
    raise exception 'closed without confirming';
  exception when check_violation then null; end;
  update acad_tickets set status = 'acknowledged' where id = tid;
  update acad_tickets set status = 'resolved', resolution_ar = 'اتسطب من جديد' where id = tid;
  update acad_tickets set status = 'confirmed' where id = tid;
  update acad_tickets set status = 'closed' where id = tid;
  assert (select status from acad_tasks where dedupe_key = 'ticket:' || tid) = 'done', 'ticket task done on close';
  assert (select count(*) from acad_ticket_events where ticket_id = tid) = 5, 'ticket history';
end $$;

-- 8. an open complaint makes an all-green call red, and keeps the student red until it closes
do $$ declare tid uuid; cid uuid; begin
  insert into acad_tickets (enrollment_id, type, channel, assignee_id, title, priority)
  values (pg_temp.enr(5), 'complaint', 'whatsapp', pg_temp.person('heba'), 'Late recording', 'urgent') returning id into tid;
  assert (select sla_due_at - created_at from acad_tickets where id = tid) = interval '4 hours', 'urgent SLA';
  insert into acad_followup_calls (enrollment_id, cohort_week_id, caller_id, answers)
  values (pg_temp.enr(5), pg_temp.wk(1), pg_temp.person('sohaila'), pg_temp.green()) returning id into cid;
  assert (select color = 'red' and red_reasons = '{open_complaint}' from acad_followup_calls where id = cid), 'complaint -> red';
  assert (select risk from acad_enrollment_followup where enrollment_id = pg_temp.enr(5)) = 'red', 'student red';
  update acad_tickets set status = 'resolved' where id = tid;
  update acad_tickets set status = 'confirmed' where id = tid;
  update acad_tickets set status = 'closed' where id = tid;
  assert (select open_complaint from acad_enrollment_followup where enrollment_id = pg_temp.enr(5)) = false, 'closed';
end $$;

-- 9. no answer two weeks in a row -> red
do $$ declare cid uuid; begin
  insert into acad_followup_calls (enrollment_id, cohort_week_id, caller_id, answers)
  values (pg_temp.enr(4), pg_temp.wk(2), pg_temp.person('mariam'), '{"outcome":"no_answer"}') returning id into cid;
  assert (select red_reasons from acad_followup_calls where id = cid) @> '{no_answer_2_weeks}', 'streak';
  -- only once in the previous week is not a streak
  insert into acad_followup_calls (enrollment_id, cohort_week_id, caller_id, answers)
  values (pg_temp.enr(7), pg_temp.wk(2), pg_temp.person('mariam'), '{"outcome":"no_answer"}') returning id into cid;
  assert (select color from acad_followup_calls where id = cid) = 'yellow', 'no streak';
end $$;

-- 10. Heba's weekly task closes itself when all her students are called (students 3, 6, 9, 12)
do $$ declare k text := 'followup:' || pg_temp.wk(1) || ':' || pg_temp.person('heba'); begin
  insert into acad_followup_calls (enrollment_id, cohort_week_id, caller_id, answers)
  values (pg_temp.enr(6), pg_temp.wk(1), pg_temp.person('heba'), pg_temp.green()),
         (pg_temp.enr(9), pg_temp.wk(1), pg_temp.person('heba'), pg_temp.green());
  assert (select status = 'todo' and evidence_text = '3/4 calls' from acad_tasks where dedupe_key = k), 'progress';
  insert into acad_followup_calls (enrollment_id, cohort_week_id, caller_id, answers)
  values (pg_temp.enr(12), pg_temp.wk(1), pg_temp.person('heba'), pg_temp.green());
  assert (select status from acad_tasks where dedupe_key = k) = 'done', 'all called -> done';
end $$;

-- 11. a used question set is locked
do $$ begin
  begin
    update acad_followup_questions set text_ar = 'x' where code = 'studied';
    raise exception 'edited a used set';
  exception when raise_exception then
    if sqlerrm not like '%already used%' then raise; end if;
  end;
end $$;

-- 12-14 as signed-in users: CS agent (role cs), QC/admin (Amr), stranger
insert into auth.users values ('00000000-0000-0000-0000-000000000003', 'heba@example.com', now());
insert into public.team values ('heba@example.com', 'Heba', 'cs');

set role authenticated;
set request.uid = '00000000-0000-0000-0000-000000000002';   -- stranger
do $$ begin
  assert (select count(*) from acad_students) = 0, 'stranger sees no students';
  assert (select count(*) from acad_followup_calls) = 0, 'stranger sees no calls';
end $$;

set request.uid = '00000000-0000-0000-0000-000000000003';   -- CS agent
do $$ declare tid uuid; begin
  assert (select count(*) from acad_students) = 12, 'CS sees students';
  insert into acad_followup_calls (enrollment_id, cohort_week_id, caller_id, answers)
  values (pg_temp.enr(8), pg_temp.wk(1), pg_temp.person('sohaila'), pg_temp.green());
  update acad_red_rules set is_active = false where code = 'low_rating';
  assert (select is_active from acad_red_rules where code = 'low_rating'), 'CS cannot change red rules';
  begin perform acad_clone_question_set(acad_question_set_for('2026-10-11')); raise exception 'CS cloned';
  exception when raise_exception then if sqlerrm not like 'Only QC%' then raise; end if; end;
  -- moving a due date locks it against the generator
  select id into tid from acad_tasks where dedupe_key = 'content:' || pg_temp.wk(2);
  update acad_tasks set due_at = due_at + interval '1 day' where id = tid;
  assert (select is_due_locked from acad_tasks where id = tid), 'locked';
end $$;
reset role;
do $$ declare d timestamptz; begin
  d := (select due_at from acad_tasks where dedupe_key = 'content:' || pg_temp.wk(2));
  perform acad_generate_tasks('2026-10-04', '2026-10-24');
  assert (select due_at from acad_tasks where dedupe_key = 'content:' || pg_temp.wk(2)) = d, 'generator keeps a moved due date';
end $$;

set role authenticated;
set request.uid = '00000000-0000-0000-0000-000000000001';   -- Amr (admin = QC rights in the trial)
do $$ declare nid uuid; begin
  nid := acad_clone_question_set(acad_question_set_for('2026-10-11'));
  assert (select effective_from > current_date and extract(dow from effective_from) = 0
          from acad_followup_question_sets where id = nid), 'a copy starts next Sunday by default';
  update acad_followup_question_sets set effective_from = '2026-10-18' where id = nid;
  update acad_followup_questions set text_ar = 'ذاكر كام في المية من المحتوى؟' where set_id = nid and code = 'studied';
  update acad_followup_question_sets set published_at = now() where id = nid;
  assert acad_question_set_for('2026-10-11') <> nid, 'old weeks keep the old questions';
  assert acad_question_set_for('2026-10-18') = nid, 'new questions from the next week';
end $$;
reset role;

-- 15. turning week 3 into catch-up skips its open follow-up tasks, and turning it back revives them
do $$ begin
  perform acad_generate_tasks('2026-10-04', '2026-10-31');
  assert (select count(*) from acad_tasks where dedupe_key like 'followup:' || pg_temp.wk(3) || ':%') = 3, 'week 3 tasks exist';
  update acad_cohort_weeks set kind = 'catch_up' where id = pg_temp.wk(3);
  perform acad_generate_tasks('2026-10-04', '2026-10-31');
  assert (select bool_and(status = 'skipped') from acad_tasks where dedupe_key like 'followup:' || pg_temp.wk(3) || ':%'), 'skipped';
  update acad_cohort_weeks set kind = 'content' where id = pg_temp.wk(3);
  perform acad_generate_tasks('2026-10-04', '2026-10-31');
  assert (select bool_and(status = 'todo') from acad_tasks where dedupe_key like 'followup:' || pg_temp.wk(3) || ':%'), 'back';
end $$;

select 'all CS checks passed' as result,
  (select count(*) from acad_tasks) tasks, (select count(*) from acad_followup_calls) calls,
  (select count(*) from acad_tickets) tickets, (select count(*) from acad_alerts) alerts;
