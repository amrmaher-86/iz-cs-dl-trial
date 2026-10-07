set client_min_messages = warning;
-- LOCAL TESTS ONLY: the bits of Supabase the migration expects, so it can run on plain Postgres.
do $$ begin create role anon nologin; exception when duplicate_object then null; end $$;
do $$ begin create role authenticated nologin; exception when duplicate_object then null; end $$;
create schema auth;
create table auth.users (id uuid primary key, email text, email_confirmed_at timestamptz);
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.uid', true), '')::uuid $$;
create table public.team (email text primary key, name text, role text);
create function public.is_team() returns boolean language sql stable security definer set search_path = public, auth as $$
  select exists (select 1 from public.team t join auth.users u on lower(u.email) = lower(t.email)
                 where u.id = auth.uid() and u.email_confirmed_at is not null) $$;
create table public.docs (app text, collection text, id text, data jsonb, updated_at timestamptz, primary key (app, collection, id));
create publication supabase_realtime;
grant usage on schema public, auth to anon, authenticated;
grant execute on function auth.uid() to anon, authenticated;
