# ExamFlow Portal

Create a functional full-stack app named ExamFlow — University Examination Scheduling & Hall Allocation Portal. The attached PRD is authoritative; implement its P0 requirements first, then P1.

Core roles: ADMIN, FACULTY, STUDENT with secure authentication, hashed passwords, backend RBAC. Core entities: Department, Student, Faculty, Course, StudentCourseRegistration, Building, Room, ExamSession, TimeSlot, Exam, ExamRegistration, ExamRoomAllocation, StudentHallAllocation, InvigilatorAssignment, AuditLog.

P0 workflow: admin manages master data; creates sessions, time slots and exams; maintains/generates registrations; detects student conflicts, room conflicts, invigilator conflicts and capacity conflicts; resolves conflicts; allocates students sequentially by register number into selected rooms and optionally generates seats; assigns invigilators; publishes timetable. Students see only published exams plus hall/seat. Faculty see assigned duties and room/student count.

Required routes:
 /login
 /admin/dashboard /admin/students /admin/students/new /admin/courses /admin/courses/new /admin/faculty /admin/departments /admin/buildings /admin/rooms /admin/sessions /admin/slots /admin/exams /admin/exams/new /admin/exams/:id /admin/exams/:id/allocation /admin/exams/:id/invigilators /admin/conflicts /admin/timetable /admin/reports
 /student/dashboard /student/profile /student/courses /student/timetable /student/exams
 /faculty/dashboard /faculty/duties /faculty/exams/:id

Use a clean, restrained university administration UI: responsive mobile/tablet/desktop, reusable tables/forms/modals/status badges/pagination/search/filter/dashboard cards, accessible labels/ARIA and keyboard navigation, loading/empty/error states, validation, toast feedback and confirmation for destructive actions.

DBMS is the academic core. PostgreSQL must contain a 3NF relational schema with PK/FK/composite keys, UNIQUE, NOT NULL, CHECK, DEFAULT and referential integrity. Create views named student_exam_timetable, exam_summary and room_utilization. Create PostgreSQL functions/procedures for register_student_for_exam and allocate_student_to_room. Create at least three PostgreSQL triggers for duplicate/conflicting allocation, capacity validation and audit logging. Add useful indexes and document EXPLAIN ANALYZE before/after for a representative query. Use transactions for multi-step allocation. Include demo SQL for INNER JOIN, LEFT JOIN, aggregate, GROUP BY/HAVING, subquery, conflict detection, room utilization and multi-table timetable joins. Do not fake DBMS features in frontend code.

The PRD recommends Java/Spring Boot + PostgreSQL + React/Vite, but Lovable's native stack is TypeScript/React with managed PostgreSQL/Supabase. Preserve behavior and database semantics; if Spring Boot or standalone PostgreSQL cannot be implemented in this environment, use the closest native architecture and explicitly document the deviation rather than claiming it exists. No external APIs, no online exams, payments, ERP, SMS/email, AI optimization, facial recognition or mobile app.

Seed deterministic demo data approximately: 5 departments, 100+ students, 20+ faculty, 30+ courses, 3+ buildings, 15+ rooms, 10+ slots, 2 sessions, 20+ exams, 300+ registrations, with intentional conflicts.

Include README.md, DATABASE_DESIGN.md, NORMALIZATION.md, API_DOCUMENTATION.md, ER_DIAGRAM.md/equivalent, SQL/database artifacts and architecture deviation notes. Match the PRD REST endpoint semantics where possible. Implement consistent 200/201/400/401/403/404/409/500 error handling.

Build the complete demonstrable flow: Admin login → data → session/slots/exams → registrations → conflict detection/resolution → room/capacity validation → hall/seat allocation → invigilators → publish → student timetable/hall/seat → faculty duty. Work continuously through the phases and summarize each major completed phase in your response.

This project was built with [Lovable](https://lovable.dev).

## Build with Lovable

Continue developing this project in the [Lovable editor](https://lovable.dev/projects/451b18f1-1d96-4b20-b7f5-bbe69f847192).

- **Ship faster**: describe what you want to build and Lovable handles the code.
- **Stay in sync**: every change made in Lovable is committed straight to this repository.
- **Full ownership**: this code is yours. Push to `main` on GitHub and your changes sync back into Lovable, ready for your next prompt.

## Development

Prefer working locally? You need Node.js and npm — [install with nvm](https://github.com/nvm-sh/nvm#installing-and-updating).

```sh
git clone <this-repository-url>
cd <repository-name>
npm i
npm run dev
```
