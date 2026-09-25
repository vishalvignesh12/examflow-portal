-- ============================================================
-- ExamFlow: Phase 5 — deterministic demo data
-- ============================================================

INSERT INTO public.departments (code, name) VALUES
  ('CSE', 'Computer Science and Engineering'),
  ('ECE', 'Electronics and Communication Engineering'),
  ('MEC', 'Mechanical Engineering'),
  ('CIV', 'Civil Engineering'),
  ('ITE', 'Information Technology');

INSERT INTO public.buildings (code, name, floors) VALUES
  ('MB', 'Main Academic Block', 4),
  ('TB', 'Technology Block', 3),
  ('AB', 'Annexe Block', 3);

-- 18 rooms
INSERT INTO public.rooms (building_id, room_number, floor, capacity, exam_capacity, room_type)
SELECT b.id,
       b.code || '-' || (100 * f + n),
       f,
       CASE WHEN n = 1 THEN 90 ELSE 60 END,
       CASE WHEN n = 1 THEN 60 ELSE 30 END,
       CASE WHEN n = 1 THEN 'HALL' ELSE 'CLASSROOM' END
FROM public.buildings b
CROSS JOIN generate_series(1, 2) f
CROSS JOIN generate_series(1, 3) n;

-- 25 faculty
INSERT INTO public.faculty (staff_code, full_name, email, phone, designation, department_id, max_duties)
SELECT 'FAC' || lpad(g::text, 3, '0'),
       (ARRAY['Anand','Bhavna','Chandran','Divya','Elango','Farida','Ganesh','Harini','Iqbal','Jaya',
              'Karthik','Lalitha','Mahesh','Nandini','Omkar','Padma','Quadir','Rajesh','Sarika','Tarun',
              'Usha','Vikram','Waheeda','Xavier','Yamini'])[g] || ' ' ||
       (ARRAY['Kumar','Rao','Iyer','Nair','Menon'])[1 + (g % 5)],
       'fac' || lpad(g::text, 3, '0') || '@univ.edu',
       '98' || lpad((10000000 + g * 137)::text, 8, '0'),
       (ARRAY['Professor','Associate Professor','Assistant Professor'])[1 + (g % 3)],
       d.id,
       CASE WHEN g % 5 = 0 THEN 4 ELSE 8 END
FROM generate_series(1, 25) g
JOIN (SELECT id, row_number() OVER (ORDER BY code) rn FROM public.departments) d
  ON d.rn = 1 + ((g - 1) % 5);

-- 35 courses (7 per department, semesters 1..7)
INSERT INTO public.courses (code, title, department_id, semester, credits, course_type)
SELECT d.code || lpad((100 + s)::text, 3, '0'),
       d.code || ' Core Subject ' || s,
       d.id, s,
       CASE WHEN s % 3 = 0 THEN 4 ELSE 3 END,
       CASE WHEN s = 7 THEN 'ELECTIVE' ELSE 'CORE' END
FROM (SELECT id, code, row_number() OVER (ORDER BY code) rn FROM public.departments) d
CROSS JOIN generate_series(1, 7) s;

-- 120 students (24 per department)
INSERT INTO public.students (register_number, full_name, email, phone, department_id, semester, program, batch_year)
SELECT '21' || d.code || lpad(n::text, 3, '0'),
       (ARRAY['Aarav','Bhuvan','Chitra','Deepak','Esha','Farhan','Gauri','Hemant','Ishita','Jatin',
              'Kavya','Lokesh','Meera','Nikhil','Ojas','Pooja','Rahul','Sneha','Tanvi','Uday',
              'Varun','Yash','Zoya','Akhil'])[n] || ' ' ||
       (ARRAY['Sharma','Verma','Reddy','Pillai','Ghosh','Desai'])[1 + (n % 6)],
       lower('21' || d.code || lpad(n::text, 3, '0')) || '@univ.edu',
       '97' || lpad((20000000 + n * 971 + d.rn * 13)::text, 8, '0'),
       d.id, 5, 'B.E.', 2021
FROM (SELECT id, code, row_number() OVER (ORDER BY code) rn FROM public.departments) d
CROSS JOIN generate_series(1, 24) n;

-- course registrations: every student takes all 7 subjects of their department
INSERT INTO public.student_course_registrations (student_id, course_id, academic_year, status)
SELECT s.id, c.id, '2025-2026',
       CASE WHEN c.semester = 7 THEN 'ARREAR' ELSE 'REGISTERED' END
FROM public.students s
JOIN public.courses c ON c.department_id = s.department_id;

-- two exam sessions
INSERT INTO public.exam_sessions (name, academic_year, exam_type, start_date, end_date, status) VALUES
  ('End Semester Examinations', '2025-2026', 'END_SEMESTER', '2026-04-20', '2026-04-30', 'DRAFT'),
  ('Arrear Examinations', '2025-2026', 'ARREAR', '2026-06-08', '2026-06-12', 'DRAFT');

-- 12 slots for the main session, 4 for the arrear session
INSERT INTO public.time_slots (session_id, slot_date, start_time, end_time, label)
SELECT es.id,
       es.start_date + (dayoff || ' days')::interval,
       CASE WHEN lbl = 'FN' THEN '09:30'::time ELSE '14:00'::time END,
       CASE WHEN lbl = 'FN' THEN '12:30'::time ELSE '17:00'::time END,
       lbl
FROM public.exam_sessions es
CROSS JOIN generate_series(0, 5) dayoff
CROSS JOIN (VALUES ('FN'), ('AN')) v(lbl)
WHERE es.exam_type = 'END_SEMESTER';

INSERT INTO public.time_slots (session_id, slot_date, start_time, end_time, label)
SELECT es.id,
       es.start_date + (dayoff || ' days')::interval,
       '10:00'::time, '13:00'::time, 'FN'
FROM public.exam_sessions es
CROSS JOIN generate_series(0, 3) dayoff
WHERE es.exam_type = 'ARREAR';

-- 20 scheduled exams: semesters 1..4 of each department, one slot per semester
WITH sess AS (SELECT id FROM public.exam_sessions WHERE exam_type = 'END_SEMESTER'),
slots AS (
  SELECT ts.id, row_number() OVER (ORDER BY ts.slot_date, ts.start_time) AS sn
  FROM public.time_slots ts JOIN sess ON sess.id = ts.session_id
)
INSERT INTO public.exams (session_id, course_id, time_slot_id, duration_minutes, max_marks, status)
SELECT (SELECT id FROM sess), c.id, slots.id, 180, 100, 'SCHEDULED'
FROM public.courses c
JOIN slots ON slots.sn = c.semester
WHERE c.semester BETWEEN 1 AND 4;

-- INTENTIONAL CONFLICT A: a 5th-semester CSE exam placed in slot 1,
-- which already holds the 1st-semester CSE exam -> student clash
WITH sess AS (SELECT id FROM public.exam_sessions WHERE exam_type = 'END_SEMESTER'),
slot1 AS (
  SELECT ts.id FROM public.time_slots ts JOIN sess ON sess.id = ts.session_id
  ORDER BY ts.slot_date, ts.start_time LIMIT 1
)
INSERT INTO public.exams (session_id, course_id, time_slot_id, status)
SELECT (SELECT id FROM sess), c.id, (SELECT id FROM slot1), 'SCHEDULED'
FROM public.courses c JOIN public.departments d ON d.id = c.department_id
WHERE d.code = 'CSE' AND c.semester = 5;

-- INTENTIONAL CONFLICT B: an exam with no time slot -> unscheduled
WITH sess AS (SELECT id FROM public.exam_sessions WHERE exam_type = 'END_SEMESTER')
INSERT INTO public.exams (session_id, course_id, time_slot_id, status)
SELECT (SELECT id FROM sess), c.id, NULL, 'DRAFT'
FROM public.courses c JOIN public.departments d ON d.id = c.department_id
WHERE d.code = 'ECE' AND c.semester = 6;

-- exam registrations generated from course registrations
INSERT INTO public.exam_registrations (exam_id, student_id, status)
SELECT e.id, scr.student_id, 'ELIGIBLE'
FROM public.exams e
JOIN public.student_course_registrations scr ON scr.course_id = e.course_id
WHERE scr.status IN ('REGISTERED', 'ARREAR')
ON CONFLICT (exam_id, student_id) DO NOTHING;

-- INTENTIONAL CONFLICT C: one small room assigned to a large exam -> capacity shortfall
WITH target AS (
  SELECT e.id FROM public.exams e JOIN public.courses c ON c.id = e.course_id
  JOIN public.departments d ON d.id = c.department_id
  WHERE d.code = 'MEC' AND c.semester = 2 LIMIT 1
),
small_room AS (
  SELECT id FROM public.rooms WHERE exam_capacity = 30 ORDER BY room_number LIMIT 1
)
INSERT INTO public.exam_room_allocations (exam_id, room_id)
SELECT (SELECT id FROM target), (SELECT id FROM small_room);

-- INTENTIONAL CONFLICT D: the same room assigned to two exams in the same slot
WITH slot2 AS (
  SELECT ts.id FROM public.time_slots ts
  JOIN public.exam_sessions es ON es.id = ts.session_id AND es.exam_type = 'END_SEMESTER'
  ORDER BY ts.slot_date, ts.start_time OFFSET 1 LIMIT 1
),
pair AS (
  SELECT e.id, row_number() OVER (ORDER BY e.id) rn
  FROM public.exams e WHERE e.time_slot_id = (SELECT id FROM slot2)
),
shared_room AS (
  SELECT id FROM public.rooms WHERE exam_capacity = 60 ORDER BY room_number LIMIT 1
)
INSERT INTO public.exam_room_allocations (exam_id, room_id)
SELECT p.id, (SELECT id FROM shared_room) FROM pair p WHERE p.rn <= 2;
