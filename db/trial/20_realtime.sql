-- TRIAL ONLY. Live updates for the trial pages.
do $$ declare t text; begin
  foreach t in array array['acad_people','acad_cohorts','acad_cohort_weeks','acad_sessions','acad_settings'] loop
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = t) then
      execute format('alter publication supabase_realtime add table %I', t);
    end if;
  end loop;
end $$;
