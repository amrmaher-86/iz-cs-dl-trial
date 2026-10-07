# Database

`migrations/` holds the database changes in order. The same files run on the trial Supabase and later on the CRM Supabase. A file is never edited after it has run anywhere; a change is a new file.

## Order on the trial (Supabase `iz-cs-dl-trial`)

1. `trial/00_access_helpers.sql`: who counts as staff and who may edit (trial: the `public.team` allowlist)
2. `migrations/20261007_001_acad_calendar.sql`: calendar tables, Zoom generator, clash views, student link function, access rules
3. `trial/10_copy_from_docs.sql`: one-time copy of the live schedule from the old `public.docs` table (safe to re-run)
4. `trial/20_realtime.sql`: live updates for the trial pages
5. `trial/01_followup_admin_helper.sql`: who may change follow-up questions and red rules (trial: team role admin, qc or management)
6. `migrations/20261007_002_acad_cs_ops.sql`: students, enrollments, follow-up survey, tasks, tickets, QC alerts
7. `seed/cs_config.sql`: starting questions, red rules, WhatsApp messages, task templates, SLA settings
8. `trial/30_sample_students.sql`: CS people, round followers and 12 SAMPLE students in R45 (not real people)
9. Schedule `select acad_generate_tasks();` daily (pg_cron), or call it when the tasks page opens

## Order on the CRM

1. The CRM's own `acad_is_staff()`, `acad_can_edit()` and `acad_can_manage_followup()` built on its users and roles
2. `migrations/*` in order
3. `seed/*` (starting configuration)
4. The release's data (in `releases/<name>/`), instead of the trial copy and sample students

## How the calendar works

- A round (`acad_cohorts`) has weeks (`acad_cohort_weeks`). Each week says its kind (foundation, content, catch-up, DLC phase), its unit and its people.
- Zooms (`acad_sessions`) are generated from the weeks and the round's days and times, and stored so tasks and recordings can point at them. Changing a week or a round's days regenerates its Zooms automatically. A Zoom edited by hand (`is_manual_override`) is never overwritten.
- `acad_generate_program_sessions(from, to)` builds the program-wide weekly Zooms (PSP, AI Mastery) from `acad_settings`.
- `acad_session_clashes` lists Zooms that overlap and share a person or a Zoom account. `acad_missing_people` lists weeks with nobody assigned.
- Students read their round only through `acad_student_timetable(token)`, with the round's unguessable token. It returns no notes and no Zoom accounts.

## How CS operations work

- **Follow-up calls** (`acad_followup_calls`): one row per attempt, filled by the CS person during the call. Answers are keyed by question code. Saving a call picks the question version for that week, refuses missing required answers, and sets the colour: the worst answer wins, then the active red rules (open complaint, no answer 2 weeks running, wants to stop, rating 2 or less) can force red.
- **Paths:** red creates a 48-hour task for the caller and a QC alert; yellow creates a task holding a ready WhatsApp message for the reason; a second no-answer in the same week creates a no-answer message task. The caller's weekly follow-up task shows progress ("3/4 calls") and closes itself when everyone on their list is reached.
- **Questions and red rules** are edited by QC / management only (`acad_can_manage_followup()`). A question version that calls already used is locked; `acad_clone_question_set()` makes a copy that starts next Sunday, so old calls keep their questions.
- **Tickets** (`acad_tickets`): `acad_ticket_from_call(call, blocker)` opens a ticket in one click, routed by the blocker's settings. Path: new, acknowledged, assigned, resolved, confirmed with the student, closed. A ticket cannot close before it is confirmed. Every ticket keeps a task for its CS owner and a history in `acad_ticket_events`. An open complaint keeps the student red.
- **Scheduled tasks** (`acad_generate_tasks(from, to)`): follow-up calls (Tuesday 20:00, one per CS person on the round), Zoom link & reminder (15:00), recording check (next day 14:00), open next week's content (Thursday 14:00), round onboarding, Classroom check, certificate, DLC phase changes. Re-running changes nothing; a due date or assignee changed by a person is kept; tasks whose source disappeared become skipped.

## Tests

`test/run_local.sh <docs snapshot.sql>` builds everything on a local Postgres (port 5499) with a small Supabase stand-in and runs `test/checks.sql` and `test/checks_cs.sql`.
