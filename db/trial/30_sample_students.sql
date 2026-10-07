-- TRIAL ONLY. CS people, who follows which round, and SAMPLE students (not real people).
insert into acad_people (slug, name, team, roles) values
  ('mariam', 'Mariam', 'CS', '{cs_agent}'),
  ('sohaila', 'Sohaila', 'CS', '{cs_agent}'),
  ('heba', 'Heba', 'CS', '{cs_agent}')
on conflict (slug) do update set team = excluded.team, roles = excluded.roles;

-- round followers as seeded in specs/cs-tasks-spec.md (2026-10-07); first = gets round tasks
insert into acad_cohort_owners (cohort_id, person_id, role, sort_order)
select c.id, p.id, case when x.ord = 1 then 'primary_owner' else 'followup_owner' end, x.ord
from (values ('iadb-r43','mariam',1), ('iadb-r43','sohaila',2), ('iadb-r44','mariam',1),
             ('iadb-2026-10','mariam',1), ('iadb-2026-10','sohaila',2), ('iadb-2026-10','heba',3)) x(cohort, person, ord)
join acad_cohorts c on c.code = x.cohort join acad_people p on p.slug = x.person
on conflict (cohort_id, person_id) do nothing;

-- 12 sample students in R45, split evenly between the three follow-up owners
with names(n, ar, en) as (values
  (1,'أحمد تجريبي','Ahmed Sample'), (2,'منة تجريبي','Menna Sample'), (3,'يوسف تجريبي','Youssef Sample'),
  (4,'سلمى تجريبي','Salma Sample'), (5,'عمر تجريبي','Omar Sample'), (6,'نور تجريبي','Nour Sample'),
  (7,'كريم تجريبي','Karim Sample'), (8,'ليلى تجريبي','Laila Sample'), (9,'مازن تجريبي','Mazen Sample'),
  (10,'هنا تجريبي','Hana Sample'), (11,'خالد تجريبي','Khaled Sample'), (12,'ريم تجريبي','Reem Sample')),
ins as (
  insert into acad_students (full_name_ar, full_name_en, phones, emails, country, timezone, is_sample)
  select ar, en, array['+2010000000' || lpad(n::text, 2, '0')], array['sample' || n || '@example.com'], 'EG', 'Africa/Cairo', true
  from names
  where not exists (select 1 from acad_students where is_sample)
  returning id, full_name_en)
insert into acad_enrollments (student_id, program_id, cohort_id, source, status, activated_at, access_status, autodesk_status, followup_owner_id)
select ins.id, c.program_id, c.id, 'sales_handoff', 'active', now(), 'granted', 'created',
       (select p.id from acad_people p where p.slug = (array['mariam','sohaila','heba'])[1 + (names.n - 1) % 3])
from ins join names on names.en = ins.full_name_en join acad_cohorts c on c.code = 'iadb-2026-10';
