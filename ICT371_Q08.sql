-- ICT371 Advanced Database | Question 8: Transport Fleet Maintenance
-- Name: Nawa Sumbwanyambe | Student number: 202308788
-- DBMS: PostgreSQL (PL/pgSQL; scheduling with the pg_cron extension)

DROP TABLE IF EXISTS service_alerts, trips, vehicles CASCADE;

-- ==== (a) Database: create the tables
CREATE TABLE vehicles (
    vehicle_id            SERIAL      PRIMARY KEY,
    registration          VARCHAR(15) NOT NULL UNIQUE,
    current_odometer      INTEGER     NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer INTEGER     NOT NULL CHECK (last_service_odometer >= 0),
    CONSTRAINT ck_service_not_ahead CHECK (last_service_odometer <= current_odometer)
);

CREATE TABLE trips (
    trip_id        SERIAL   PRIMARY KEY,
    vehicle_id     INTEGER  NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on        DATE     NOT NULL,
    start_odometer INTEGER  NOT NULL CHECK (start_odometer >= 0),
    end_odometer   INTEGER  NOT NULL CHECK (end_odometer >= 0)
);

CREATE TABLE service_alerts (
    vehicle_id       INTEGER PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service INTEGER NOT NULL,
    flagged_on       DATE    NOT NULL
);

-- ==== (b) Function fn_service_due: TRUE when at least 5,000 km since last service
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INTEGER)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_km INTEGER;
BEGIN
    SELECT current_odometer - last_service_odometer INTO v_km
    FROM vehicles
    WHERE vehicle_id = p_vehicle_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;

    RETURN v_km >= 5000;
END;
$$;

-- ==== (d) Trigger first: BEFORE INSERT row trigger on trips
CREATE OR REPLACE FUNCTION trg_fn_trips_odometer()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_current INTEGER;
BEGIN
    -- Lock the vehicle so two trips cannot both start from the same odometer value.
    SELECT current_odometer INTO v_current
    FROM vehicles
    WHERE vehicle_id = NEW.vehicle_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', NEW.vehicle_id;
    END IF;

    IF NEW.start_odometer < 0 OR NEW.end_odometer < 0 OR NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'Invalid mileage: start %, end % (end must exceed start, both non-negative)',
            NEW.start_odometer, NEW.end_odometer;
    END IF;

    IF NEW.start_odometer <> v_current THEN
        RAISE EXCEPTION 'Start odometer % does not match vehicle % current odometer %',
            NEW.start_odometer, NEW.vehicle_id, v_current;
    END IF;

    UPDATE vehicles                                   -- exactly one update per inserted trip
    SET current_odometer = NEW.end_odometer
    WHERE vehicle_id = NEW.vehicle_id;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_trips_odometer
BEFORE INSERT ON trips
FOR EACH ROW
EXECUTE FUNCTION trg_fn_trips_odometer();

-- ==== (c) Procedure pr_record_trip (does NOT touch the odometer; the trigger does)
CREATE OR REPLACE PROCEDURE pr_record_trip(p_vehicle_id INTEGER, p_trip_on DATE, p_start INTEGER, p_end INTEGER)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM 1 FROM vehicles WHERE vehicle_id = p_vehicle_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;

    IF p_trip_on IS NULL OR p_start IS NULL OR p_end IS NULL THEN
        RAISE EXCEPTION 'Trip date, start odometer and end odometer are required';
    END IF;

    IF p_end <= p_start THEN
        RAISE EXCEPTION 'end_odometer (%) must be greater than start_odometer (%)', p_end, p_start;
    END IF;

    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END;
$$;

-- ==== (e) View v_service_due
CREATE OR REPLACE VIEW v_service_due AS
SELECT registration,
       current_odometer - last_service_odometer AS km_since_service
FROM vehicles
WHERE current_odometer - last_service_odometer >= 5000;

-- ==== (f) Index: one vehicle's trips in a trip_on date range
-- Equality column first (vehicle_id), range column second (trip_on).
CREATE INDEX idx_trips_vehicle_trip_on ON trips (vehicle_id, trip_on);

-- ==== (g) Scheduled job: pr_refresh_service_alerts
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql
AS $$
BEGIN
    -- Insert new alerts / update the distance on existing ones (original flagged_on is kept).
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT vehicle_id, current_odometer - last_service_odometer, CURRENT_DATE
    FROM vehicles
    WHERE current_odometer - last_service_odometer >= 5000
    ON CONFLICT (vehicle_id) DO UPDATE
    SET km_since_service = EXCLUDED.km_since_service;

    -- Remove alerts for vehicles that are no longer due (e.g. after servicing).
    DELETE FROM service_alerts sa
    WHERE NOT EXISTS (
        SELECT 1 FROM vehicles v
        WHERE v.vehicle_id = sa.vehicle_id
          AND v.current_odometer - v.last_service_odometer >= 5000
    );
END;
$$;

-- Requires: CREATE EXTENSION pg_cron;
SELECT cron.schedule(
    'refresh_service_alerts_weekly',
    '0 6 * * 1',                               -- every Monday at 06:00
    $$CALL pr_refresh_service_alerts()$$
);

-- ==== (a) Seed data: 3 vehicles with different service positions, 6 trips through the procedure
INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
    ('BAE 1001', 10000,  9000),    -- 1,000 km since service
    ('BAF 2002', 20000, 14000),    -- 6,000 km: already overdue
    ('BAG 3003', 30000, 25000);    -- exactly 5,000 km: on the threshold

CALL pr_record_trip(1, '2026-11-01', 10000, 10200);
CALL pr_record_trip(1, '2026-11-03', 10200, 10450);
CALL pr_record_trip(2, '2026-11-02', 20000, 20300);
CALL pr_record_trip(2, '2026-11-05', 20300, 20500);
CALL pr_record_trip(3, '2026-11-04', 30000, 30100);
CALL pr_record_trip(3, '2026-11-06', 30100, 30400);

SELECT * FROM vehicles ORDER BY vehicle_id;       -- odometers advanced by the trigger
SELECT * FROM trips ORDER BY trip_id;

-- ==== (b) Function tests
SELECT vehicle_id, registration, fn_service_due(vehicle_id) AS service_due FROM vehicles ORDER BY vehicle_id;
DO $$ BEGIN PERFORM fn_service_due(99); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED: %', SQLERRM; END $$;

-- ==== (c) Procedure tests
DO $$ BEGIN CALL pr_record_trip(99, '2026-11-10', 100, 200);   EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_record_trip(1, '2026-11-10', 10450, 10450); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_record_trip(1, '2026-11-10', 10450, 10400); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_record_trip(1, '2026-11-10', 9999, 10100);  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED: %', SQLERRM; END $$;  -- wrong start (trigger)
SELECT vehicle_id, current_odometer FROM vehicles WHERE vehicle_id = 1;      -- unchanged by failures

-- ==== (d) Trigger tests (direct SQL)
DO $$ BEGIN INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer) VALUES (1, '2026-11-10', 5000, 5100);
       EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED: %', SQLERRM; END $$;
DO $$ BEGIN INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer) VALUES (1, '2026-11-10', 10450, 10000);
       EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED: %', SQLERRM; END $$;
CALL pr_record_trip(1, '2026-11-10', 10450, 11000);   -- valid: odometer moves exactly 550 km
SELECT vehicle_id, current_odometer FROM vehicles WHERE vehicle_id = 1;       -- 11000, not 11550

-- ==== (e) View
SELECT * FROM v_service_due ORDER BY registration;

-- ==== (f) EXPLAIN
ANALYZE trips;
SET enable_seqscan = off;   -- tiny demo table: force the planner to show the index plan
EXPLAIN
SELECT trip_id, trip_on, start_odometer, end_odometer
FROM trips
WHERE vehicle_id = 2
  AND trip_on BETWEEN '2026-11-01' AND '2026-11-30';
RESET enable_seqscan;

-- ==== (g) Run the job; service a vehicle; run again
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id;       -- vehicles 2 and 3
CALL pr_record_trip(2, '2026-11-12', 20500, 20900);     -- vehicle 2 travels further
UPDATE vehicles SET last_service_odometer = current_odometer WHERE vehicle_id = 3;   -- vehicle 3 is serviced
CALL pr_refresh_service_alerts();                       -- update vehicle 2, remove vehicle 3
SELECT * FROM service_alerts ORDER BY vehicle_id;
CALL pr_refresh_service_alerts();                       -- rerun: nothing duplicated
SELECT * FROM service_alerts ORDER BY vehicle_id;
SELECT jobname, schedule, command FROM cron.job WHERE jobname = 'refresh_service_alerts_weekly';
