# Database

`migrations/` holds the database changes in order. The same files run on the trial Supabase and later on the CRM Supabase. A file is never edited after it has run anywhere; a change is a new file.

## Order on the trial (Supabase `iz-cs-dl-trial`)

1. `trial/00_access_helpers.sql`: who counts as staff and who may edit (trial: the `public.team` allowlist)
2. `migrations/20261007_001_acad_calendar.sql`: calendar tables, Zoom generator, clash views, student link function, access rules
3. `trial/10_copy_from_docs.sql`: one-time copy of the live schedule from the old `public.docs` table (safe to re-run)
4. `trial/20_realtime.sql`: live updates for the trial pages

## Order on the CRM

1. The CRM's own `acad_is_staff()` and `acad_can_edit()` built on its users and roles (replaces step 1 above)
2. `migrations/*` in order
3. The release's seed data (in `releases/<name>/`), instead of the trial copy

## How the calendar works

- A round (`acad_cohorts`) has weeks (`acad_cohort_weeks`). Each week says its kind (foundation, content, catch-up, DLC phase), its unit and its people.
- Zooms (`acad_sessions`) are generated from the weeks and the round's days and times, and stored so tasks and recordings can point at them. Changing a week or a round's days regenerates its Zooms automatically. A Zoom edited by hand (`is_manual_override`) is never overwritten.
- `acad_generate_program_sessions(from, to)` builds the program-wide weekly Zooms (PSP, AI Mastery) from `acad_settings`.
- `acad_session_clashes` lists Zooms that overlap and share a person or a Zoom account. `acad_missing_people` lists weeks with nobody assigned.
- Students read their round only through `acad_student_timetable(token)`, with the round's unguessable token. It returns no notes and no Zoom accounts.

## Tests

`test/run_local.sh <docs snapshot.sql>` builds everything on a local Postgres (port 5499) with a small Supabase stand-in and runs `test/checks.sql`.
