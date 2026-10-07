# Interior Zone Academy: CS & DL trial

نسخة التجربة لنظام خدمة العملاء (CS) والتصميم والتعلم (DL)، وقناة التسليم لـ CRM الشركة.
Trial version of the CS & DL system, and the handoff channel to the company CRM.

## Layout

| Folder | What it holds |
| --- | --- |
| `trial-app/` | Source of the trial site (Vercel + Supabase project `iz-cs-dl-trial`) |
| `db/migrations/` | Database changes in order (tables + access rules). The same files run on the trial and, later, on the CRM |
| `releases/` | One folder per handoff release (e.g. `IADB-1`): release note, frozen spec, seed data, screenshots, acceptance checklist |
| `specs/` | Living specs for each part |

## Rules

- A release folder never changes after it is handed over. Later changes go in a new release with only the difference.
- No real student data in this repo.
