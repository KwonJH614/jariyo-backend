BEGIN;

-- k6 fixture IDs: store=00000000-0000-7000-8000-000000000001
-- k6 fixture IDs: service=00000000-0000-7000-8000-000000000401
-- k6 fixture IDs: staff=00000000-0000-7000-8000-000000000301
INSERT INTO users (id, email, phone_number, password_hash, status, created_at, updated_at)
VALUES ('00000000-0000-7000-8000-000000000201', 'issue-57-staff@jariyo.local', '010-0000-0057',
        '{noop}issue-57-load-test', 'ACTIVE', now(), now())
ON CONFLICT (id) DO UPDATE
SET email = EXCLUDED.email,
    phone_number = EXCLUDED.phone_number,
    password_hash = EXCLUDED.password_hash,
    status = EXCLUDED.status,
    updated_at = now();

INSERT INTO store_member (id, store_id, user_id, role, display_name, status, booking_enabled, created_at, updated_at)
VALUES ('00000000-0000-7000-8000-000000000301', '00000000-0000-7000-8000-000000000001',
        '00000000-0000-7000-8000-000000000201', 'STAFF', '부하 테스트 직원', 'ACTIVE', true, now(), now())
ON CONFLICT (id) DO UPDATE
SET store_id = EXCLUDED.store_id,
    user_id = EXCLUDED.user_id,
    role = EXCLUDED.role,
    display_name = EXCLUDED.display_name,
    status = EXCLUDED.status,
    booking_enabled = EXCLUDED.booking_enabled,
    updated_at = now();

INSERT INTO service (id, store_id, name, description, duration_minutes, cleanup_minutes, capacity, status, created_at,
                     updated_at)
VALUES ('00000000-0000-7000-8000-000000000401', '00000000-0000-7000-8000-000000000001', '부하 테스트 서비스',
        '동시 예약 부하 테스트용 30분 서비스', 30, 10, 1, 'ACTIVE', now(), now())
ON CONFLICT (id) DO UPDATE
SET store_id = EXCLUDED.store_id,
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    duration_minutes = EXCLUDED.duration_minutes,
    cleanup_minutes = EXCLUDED.cleanup_minutes,
    capacity = EXCLUDED.capacity,
    status = EXCLUDED.status,
    updated_at = now();

INSERT INTO staff_service (id, store_member_id, service_id, custom_duration_minutes, active)
VALUES ('00000000-0000-7000-8000-000000000501', '00000000-0000-7000-8000-000000000301',
        '00000000-0000-7000-8000-000000000401', NULL, true)
ON CONFLICT (id) DO UPDATE
SET store_member_id = EXCLUDED.store_member_id,
    service_id = EXCLUDED.service_id,
    custom_duration_minutes = EXCLUDED.custom_duration_minutes,
    active = EXCLUDED.active;

INSERT INTO business_hour (id, store_id, day_of_week, open_time, close_time, is_closed)
VALUES
  ('00000000-0000-7000-8000-000000000601', '00000000-0000-7000-8000-000000000001', 'MONDAY', '09:00', '18:00', false),
  ('00000000-0000-7000-8000-000000000602', '00000000-0000-7000-8000-000000000001', 'TUESDAY', '09:00', '18:00', false),
  ('00000000-0000-7000-8000-000000000603', '00000000-0000-7000-8000-000000000001', 'WEDNESDAY', '09:00', '18:00', false),
  ('00000000-0000-7000-8000-000000000604', '00000000-0000-7000-8000-000000000001', 'THURSDAY', '09:00', '18:00', false),
  ('00000000-0000-7000-8000-000000000605', '00000000-0000-7000-8000-000000000001', 'FRIDAY', '09:00', '18:00', false),
  ('00000000-0000-7000-8000-000000000606', '00000000-0000-7000-8000-000000000001', 'SATURDAY', '09:00', '18:00', false),
  ('00000000-0000-7000-8000-000000000607', '00000000-0000-7000-8000-000000000001', 'SUNDAY', '09:00', '18:00', false)
ON CONFLICT (id) DO UPDATE
SET store_id = EXCLUDED.store_id,
    day_of_week = EXCLUDED.day_of_week,
    open_time = EXCLUDED.open_time,
    close_time = EXCLUDED.close_time,
    is_closed = EXCLUDED.is_closed;

INSERT INTO staff_schedule (id, store_member_id, day_of_week, start_time, end_time, valid_from, valid_until, created_at)
VALUES
  ('00000000-0000-7000-8000-000000000701', '00000000-0000-7000-8000-000000000301', 'MONDAY', '09:00', '18:00', '2026-01-01', NULL, now()),
  ('00000000-0000-7000-8000-000000000702', '00000000-0000-7000-8000-000000000301', 'TUESDAY', '09:00', '18:00', '2026-01-01', NULL, now()),
  ('00000000-0000-7000-8000-000000000703', '00000000-0000-7000-8000-000000000301', 'WEDNESDAY', '09:00', '18:00', '2026-01-01', NULL, now()),
  ('00000000-0000-7000-8000-000000000704', '00000000-0000-7000-8000-000000000301', 'THURSDAY', '09:00', '18:00', '2026-01-01', NULL, now()),
  ('00000000-0000-7000-8000-000000000705', '00000000-0000-7000-8000-000000000301', 'FRIDAY', '09:00', '18:00', '2026-01-01', NULL, now()),
  ('00000000-0000-7000-8000-000000000706', '00000000-0000-7000-8000-000000000301', 'SATURDAY', '09:00', '18:00', '2026-01-01', NULL, now()),
  ('00000000-0000-7000-8000-000000000707', '00000000-0000-7000-8000-000000000301', 'SUNDAY', '09:00', '18:00', '2026-01-01', NULL, now())
ON CONFLICT (id) DO UPDATE
SET store_member_id = EXCLUDED.store_member_id,
    day_of_week = EXCLUDED.day_of_week,
    start_time = EXCLUDED.start_time,
    end_time = EXCLUDED.end_time,
    valid_from = EXCLUDED.valid_from,
    valid_until = EXCLUDED.valid_until;

COMMIT;
