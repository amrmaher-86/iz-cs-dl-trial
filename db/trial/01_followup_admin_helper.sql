-- TRIAL ONLY. Run before migrations/20261007_002_acad_cs_ops.sql.
-- Who may change follow-up questions and red rules: QC, top management, mega admins.
-- Trial: team members whose role is admin, qc or management. CRM: back it with the CRM's roles.
create or replace function acad_can_manage_followup() returns boolean
language sql stable security definer set search_path = public, auth as $$
  select exists (select 1 from public.team t join auth.users u on lower(u.email) = lower(t.email)
                 where u.id = auth.uid() and u.email_confirmed_at is not null
                   and t.role in ('admin', 'qc', 'management'))
$$;
