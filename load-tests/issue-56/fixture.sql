BEGIN;

-- Issue #56 uses the store seeded by V2 and creates all customers through the public sign-up API.
INSERT INTO service (id, store_id, name, description, duration_minutes, cleanup_minutes, capacity, status, created_at,
                     updated_at)
VALUES ('00000000-0000-7000-8000-000000000401', '00000000-0000-7000-8000-000000000001', '현장 대기 부하 테스트 서비스',
        '현장 대기 polling 부하 테스트용 서비스', 30, 0, 1, 'ACTIVE', now(), now())
ON CONFLICT (id) DO UPDATE
SET store_id = EXCLUDED.store_id,
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    duration_minutes = EXCLUDED.duration_minutes,
    cleanup_minutes = EXCLUDED.cleanup_minutes,
    capacity = EXCLUDED.capacity,
    status = EXCLUDED.status,
    updated_at = now();

INSERT INTO business_hour (id, store_id, day_of_week, open_time, close_time, is_closed)
VALUES
  ('00000000-0000-7000-8000-000000000601', '00000000-0000-7000-8000-000000000001', 'MONDAY', '00:00', '23:59', false),
  ('00000000-0000-7000-8000-000000000602', '00000000-0000-7000-8000-000000000001', 'TUESDAY', '00:00', '23:59', false),
  ('00000000-0000-7000-8000-000000000603', '00000000-0000-7000-8000-000000000001', 'WEDNESDAY', '00:00', '23:59', false),
  ('00000000-0000-7000-8000-000000000604', '00000000-0000-7000-8000-000000000001', 'THURSDAY', '00:00', '23:59', false),
  ('00000000-0000-7000-8000-000000000605', '00000000-0000-7000-8000-000000000001', 'FRIDAY', '00:00', '23:59', false),
  ('00000000-0000-7000-8000-000000000606', '00000000-0000-7000-8000-000000000001', 'SATURDAY', '00:00', '23:59', false),
  ('00000000-0000-7000-8000-000000000607', '00000000-0000-7000-8000-000000000001', 'SUNDAY', '00:00', '23:59', false)
ON CONFLICT (id) DO UPDATE
SET store_id = EXCLUDED.store_id,
    day_of_week = EXCLUDED.day_of_week,
    open_time = EXCLUDED.open_time,
    close_time = EXCLUDED.close_time,
    is_closed = EXCLUDED.is_closed;

COMMIT;
