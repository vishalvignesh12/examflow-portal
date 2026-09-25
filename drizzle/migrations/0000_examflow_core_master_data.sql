-- ============================================================
-- ExamFlow: Phase 1 — identity, RBAC and academic master data
-- ============================================================

CREATE TYPE public.app_role AS ENUM ('ADMIN', 'FACULTY', 'STUDENT');

-- ---------- profiles ----------
CREATE TABLE public.profiles (
  id          uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email       text NOT NULL,
  full_name   text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT profiles_email_format CHECK (email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$')
);
GRANT SELECT, INSERT, UPDATE ON public.profiles TO authenticated;
GRANT ALL ON public.profiles TO service_role;
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

-- ---------- user_roles ----------
CREATE TABLE public.user_roles (
  id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id  uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role     public.app_role NOT NULL,
  UNIQUE (user_id, role)
);
GRANT SELECT ON public.user_roles TO authenticated;
GRANT ALL ON public.user_roles TO service_role;
ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.has_role(_user_id uuid, _role public.app_role)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = _user_id AND role = _role);
$$;

CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$ SELECT public.has_role(auth.uid(), 'ADMIN'::public.app_role); $$;

CREATE POLICY "own profile readable" ON public.profiles FOR SELECT TO authenticated
  USING (id = auth.uid() OR public.is_admin());
CREATE POLICY "own profile updatable" ON public.profiles FOR UPDATE TO authenticated
  USING (id = auth.uid() OR public.is_admin());
CREATE POLICY "own profile insert" ON public.profiles FOR INSERT TO authenticated
  WITH CHECK (id = auth.uid());

CREATE POLICY "own roles readable" ON public.user_roles FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR public.is_admin());

-- auto-create profile on signup
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO public.profiles (id, email, full_name)
  VALUES (NEW.id, NEW.email, COALESCE(NEW.raw_user_meta_data->>'full_name', split_part(NEW.email,'@',1)))
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END; $$;

CREATE TRIGGER on_auth_user_created
AFTER INSERT ON auth.users
FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- generic updated_at helper
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END; $$;

-- ============================================================
-- Academic master data
-- ============================================================

CREATE TABLE public.departments (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code        text NOT NULL UNIQUE,
  name        text NOT NULL UNIQUE,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT departments_code_chk CHECK (code = upper(code) AND char_length(code) BETWEEN 2 AND 10)
);

CREATE TABLE public.faculty (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        uuid UNIQUE REFERENCES auth.users(id) ON DELETE SET NULL,
  staff_code     text NOT NULL UNIQUE,
  full_name      text NOT NULL,
  email          text NOT NULL UNIQUE,
  phone          text,
  designation    text NOT NULL DEFAULT 'Assistant Professor',
  department_id  uuid NOT NULL REFERENCES public.departments(id) ON DELETE RESTRICT,
  max_duties     integer NOT NULL DEFAULT 6,
  is_active      boolean NOT NULL DEFAULT true,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT faculty_max_duties_chk CHECK (max_duties BETWEEN 0 AND 40),
  CONSTRAINT faculty_email_chk CHECK (email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$')
);

CREATE TABLE public.students (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          uuid UNIQUE REFERENCES auth.users(id) ON DELETE SET NULL,
  register_number  text NOT NULL UNIQUE,
  full_name        text NOT NULL,
  email            text NOT NULL UNIQUE,
  phone            text,
  department_id    uuid NOT NULL REFERENCES public.departments(id) ON DELETE RESTRICT,
  semester         integer NOT NULL,
  program          text NOT NULL DEFAULT 'B.E.',
  batch_year       integer NOT NULL,
  is_active        boolean NOT NULL DEFAULT true,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT students_semester_chk CHECK (semester BETWEEN 1 AND 10),
  CONSTRAINT students_batch_chk CHECK (batch_year BETWEEN 2000 AND 2100),
  CONSTRAINT students_regno_chk CHECK (char_length(register_number) BETWEEN 4 AND 20),
  CONSTRAINT students_email_chk CHECK (email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$')
);

CREATE TABLE public.courses (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code           text NOT NULL UNIQUE,
  title          text NOT NULL,
  department_id  uuid NOT NULL REFERENCES public.departments(id) ON DELETE RESTRICT,
  semester       integer NOT NULL,
  credits        integer NOT NULL DEFAULT 3,
  course_type    text NOT NULL DEFAULT 'CORE',
  is_active      boolean NOT NULL DEFAULT true,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT courses_semester_chk CHECK (semester BETWEEN 1 AND 10),
  CONSTRAINT courses_credits_chk CHECK (credits BETWEEN 1 AND 10),
  CONSTRAINT courses_type_chk CHECK (course_type IN ('CORE','ELECTIVE','LAB','OPEN_ELECTIVE'))
);

CREATE TABLE public.student_course_registrations (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  student_id    uuid NOT NULL REFERENCES public.students(id) ON DELETE CASCADE,
  course_id     uuid NOT NULL REFERENCES public.courses(id) ON DELETE CASCADE,
  academic_year text NOT NULL,
  status        text NOT NULL DEFAULT 'REGISTERED',
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT scr_unique UNIQUE (student_id, course_id, academic_year),
  CONSTRAINT scr_status_chk CHECK (status IN ('REGISTERED','DROPPED','ARREAR'))
);

CREATE TABLE public.buildings (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code        text NOT NULL UNIQUE,
  name        text NOT NULL,
  floors      integer NOT NULL DEFAULT 1,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT buildings_floors_chk CHECK (floors BETWEEN 1 AND 20)
);

CREATE TABLE public.rooms (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  building_id   uuid NOT NULL REFERENCES public.buildings(id) ON DELETE RESTRICT,
  room_number   text NOT NULL,
  floor         integer NOT NULL DEFAULT 1,
  capacity      integer NOT NULL,
  exam_capacity integer NOT NULL,
  room_type     text NOT NULL DEFAULT 'CLASSROOM',
  is_active     boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT rooms_unique UNIQUE (building_id, room_number),
  CONSTRAINT rooms_capacity_chk CHECK (capacity > 0 AND capacity <= 500),
  CONSTRAINT rooms_exam_capacity_chk CHECK (exam_capacity > 0 AND exam_capacity <= capacity),
  CONSTRAINT rooms_type_chk CHECK (room_type IN ('CLASSROOM','HALL','LAB','SEMINAR'))
);

-- grants + RLS: master data readable by any authenticated user, writable by ADMIN only
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['departments','faculty','students','courses','student_course_registrations','buildings','rooms']
  LOOP
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON public.%I TO authenticated', t);
    EXECUTE format('GRANT ALL ON public.%I TO service_role', t);
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('CREATE POLICY "read for authenticated" ON public.%I FOR SELECT TO authenticated USING (true)', t);
    EXECUTE format('CREATE POLICY "admin insert" ON public.%I FOR INSERT TO authenticated WITH CHECK (public.is_admin())', t);
    EXECUTE format('CREATE POLICY "admin update" ON public.%I FOR UPDATE TO authenticated USING (public.is_admin())', t);
    EXECUTE format('CREATE POLICY "admin delete" ON public.%I FOR DELETE TO authenticated USING (public.is_admin())', t);
  END LOOP;
END $$;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['profiles','departments','faculty','students','courses','buildings','rooms']
  LOOP
    EXECUTE format('CREATE TRIGGER trg_%s_updated_at BEFORE UPDATE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.set_updated_at()', t, t);
  END LOOP;
END $$;

-- indexes
CREATE INDEX idx_students_department ON public.students(department_id);
CREATE INDEX idx_students_semester ON public.students(semester);
CREATE INDEX idx_students_regno ON public.students(register_number);
CREATE INDEX idx_faculty_department ON public.faculty(department_id);
CREATE INDEX idx_courses_department_semester ON public.courses(department_id, semester);
CREATE INDEX idx_scr_student ON public.student_course_registrations(student_id);
CREATE INDEX idx_scr_course ON public.student_course_registrations(course_id);
CREATE INDEX idx_rooms_building ON public.rooms(building_id);
