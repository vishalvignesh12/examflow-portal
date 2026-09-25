-- ============================================================
-- ExamFlow: Phase 2 — sessions, slots, exams, allocations, audit
-- ============================================================

CREATE TABLE public.exam_sessions (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name           text NOT NULL,
  academic_year  text NOT NULL,
  exam_type      text NOT NULL DEFAULT 'END_SEMESTER',
  start_date     date NOT NULL,
  end_date       date NOT NULL,
  status         text NOT NULL DEFAULT 'DRAFT',
  published_at   timestamptz,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT exam_sessions_unique UNIQUE (name, academic_year),
  CONSTRAINT exam_sessions_dates_chk CHECK (end_date >= start_date),
  CONSTRAINT exam_sessions_type_chk CHECK (exam_type IN ('INTERNAL','END_SEMESTER','ARREAR','SUPPLEMENTARY')),
  CONSTRAINT exam_sessions_status_chk CHECK (status IN ('DRAFT','PUBLISHED','ARCHIVED'))
);

CREATE TABLE public.time_slots (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id  uuid NOT NULL REFERENCES public.exam_sessions(id) ON DELETE CASCADE,
  slot_date   date NOT NULL,
  start_time  time NOT NULL,
  end_time    time NOT NULL,
  label       text NOT NULL DEFAULT 'FN',
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT time_slots_unique UNIQUE (session_id, slot_date, start_time),
  CONSTRAINT time_slots_time_chk CHECK (end_time > start_time),
  CONSTRAINT time_slots_label_chk CHECK (label IN ('FN','AN','EVE'))
);

CREATE TABLE public.exams (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id        uuid NOT NULL REFERENCES public.exam_sessions(id) ON DELETE CASCADE,
  course_id         uuid NOT NULL REFERENCES public.courses(id) ON DELETE RESTRICT,
  time_slot_id      uuid REFERENCES public.time_slots(id) ON DELETE SET NULL,
  duration_minutes  integer NOT NULL DEFAULT 180,
  max_marks         integer NOT NULL DEFAULT 100,
  status            text NOT NULL DEFAULT 'DRAFT',
  seats_generated   boolean NOT NULL DEFAULT false,
  published_at      timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT exams_unique UNIQUE (session_id, course_id),
  CONSTRAINT exams_duration_chk CHECK (duration_minutes BETWEEN 30 AND 360),
  CONSTRAINT exams_marks_chk CHECK (max_marks BETWEEN 10 AND 500),
  CONSTRAINT exams_status_chk CHECK (status IN ('DRAFT','SCHEDULED','ALLOCATED','PUBLISHED','CANCELLED'))
);

CREATE TABLE public.exam_registrations (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  exam_id     uuid NOT NULL REFERENCES public.exams(id) ON DELETE CASCADE,
  student_id  uuid NOT NULL REFERENCES public.students(id) ON DELETE CASCADE,
  status      text NOT NULL DEFAULT 'ELIGIBLE',
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT exam_registrations_unique UNIQUE (exam_id, student_id),
  CONSTRAINT exam_registrations_status_chk CHECK (status IN ('ELIGIBLE','WITHHELD','ABSENT','CANCELLED'))
);

CREATE TABLE public.exam_room_allocations (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  exam_id         uuid NOT NULL REFERENCES public.exams(id) ON DELETE CASCADE,
  room_id         uuid NOT NULL REFERENCES public.rooms(id) ON DELETE RESTRICT,
  allocated_count integer NOT NULL DEFAULT 0,
  created_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT era_unique UNIQUE (exam_id, room_id),
  CONSTRAINT era_count_chk CHECK (allocated_count >= 0)
);

CREATE TABLE public.student_hall_allocations (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  exam_id              uuid NOT NULL REFERENCES public.exams(id) ON DELETE CASCADE,
  student_id           uuid NOT NULL REFERENCES public.students(id) ON DELETE CASCADE,
  exam_registration_id uuid NOT NULL REFERENCES public.exam_registrations(id) ON DELETE CASCADE,
  room_id              uuid NOT NULL REFERENCES public.rooms(id) ON DELETE RESTRICT,
  seat_number          integer,
  created_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT sha_registration_unique UNIQUE (exam_registration_id),
  CONSTRAINT sha_student_exam_unique UNIQUE (exam_id, student_id),
  CONSTRAINT sha_seat_unique UNIQUE (exam_id, room_id, seat_number),
  CONSTRAINT sha_seat_chk CHECK (seat_number IS NULL OR seat_number > 0)
);

CREATE TABLE public.invigilator_assignments (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  exam_id     uuid NOT NULL REFERENCES public.exams(id) ON DELETE CASCADE,
  room_id     uuid NOT NULL REFERENCES public.rooms(id) ON DELETE RESTRICT,
  faculty_id  uuid NOT NULL REFERENCES public.faculty(id) ON DELETE CASCADE,
  duty_role   text NOT NULL DEFAULT 'INVIGILATOR',
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ia_unique UNIQUE (exam_id, room_id, faculty_id),
  CONSTRAINT ia_role_chk CHECK (duty_role IN ('INVIGILATOR','RELIEVER','SQUAD'))
);

CREATE TABLE public.audit_logs (
  id          bigserial PRIMARY KEY,
  actor_id    uuid,
  action      text NOT NULL,
  entity_type text NOT NULL,
  entity_id   text,
  details     jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at  timestamptz NOT NULL DEFAULT now()
);

-- ---------- grants / RLS ----------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['exam_sessions','time_slots','exams','exam_registrations',
                           'exam_room_allocations','student_hall_allocations','invigilator_assignments']
  LOOP
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON public.%I TO authenticated', t);
    EXECUTE format('GRANT ALL ON public.%I TO service_role', t);
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('CREATE POLICY "admin insert" ON public.%I FOR INSERT TO authenticated WITH CHECK (public.is_admin())', t);
    EXECUTE format('CREATE POLICY "admin update" ON public.%I FOR UPDATE TO authenticated USING (public.is_admin())', t);
    EXECUTE format('CREATE POLICY "admin delete" ON public.%I FOR DELETE TO authenticated USING (public.is_admin())', t);
  END LOOP;
END $$;

GRANT SELECT ON public.audit_logs TO authenticated;
GRANT ALL ON public.audit_logs TO service_role;
ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "admin reads audit" ON public.audit_logs FOR SELECT TO authenticated USING (public.is_admin());

-- helper: is the caller the given student?
CREATE OR REPLACE FUNCTION public.is_self_student(_student_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.students s WHERE s.id = _student_id AND s.user_id = auth.uid());
$$;

CREATE OR REPLACE FUNCTION public.is_self_faculty(_faculty_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.faculty f WHERE f.id = _faculty_id AND f.user_id = auth.uid());
$$;

-- read policies (least privilege per role)
CREATE POLICY "sessions readable" ON public.exam_sessions FOR SELECT TO authenticated
  USING (public.is_admin() OR status = 'PUBLISHED');
CREATE POLICY "slots readable" ON public.time_slots FOR SELECT TO authenticated USING (true);

CREATE POLICY "exams readable" ON public.exams FOR SELECT TO authenticated
  USING (public.is_admin() OR status = 'PUBLISHED');

CREATE POLICY "exam registrations readable" ON public.exam_registrations FOR SELECT TO authenticated
  USING (
    public.is_admin()
    OR public.is_self_student(student_id)
    OR EXISTS (SELECT 1 FROM public.invigilator_assignments ia
               JOIN public.faculty f ON f.id = ia.faculty_id
               WHERE ia.exam_id = exam_registrations.exam_id AND f.user_id = auth.uid())
  );

CREATE POLICY "room allocations readable" ON public.exam_room_allocations FOR SELECT TO authenticated
  USING (
    public.is_admin()
    OR EXISTS (SELECT 1 FROM public.exams e WHERE e.id = exam_room_allocations.exam_id AND e.status = 'PUBLISHED')
  );

CREATE POLICY "hall allocations readable" ON public.student_hall_allocations FOR SELECT TO authenticated
  USING (
    public.is_admin()
    OR (public.is_self_student(student_id)
        AND EXISTS (SELECT 1 FROM public.exams e WHERE e.id = student_hall_allocations.exam_id AND e.status = 'PUBLISHED'))
    OR EXISTS (SELECT 1 FROM public.invigilator_assignments ia
               JOIN public.faculty f ON f.id = ia.faculty_id
               WHERE ia.exam_id = student_hall_allocations.exam_id
                 AND ia.room_id = student_hall_allocations.room_id
                 AND f.user_id = auth.uid())
  );

CREATE POLICY "invigilator assignments readable" ON public.invigilator_assignments FOR SELECT TO authenticated
  USING (public.is_admin() OR public.is_self_faculty(faculty_id));

-- updated_at triggers
CREATE TRIGGER trg_exam_sessions_updated_at BEFORE UPDATE ON public.exam_sessions
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_exams_updated_at BEFORE UPDATE ON public.exams
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- indexes
CREATE INDEX idx_time_slots_session_date ON public.time_slots(session_id, slot_date);
CREATE INDEX idx_exams_session ON public.exams(session_id);
CREATE INDEX idx_exams_slot ON public.exams(time_slot_id);
CREATE INDEX idx_exams_course ON public.exams(course_id);
CREATE INDEX idx_exams_status ON public.exams(status);
CREATE INDEX idx_exam_reg_exam ON public.exam_registrations(exam_id);
CREATE INDEX idx_exam_reg_student ON public.exam_registrations(student_id);
CREATE INDEX idx_era_exam ON public.exam_room_allocations(exam_id);
CREATE INDEX idx_era_room ON public.exam_room_allocations(room_id);
CREATE INDEX idx_sha_exam_room ON public.student_hall_allocations(exam_id, room_id);
CREATE INDEX idx_sha_student ON public.student_hall_allocations(student_id);
CREATE INDEX idx_ia_exam ON public.invigilator_assignments(exam_id);
CREATE INDEX idx_ia_faculty ON public.invigilator_assignments(faculty_id);
CREATE INDEX idx_audit_created ON public.audit_logs(created_at DESC);
CREATE INDEX idx_audit_entity ON public.audit_logs(entity_type, entity_id);
