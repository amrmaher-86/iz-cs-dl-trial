-- Starting configuration for CS operations (both trial and CRM). Safe to re-run: it only adds what is missing.
-- Everything here is editable later from the app by QC / management (questions, rules, messages)
-- or by editors (task templates). Source: brainstorm/followup-calls-and-complaints.md and specs/cs-tasks-spec.md.

insert into acad_settings (key, value) values
  ('ticket_sla_hours', '{"normal":48,"important":24,"urgent":4}'),   -- OPEN: placeholders until CS agrees response times
  ('followup_no_answer_attempts', '2'),
  ('cs', '{"psp_owner":null,"aim_owner":"mariam"}')
on conflict (key) do nothing;

-- ---------- follow-up questions, version 1 ----------
do $$
declare sid uuid;
begin
  if exists (select 1 from acad_followup_question_sets) then return; end if;
  insert into acad_followup_question_sets (effective_from, published_at, note)
  values ('2026-01-04', now(), 'First version, agreed with Amr 2026-10-07') returning id into sid;

  insert into acad_followup_questions (set_id, seq, code, text_ar, text_en, kind, options, required) values
  (sid, 1, 'outcome', 'نتيجة المكالمة', 'Call result', 'single', $j$[
    {"value":"reached","label_ar":"رد","color":"green","done":true},
    {"value":"reschedule","label_ar":"طلب ميعاد تاني","color":"yellow","ends_call":true},
    {"value":"no_answer","label_ar":"مردش","color":"yellow","ends_call":true},
    {"value":"wrong_number","label_ar":"رقم غلط","color":"red","ends_call":true}]$j$, true),
  (sid, 2, 'studied', 'ذاكر محتوى الأسبوع؟', 'Studied this week''s content?', 'single', $j$[
    {"value":"all","label_ar":"كله","color":"green"},
    {"value":"part","label_ar":"جزء","color":"yellow"},
    {"value":"none","label_ar":"لأ","color":"red"}]$j$, true),
  (sid, 3, 'current_week', 'هو في أسبوع كام؟', 'Which week is the student on?', 'single', $j$[
    {"value":"on_track","label_ar":"نفس الراوند","color":"green"},
    {"value":"behind_1","label_ar":"متأخر أسبوع","color":"yellow"},
    {"value":"behind_2","label_ar":"متأخر أسبوعين أو أكتر","color":"red"}]$j$, true),
  (sid, 4, 'task_submitted', 'سلّم التاسك؟', 'Submitted the task?', 'single', $j$[
    {"value":"yes","label_ar":"أيوه","color":"green"},
    {"value":"late","label_ar":"متأخر","color":"yellow"},
    {"value":"no","label_ar":"لأ","color":"red"}]$j$, true),
  (sid, 5, 'blockers', 'فيه حاجة واقفة معاه؟', 'Anything blocking?', 'multi', $j$[
    {"value":"none","label_ar":"لأ","color":"green"},
    {"value":"tech","label_ar":"برامج وتقنية","color":"yellow","ticket":{"type":"technical","resolver_team":"Tech support"}},
    {"value":"content","label_ar":"فهم المحتوى","color":"yellow","ticket":{"type":"one_on_one","resolver_team":"D&L"}},
    {"value":"access","label_ar":"حساب وAccess","color":"yellow","ticket":{"type":"access","resolver_team":"CS"}},
    {"value":"time","label_ar":"وقت وظروف","color":"yellow","ticket":{"type":"deferral","resolver_team":"CS"}},
    {"value":"money","label_ar":"فلوس","color":"yellow","ticket":{"type":"payment","resolver_team":"Sales / Finance"}}]$j$, true),
  (sid, 6, 'rating', 'رضاه عن الأسبوع والمدرب', 'Satisfaction with the week and trainer', 'stars', $j$[
    {"min":4,"max":5,"color":"green"},{"min":3,"max":3,"color":"yellow"},{"min":1,"max":2,"color":"red"}]$j$, true),
  (sid, 7, 'intent', 'نيته', 'Intent', 'single', $j$[
    {"value":"continue","label_ar":"مكمل","color":"green"},
    {"value":"hesitant","label_ar":"متردد","color":"yellow"},
    {"value":"stop","label_ar":"بيفكر يوقف أو يأجل","color":"red"}]$j$, true);
end $$;

insert into acad_red_rules (code, label_ar, kind, params) values
  ('open_complaint', 'عنده شكوى مفتوحة', 'open_complaint', '{}'),
  ('no_answer_2_weeks', 'مردش أسبوعين ورا بعض', 'no_answer_streak', '{"weeks":2,"outcomes":["no_answer"]}'),
  ('wants_to_stop', 'بيفكر يوقف أو يأجل', 'answer_in', '{"question":"intent","values":["stop"]}'),
  ('low_rating', 'تقييمه للمدرب 2 أو أقل', 'rating_at_most', '{"question":"rating","max":2}')
on conflict (code) do nothing;

insert into acad_message_templates (code, title_ar, body_ar) values
  ('followup.yellow', 'متابعة عامة', 'أهلاً {{student_name}}، كنا بنطمن عليك في {{cohort}}. لو محتاج أي مساعدة في الأسبوع ده إحنا موجودين.'),
  ('followup.yellow.tech', 'مشكلة برامج', 'أهلاً {{student_name}}، بخصوص مشكلة البرامج: ده لينك خطوات التسطيب، ولو لسه واقفة معاك ابعتلنا سكرين شوت ونتابع معاك.'),
  ('followup.yellow.content', 'فهم المحتوى', 'أهلاً {{student_name}}، لو فيه جزء مش واضح في المحتوى، ابعت سؤالك ونحطه في الـ Q&A الجاية، أو نرتبلك سيشن قصيرة.'),
  ('followup.yellow.access', 'الحساب والدخول', 'أهلاً {{student_name}}، بنراجع حسابك على الموقع دلوقتي وهنبلغك أول ما يتظبط.'),
  ('followup.yellow.time', 'الوقت والظروف', 'أهلاً {{student_name}}، مقدّرين ظروفك. التسجيلات متاحة دايماً، ولو محتاج تأجيل قولنا ونشوف الأنسب ليك.'),
  ('followup.yellow.money', 'الدفع', 'أهلاً {{student_name}}، هنوصلك بفريق المبيعات يتكلموا معاك بخصوص الدفع.'),
  ('followup.no_answer', 'مردش', 'أهلاً {{student_name}}، حاولنا نكلمك عشان نطمن عليك في {{cohort}}. ابعتلنا الوقت المناسب ليك ونكلمك.')
on conflict (code) do nothing;

insert into acad_task_templates (code, title_ar, title_en, trigger_type, offset_days, due_time, due_hours, assignee_rule, steps, evidence_type) values
  ('cs.followup_calls',     'مكالمات المتابعة الأسبوعية', 'Weekly follow-up calls', 'per_enrollment', 2, '20:00', null, 'followup_owner', '[]', 'form'),
  ('cs.zoom_reminder',      'إرسال لينك الزوم والتذكير', 'Send Zoom link & reminder', 'per_session', 0, '15:00', null, 'cohort_primary_owner', '[]', 'none'),
  ('cs.recording_check',    'مراجعة التسجيل على Vimeo والموقع', 'Check recording on Vimeo & website', 'per_session', 1, '14:00', null, 'cohort_primary_owner', '[]', 'link'),
  ('cs.open_content',       'فتح محتوى الأسبوع الجاي على الموقع', 'Open next week''s content', 'cohort_weekly', 4, '14:00', null, 'cohort_primary_owner', '[]', 'none'),
  ('cs.onboard_round',      'أونبوردنج راوند جديد', 'Onboard a new round', 'cohort_lifecycle', -3, '12:00', null, 'cohort_primary_owner',
     '["استلام شيت الكونتاكت من السيلز","إضافة الطلاب لشيت الطلاب","إضافة لجروب الواتساب والكوميونيتي","فتح الـ Access على الموقع","عمل حسابات Autodesk وتسجيلها","إرسال ميعاد ولينك الزوم"]', 'checklist'),
  ('cs.classroom_check',    'مراجعة تسليمات Classroom وتذكير المتأخرين', 'Check Classroom submissions', 'cohort_weekly', 6, '12:00', null, 'cohort_primary_owner', '[]', 'none'),
  ('cs.certificate',        'استبيان التقييم وخطوات الشهادة', 'Feedback survey & certificate', 'cohort_lifecycle', 6, '12:00', null, 'cohort_primary_owner', '[]', 'checklist'),
  ('cs.dlc_phase_announce', 'إعلان المرحلة الجاية (DLC)', 'Announce next DLC phase', 'phase_change', -3, '14:00', null, 'cohort_primary_owner', '[]', 'none'),
  ('cs.dlc_phase_start',    'بداية مرحلة جديدة (DLC)', 'Start DLC phase', 'phase_change', 0, '12:00', null, 'cohort_primary_owner',
     '["تقسيم الطلاب جروبات حسب المدرب","إرسال لينكات وميعاد الزوم والتايملاين والملفات","فتح المرحلة الجديدة على الموقع"]', 'checklist'),
  ('cs.student_at_risk',    'متابعة طالب في خطر', 'Follow up an at-risk student', 'event', 0, null, 48, 'caller', '[]', 'text'),
  ('cs.followup_whatsapp',  'رسالة واتساب للطالب', 'WhatsApp message to student', 'event', 0, null, 24, 'caller', '[]', 'none'),
  ('cs.followup_no_answer', 'الطالب مردش: ابعت رسالة', 'No answer: send WhatsApp', 'event', 0, null, 4, 'caller', '[]', 'none'),
  ('cs.ticket',             'تيكت', 'Ticket', 'event', 0, null, null, 'ticket_assignee', '[]', 'none')
on conflict (code) do nothing;
