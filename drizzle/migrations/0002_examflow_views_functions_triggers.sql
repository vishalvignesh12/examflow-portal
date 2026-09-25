-- ============================================================
-- ExamFlow: Phase 3 — views, stored procedures, triggers
-- ============================================================

-- ---------------- VIEWS ----------------
CREATE VIEW public.student_exam_timetable
WITH (security_invoker = true) AS
SELECT
  s.id                AS student_id,
  s.register_number,
  s.full_name         AS student_name,
  d.code              AS department_code,
  e.id                AS exam_id,
  c.code              AS course_code,
  c.title             AS course_title,
  ts.slot_date        AS exam_date,
  ts.start_time,
  ts.end_time,
  ts.label            AS session_label,
  e.duration_minutes,
  e.max_marks,
  es.name             AS session_name,
  es.academic_year,
  r.room_number,
  b.name              AS building_name,
  sha.seat_number,
  e.status            AS exam_status
FROM public.exam_registrations er
JOIN public.students s        ON s.id = er.student_id
JOIN public.departments d     ON d.id = s.department_id
JOIN public.exams e           ON e.id = er.exam_id
JOIN public.courses c         ON c.id = e.course_id
JOIN public.exam_sessions es  ON es.id = e.session_id
LEFT JOIN public.time_slots ts ON ts.id = e.time_slot_id
LEFT JOIN public.student_hall_allocations sha ON sha.exam_registration_id = er.id
LEFT JOIN public.rooms r      ON r.id = sha.room_id
LEFT JOIN public.buildings b  ON b.id = r.building_id;

CREATE VIEW public.exam_summary
WITH (security_invoker = true) AS
SELECT
  e.id                AS exam_id,
  c.code              AS course_code,
  c.title             AS course_title,
  d.code              AS department_code,
  es.name             AS session_name,
  es.academic_year,
  ts.slot_date        AS exam_date,
  ts.start_time,
  ts.label            AS session_label,
  e.status,
  e.duration_minutes,
  COUNT(DISTINCT er.id)                                   AS registered_count,
  COUNT(DISTINCT sha.id)                                  AS allocated_count,
  COUNT(DISTINCT er.id) - COUNT(DISTINCT sha.id)          AS unallocated_count,
  COUNT(DISTINCT era.room_id)                             AS room_count,
  COUNT(DISTINCT ia.faculty_id)                           AS invigilator_count
FROM public.exams e
JOIN public.courses c          ON c.id = e.course_id
JOIN public.departments d      ON d.id = c.department_id
JOIN public.exam_sessions es   ON es.id = e.session_id
LEFT JOIN public.time_slots ts ON ts.id = e.time_slot_id
LEFT JOIN public.exam_registrations er ON er.exam_id = e.id
LEFT JOIN public.student_hall_allocations sha ON sha.exam_id = e.id
LEFT JOIN public.exam_room_allocations era ON era.exam_id = e.id
LEFT JOIN public.invigilator_assignments ia ON ia.exam_id = e.id
GROUP BY e.id, c.code, c.title, d.code, es.name, es.academic_year,
         ts.slot_date, ts.start_time, ts.label, e.status, e.duration_minutes;

CREATE VIEW public.room_utilization
WITH (security_invoker = true) AS
SELECT
  r.id            AS room_id,
  b.name          AS building_name,
  b.code          AS building_code,
  r.room_number,
  r.capacity,
  r.exam_capacity,
  COUNT(DISTINCT era.exam_id)                                AS exams_hosted,
  COALESCE(SUM(era.allocated_count), 0)                      AS total_students_seated,
  ROUND(
    CASE WHEN COUNT(DISTINCT era.exam_id) = 0 THEN 0
         ELSE (COALESCE(SUM(era.allocated_count), 0)::numeric
               / (r.exam_capacity * COUNT(DISTINCT era.exam_id))) * 100
    END, 2)                                                  AS utilization_pct
FROM public.rooms r
JOIN public.buildings b ON b.id = r.building_id
LEFT JOIN public.exam_room_allocations era ON era.room_id = r.id
GROUP BY r.id, b.name, b.code, r.room_number, r.capacity, r.exam_capacity;

GRANT SELECT ON public.student_exam_timetable TO authenticated;
GRANT SELECT ON public.exam_summary TO authenticated;
GRANT SELECT ON public.room_utilization TO authenticated;

-- ---------------- AUDIT ----------------
CREATE OR REPLACE FUNCTION public.write_audit_log()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_entity_id text;
  v_details jsonb;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_entity_id := OLD.id::text;
    v_details := jsonb_build_object('old', to_jsonb(OLD));
  ELSIF TG_OP = 'UPDATE' THEN
    v_entity_id := NEW.id::text;
    v_details := jsonb_build_object('old', to_jsonb(OLD), 'new', to_jsonb(NEW));
  ELSE
    v_entity_id := NEW.id::text;
    v_details := jsonb_build_object('new', to_jsonb(NEW));
  END IF;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (auth.uid(), TG_OP, TG_TABLE_NAME, v_entity_id, v_details);

  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END; $$;

CREATE TRIGGER trg_audit_exams
AFTER INSERT OR UPDATE OR DELETE ON public.exams
FOR EACH ROW EXECUTE FUNCTION public.write_audit_log();

CREATE TRIGGER trg_audit_hall_allocations
AFTER INSERT OR UPDATE OR DELETE ON public.student_hall_allocations
FOR EACH ROW EXECUTE FUNCTION public.write_audit_log();

CREATE TRIGGER trg_audit_invigilators
AFTER INSERT OR UPDATE OR DELETE ON public.invigilator_assignments
FOR EACH ROW EXECUTE FUNCTION public.write_audit_log();

CREATE TRIGGER trg_audit_sessions
AFTER INSERT OR UPDATE OR DELETE ON public.exam_sessions
FOR EACH ROW EXECUTE FUNCTION public.write_audit_log();

-- ---------------- TRIGGER: duplicate / conflicting allocation ----------------
CREATE OR REPLACE FUNCTION public.check_allocation_conflict()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
DECLARE
  v_slot uuid;
  v_conflict_course text;
BEGIN
  -- the registration must belong to the same exam/student pair
  IF NOT EXISTS (
    SELECT 1 FROM public.exam_registrations er
    WHERE er.id = NEW.exam_registration_id
      AND er.exam_id = NEW.exam_id
      AND er.student_id = NEW.student_id
  ) THEN
    RAISE EXCEPTION 'ALLOCATION_INVALID_REGISTRATION: registration does not match exam/student';
  END IF;

  -- duplicate allocation for the same exam
  IF EXISTS (
    SELECT 1 FROM public.student_hall_allocations sha
    WHERE sha.exam_id = NEW.exam_id
      AND sha.student_id = NEW.student_id
      AND sha.id <> COALESCE(NEW.id, '00000000-0000-0000-0000-000000000000'::uuid)
  ) THEN
    RAISE EXCEPTION 'ALLOCATION_DUPLICATE: student already allocated a hall for this exam';
  END IF;

  -- the room must be an approved room for this exam
  IF NOT EXISTS (
    SELECT 1 FROM public.exam_room_allocations era
    WHERE era.exam_id = NEW.exam_id AND era.room_id = NEW.room_id
  ) THEN
    RAISE EXCEPTION 'ALLOCATION_ROOM_NOT_ASSIGNED: room is not assigned to this exam';
  END IF;

  -- clash with another exam in the same time slot
  SELECT e.time_slot_id INTO v_slot FROM public.exams e WHERE e.id = NEW.exam_id;
  IF v_slot IS NOT NULL THEN
    SELECT c.code INTO v_conflict_course
    FROM public.student_hall_allocations sha
    JOIN public.exams e2 ON e2.id = sha.exam_id
    JOIN public.courses c ON c.id = e2.course_id
    WHERE sha.student_id = NEW.student_id
      AND e2.id <> NEW.exam_id
      AND e2.time_slot_id = v_slot
    LIMIT 1;

    IF v_conflict_course IS NOT NULL THEN
      RAISE EXCEPTION 'ALLOCATION_SLOT_CONFLICT: student already seated for % in this time slot', v_conflict_course;
    END IF;
  END IF;

  RETURN NEW;
END; $$;

CREATE TRIGGER trg_sha_conflict
BEFORE INSERT OR UPDATE ON public.student_hall_allocations
FOR EACH ROW EXECUTE FUNCTION public.check_allocation_conflict();

-- ---------------- TRIGGER: capacity validation ----------------
CREATE OR REPLACE FUNCTION public.check_room_capacity()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
DECLARE
  v_capacity integer;
  v_seated integer;
BEGIN
  SELECT r.exam_capacity INTO v_capacity FROM public.rooms r WHERE r.id = NEW.room_id AND r.is_active;
  IF v_capacity IS NULL THEN
    RAISE EXCEPTION 'ALLOCATION_ROOM_INACTIVE: room is inactive or missing';
  END IF;

  SELECT COUNT(*) INTO v_seated
  FROM public.student_hall_allocations sha
  WHERE sha.exam_id = NEW.exam_id
    AND sha.room_id = NEW.room_id
    AND sha.id <> COALESCE(NEW.id, '00000000-0000-0000-0000-000000000000'::uuid);

  IF v_seated >= v_capacity THEN
    RAISE EXCEPTION 'ALLOCATION_CAPACITY_EXCEEDED: room capacity % already filled', v_capacity;
  END IF;

  IF NEW.seat_number IS NOT NULL AND NEW.seat_number > v_capacity THEN
    RAISE EXCEPTION 'ALLOCATION_SEAT_OUT_OF_RANGE: seat % exceeds capacity %', NEW.seat_number, v_capacity;
  END IF;

  RETURN NEW;
END; $$;

CREATE TRIGGER trg_sha_capacity
BEFORE INSERT OR UPDATE ON public.student_hall_allocations
FOR EACH ROW EXECUTE FUNCTION public.check_room_capacity();

-- ---------------- TRIGGER: keep allocated_count in sync ----------------
CREATE OR REPLACE FUNCTION public.sync_room_allocation_count()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF TG_OP IN ('INSERT','UPDATE') THEN
    UPDATE public.exam_room_allocations era
    SET allocated_count = (SELECT COUNT(*) FROM public.student_hall_allocations sha
                           WHERE sha.exam_id = era.exam_id AND sha.room_id = era.room_id)
    WHERE era.exam_id = NEW.exam_id AND era.room_id = NEW.room_id;
  END IF;
  IF TG_OP IN ('DELETE','UPDATE') THEN
    UPDATE public.exam_room_allocations era
    SET allocated_count = (SELECT COUNT(*) FROM public.student_hall_allocations sha
                           WHERE sha.exam_id = era.exam_id AND sha.room_id = era.room_id)
    WHERE era.exam_id = OLD.exam_id AND era.room_id = OLD.room_id;
  END IF;
  RETURN NULL;
END; $$;

CREATE TRIGGER trg_sha_sync_count
AFTER INSERT OR UPDATE OR DELETE ON public.student_hall_allocations
FOR EACH ROW EXECUTE FUNCTION public.sync_room_allocation_count();

-- ---------------- TRIGGER: invigilator double-booking ----------------
CREATE OR REPLACE FUNCTION public.check_invigilator_conflict()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
DECLARE
  v_slot uuid;
  v_clash text;
  v_duties integer;
  v_max integer;
BEGIN
  SELECT e.time_slot_id INTO v_slot FROM public.exams e WHERE e.id = NEW.exam_id;

  IF v_slot IS NOT NULL THEN
    SELECT c.code || ' / room ' || r.room_number INTO v_clash
    FROM public.invigilator_assignments ia
    JOIN public.exams e2 ON e2.id = ia.exam_id
    JOIN public.courses c ON c.id = e2.course_id
    JOIN public.rooms r ON r.id = ia.room_id
    WHERE ia.faculty_id = NEW.faculty_id
      AND e2.time_slot_id = v_slot
      AND ia.id <> COALESCE(NEW.id, '00000000-0000-0000-0000-000000000000'::uuid)
    LIMIT 1;

    IF v_clash IS NOT NULL THEN
      RAISE EXCEPTION 'INVIGILATOR_SLOT_CONFLICT: faculty already on duty for % in this time slot', v_clash;
    END IF;
  END IF;

  SELECT max_duties INTO v_max FROM public.faculty WHERE id = NEW.faculty_id AND is_active;
  IF v_max IS NULL THEN
    RAISE EXCEPTION 'INVIGILATOR_INACTIVE: faculty is inactive or missing';
  END IF;

  SELECT COUNT(*) INTO v_duties FROM public.invigilator_assignments
  WHERE faculty_id = NEW.faculty_id
    AND id <> COALESCE(NEW.id, '00000000-0000-0000-0000-000000000000'::uuid);

  IF v_duties >= v_max THEN
    RAISE EXCEPTION 'INVIGILATOR_MAX_DUTIES: faculty already has % duties (max %)', v_duties, v_max;
  END IF;

  RETURN NEW;
END; $$;

CREATE TRIGGER trg_ia_conflict
BEFORE INSERT OR UPDATE ON public.invigilator_assignments
FOR EACH ROW EXECUTE FUNCTION public.check_invigilator_conflict();

-- ---------------- PROCEDURE: register_student_for_exam ----------------
CREATE OR REPLACE FUNCTION public.register_student_for_exam(_exam_id uuid, _student_id uuid)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_course_id uuid;
  v_session_year text;
  v_reg_id uuid;
  v_slot uuid;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'FORBIDDEN: only administrators may register students for exams';
  END IF;

  SELECT e.course_id, e.time_slot_id, es.academic_year
    INTO v_course_id, v_slot, v_session_year
  FROM public.exams e JOIN public.exam_sessions es ON es.id = e.session_id
  WHERE e.id = _exam_id;

  IF v_course_id IS NULL THEN
    RAISE EXCEPTION 'NOT_FOUND: exam % does not exist', _exam_id;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.students WHERE id = _student_id AND is_active) THEN
    RAISE EXCEPTION 'NOT_FOUND: active student % does not exist', _student_id;
  END IF;

  -- eligibility: the student must be registered for the underlying course
  IF NOT EXISTS (
    SELECT 1 FROM public.student_course_registrations scr
    WHERE scr.student_id = _student_id AND scr.course_id = v_course_id
      AND scr.status IN ('REGISTERED','ARREAR')
  ) THEN
    RAISE EXCEPTION 'CONFLICT: student is not registered for the course of this exam';
  END IF;

  -- reject a clash with another exam in the same time slot
  IF v_slot IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.exam_registrations er
    JOIN public.exams e2 ON e2.id = er.exam_id
    WHERE er.student_id = _student_id AND e2.time_slot_id = v_slot AND e2.id <> _exam_id
      AND er.status = 'ELIGIBLE'
  ) THEN
    RAISE EXCEPTION 'CONFLICT: student already has an exam in this time slot';
  END IF;

  INSERT INTO public.exam_registrations (exam_id, student_id)
  VALUES (_exam_id, _student_id)
  ON CONFLICT (exam_id, student_id) DO UPDATE SET status = 'ELIGIBLE'
  RETURNING id INTO v_reg_id;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (auth.uid(), 'REGISTER_STUDENT_FOR_EXAM', 'exam_registrations', v_reg_id::text,
          jsonb_build_object('exam_id', _exam_id, 'student_id', _student_id));

  RETURN v_reg_id;
END; $$;

-- ---------------- PROCEDURE: allocate_student_to_room ----------------
CREATE OR REPLACE FUNCTION public.allocate_student_to_room(
  _exam_id uuid, _student_id uuid, _room_id uuid, _seat_number integer DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_reg_id uuid;
  v_alloc_id uuid;
  v_seat integer := _seat_number;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'FORBIDDEN: only administrators may allocate halls';
  END IF;

  SELECT id INTO v_reg_id FROM public.exam_registrations
  WHERE exam_id = _exam_id AND student_id = _student_id AND status = 'ELIGIBLE';

  IF v_reg_id IS NULL THEN
    RAISE EXCEPTION 'NOT_FOUND: no eligible exam registration for this student';
  END IF;

  -- lock the room row for this exam so concurrent allocations serialise
  PERFORM 1 FROM public.exam_room_allocations
  WHERE exam_id = _exam_id AND room_id = _room_id FOR UPDATE;

  IF v_seat IS NULL THEN
    SELECT COALESCE(MAX(seat_number), 0) + 1 INTO v_seat
    FROM public.student_hall_allocations
    WHERE exam_id = _exam_id AND room_id = _room_id;
  END IF;

  INSERT INTO public.student_hall_allocations
    (exam_id, student_id, exam_registration_id, room_id, seat_number)
  VALUES (_exam_id, _student_id, v_reg_id, _room_id, v_seat)
  RETURNING id INTO v_alloc_id;

  RETURN v_alloc_id;
END; $$;

REVOKE ALL ON FUNCTION public.register_student_for_exam(uuid, uuid) FROM public;
REVOKE ALL ON FUNCTION public.allocate_student_to_room(uuid, uuid, uuid, integer) FROM public;
GRANT EXECUTE ON FUNCTION public.register_student_for_exam(uuid, uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.allocate_student_to_room(uuid, uuid, uuid, integer) TO authenticated, service_role;
