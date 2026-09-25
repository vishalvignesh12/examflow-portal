-- ============================================================
-- ExamFlow: Phase 4 — conflict detection engine
-- ============================================================

CREATE OR REPLACE FUNCTION public.detect_conflicts(_session_id uuid)
RETURNS TABLE (
  conflict_type text,
  severity      text,
  subject       text,
  detail        text,
  exam_id       uuid,
  secondary_id  uuid,
  student_id    uuid,
  room_id       uuid,
  faculty_id    uuid
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  -- 1. student scheduled for two exams in the same time slot
  SELECT 'STUDENT_CLASH', 'HIGH',
         s.register_number || ' — ' || s.full_name,
         c1.code || ' and ' || c2.code || ' both on ' || ts.slot_date::text || ' ' || ts.label,
         e1.id, e2.id, s.id, NULL::uuid, NULL::uuid
  FROM public.exam_registrations er1
  JOIN public.exam_registrations er2 ON er2.student_id = er1.student_id AND er2.exam_id <> er1.exam_id
  JOIN public.exams e1 ON e1.id = er1.exam_id
  JOIN public.exams e2 ON e2.id = er2.exam_id
  JOIN public.time_slots ts ON ts.id = e1.time_slot_id AND ts.id = e2.time_slot_id
  JOIN public.courses c1 ON c1.id = e1.course_id
  JOIN public.courses c2 ON c2.id = e2.course_id
  JOIN public.students s ON s.id = er1.student_id
  WHERE e1.session_id = _session_id AND e2.session_id = _session_id
    AND er1.status = 'ELIGIBLE' AND er2.status = 'ELIGIBLE'
    AND e1.id < e2.id

  UNION ALL
  -- 2. the same room assigned to two exams in one time slot
  SELECT 'ROOM_CONFLICT', 'HIGH',
         b.name || ' / ' || r.room_number,
         c1.code || ' and ' || c2.code || ' share this room on ' || ts.slot_date::text || ' ' || ts.label,
         e1.id, e2.id, NULL::uuid, r.id, NULL::uuid
  FROM public.exam_room_allocations era1
  JOIN public.exam_room_allocations era2 ON era2.room_id = era1.room_id AND era2.exam_id <> era1.exam_id
  JOIN public.exams e1 ON e1.id = era1.exam_id
  JOIN public.exams e2 ON e2.id = era2.exam_id
  JOIN public.time_slots ts ON ts.id = e1.time_slot_id AND ts.id = e2.time_slot_id
  JOIN public.courses c1 ON c1.id = e1.course_id
  JOIN public.courses c2 ON c2.id = e2.course_id
  JOIN public.rooms r ON r.id = era1.room_id
  JOIN public.buildings b ON b.id = r.building_id
  WHERE e1.session_id = _session_id AND e2.session_id = _session_id AND e1.id < e2.id

  UNION ALL
  -- 3. invigilator on duty twice in one time slot
  SELECT 'INVIGILATOR_CONFLICT', 'MEDIUM',
         f.staff_code || ' — ' || f.full_name,
         'Two duties on ' || ts.slot_date::text || ' ' || ts.label,
         e1.id, e2.id, NULL::uuid, NULL::uuid, f.id
  FROM public.invigilator_assignments ia1
  JOIN public.invigilator_assignments ia2 ON ia2.faculty_id = ia1.faculty_id AND ia2.exam_id <> ia1.exam_id
  JOIN public.exams e1 ON e1.id = ia1.exam_id
  JOIN public.exams e2 ON e2.id = ia2.exam_id
  JOIN public.time_slots ts ON ts.id = e1.time_slot_id AND ts.id = e2.time_slot_id
  JOIN public.faculty f ON f.id = ia1.faculty_id
  WHERE e1.session_id = _session_id AND e2.session_id = _session_id AND e1.id < e2.id

  UNION ALL
  -- 4. registered students exceed the seating assigned to the exam
  SELECT 'CAPACITY_CONFLICT', 'HIGH',
         c.code || ' — ' || c.title,
         reg.cnt || ' students registered but only ' || COALESCE(cap.seats, 0) || ' seats assigned',
         e.id, NULL::uuid, NULL::uuid, NULL::uuid, NULL::uuid
  FROM public.exams e
  JOIN public.courses c ON c.id = e.course_id
  JOIN (SELECT exam_id, COUNT(*) cnt FROM public.exam_registrations
        WHERE status = 'ELIGIBLE' GROUP BY exam_id) reg ON reg.exam_id = e.id
  LEFT JOIN (SELECT era.exam_id, SUM(r.exam_capacity) seats
             FROM public.exam_room_allocations era JOIN public.rooms r ON r.id = era.room_id
             WHERE r.is_active GROUP BY era.exam_id) cap ON cap.exam_id = e.id
  WHERE e.session_id = _session_id AND reg.cnt > COALESCE(cap.seats, 0)

  UNION ALL
  -- 5. exam without a time slot cannot be published
  SELECT 'UNSCHEDULED_EXAM', 'MEDIUM',
         c.code || ' — ' || c.title,
         'No time slot assigned',
         e.id, NULL::uuid, NULL::uuid, NULL::uuid, NULL::uuid
  FROM public.exams e
  JOIN public.courses c ON c.id = e.course_id
  WHERE e.session_id = _session_id AND e.time_slot_id IS NULL;
$$;

REVOKE ALL ON FUNCTION public.detect_conflicts(uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.detect_conflicts(uuid) TO authenticated, service_role;

-- publish an entire session atomically (all-or-nothing)
CREATE OR REPLACE FUNCTION public.publish_exam_session(_session_id uuid)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_blockers integer;
  v_count integer;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'FORBIDDEN: only administrators may publish a timetable';
  END IF;

  SELECT COUNT(*) INTO v_blockers
  FROM public.detect_conflicts(_session_id) WHERE severity = 'HIGH';

  IF v_blockers > 0 THEN
    RAISE EXCEPTION 'CONFLICT: % blocking conflict(s) must be resolved before publishing', v_blockers;
  END IF;

  UPDATE public.exams
  SET status = 'PUBLISHED', published_at = now()
  WHERE session_id = _session_id AND status <> 'CANCELLED' AND time_slot_id IS NOT NULL;
  GET DIAGNOSTICS v_count = ROW_COUNT;

  UPDATE public.exam_sessions
  SET status = 'PUBLISHED', published_at = now()
  WHERE id = _session_id;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (auth.uid(), 'PUBLISH_SESSION', 'exam_sessions', _session_id::text,
          jsonb_build_object('exams_published', v_count));

  RETURN v_count;
END; $$;

REVOKE ALL ON FUNCTION public.publish_exam_session(uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.publish_exam_session(uuid) TO authenticated, service_role;

-- bulk sequential allocation by register number, inside one transaction
CREATE OR REPLACE FUNCTION public.allocate_exam_sequentially(
  _exam_id uuid, _room_ids uuid[], _generate_seats boolean DEFAULT true
)
RETURNS TABLE (allocated integer, unallocated integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  r_student record;
  v_room uuid;
  v_seat integer;
  v_cap integer;
  v_used integer;
  v_alloc integer := 0;
  v_left integer := 0;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'FORBIDDEN: only administrators may allocate halls';
  END IF;

  IF _room_ids IS NULL OR array_length(_room_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'BAD_REQUEST: select at least one room';
  END IF;

  -- register the chosen rooms for this exam
  FOREACH v_room IN ARRAY _room_ids LOOP
    INSERT INTO public.exam_room_allocations (exam_id, room_id)
    VALUES (_exam_id, v_room) ON CONFLICT (exam_id, room_id) DO NOTHING;
  END LOOP;

  -- clear any previous seating for this exam so re-allocation is idempotent
  DELETE FROM public.student_hall_allocations WHERE exam_id = _exam_id;

  FOR r_student IN
    SELECT er.student_id, er.id AS reg_id
    FROM public.exam_registrations er
    JOIN public.students s ON s.id = er.student_id
    WHERE er.exam_id = _exam_id AND er.status = 'ELIGIBLE'
    ORDER BY s.register_number
  LOOP
    v_room := NULL;
    FOREACH v_seat IN ARRAY ARRAY[1] LOOP END LOOP; -- no-op, keeps v_seat typed

    -- first room in the given order that still has free capacity
    SELECT room_id INTO v_room FROM (
      SELECT u.room_id, u.ord, r.exam_capacity,
             (SELECT COUNT(*) FROM public.student_hall_allocations sha
              WHERE sha.exam_id = _exam_id AND sha.room_id = u.room_id) AS used
      FROM unnest(_room_ids) WITH ORDINALITY AS u(room_id, ord)
      JOIN public.rooms r ON r.id = u.room_id AND r.is_active
    ) q
    WHERE q.used < q.exam_capacity
    ORDER BY q.ord
    LIMIT 1;

    IF v_room IS NULL THEN
      v_left := v_left + 1;
      CONTINUE;
    END IF;

    SELECT r.exam_capacity INTO v_cap FROM public.rooms r WHERE r.id = v_room;
    SELECT COUNT(*) INTO v_used FROM public.student_hall_allocations
    WHERE exam_id = _exam_id AND room_id = v_room;

    INSERT INTO public.student_hall_allocations
      (exam_id, student_id, exam_registration_id, room_id, seat_number)
    VALUES (_exam_id, r_student.student_id, r_student.reg_id, v_room,
            CASE WHEN _generate_seats THEN v_used + 1 ELSE NULL END);

    v_alloc := v_alloc + 1;
  END LOOP;

  UPDATE public.exams
  SET status = CASE WHEN status IN ('DRAFT','SCHEDULED') THEN 'ALLOCATED' ELSE status END,
      seats_generated = _generate_seats
  WHERE id = _exam_id;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (auth.uid(), 'ALLOCATE_EXAM', 'exams', _exam_id::text,
          jsonb_build_object('allocated', v_alloc, 'unallocated', v_left, 'rooms', _room_ids));

  RETURN QUERY SELECT v_alloc, v_left;
END; $$;

REVOKE ALL ON FUNCTION public.allocate_exam_sequentially(uuid, uuid[], boolean) FROM public;
GRANT EXECUTE ON FUNCTION public.allocate_exam_sequentially(uuid, uuid[], boolean) TO authenticated, service_role;
