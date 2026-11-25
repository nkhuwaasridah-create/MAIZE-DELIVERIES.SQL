-- ICT371 Advanced Database - Question 9: Maize Deliveries

-- ==== Setup ====
-- Run top to bottom in psql / pgAdmin (PostgreSQL 11 or later).
-- Scheduling in part (g) needs the pg_cron extension.
-- Rates: grade A K5/kg, grade B K4/kg, grade C K3/kg.
DROP TABLE IF EXISTS daily_purchases, deliveries, farmers CASCADE;

-- ==== (a) Database and seed data ====
CREATE TABLE farmers (
    farmer_id     SERIAL PRIMARY KEY,
    farmer_number VARCHAR(20) NOT NULL UNIQUE,
    full_name     VARCHAR(100) NOT NULL
);

CREATE TABLE deliveries (
    delivery_id  SERIAL PRIMARY KEY,
    farmer_id    INTEGER NOT NULL REFERENCES farmers(farmer_id),
    grade        VARCHAR(1) NOT NULL CHECK (grade IN ('A', 'B', 'C')),
    weight_kg    NUMERIC(10,2) NOT NULL CHECK (weight_kg > 0),
    unit_rate    NUMERIC(10,2) NOT NULL,      -- filled in by the trigger
    total_value  NUMERIC(12,2) NOT NULL,      -- filled in by the trigger
    delivered_on DATE NOT NULL,
    is_paid      BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE daily_purchases (
    purchase_date DATE PRIMARY KEY,
    total_weight  NUMERIC(14,2) NOT NULL,
    total_value   NUMERIC(14,2) NOT NULL
);

INSERT INTO farmers (farmer_number, full_name) VALUES
    ('F001', 'Moses Lungu'),
    ('F002', 'Naomi Chilufya'),
    ('F003', 'Oswell Kabwe');

-- The deliveries are inserted at the end of part (d), after the trigger exists.

-- ==== (b) Function: fn_maize_rate ====
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade TEXT)
RETURNS NUMERIC AS $$
BEGIN
    IF p_grade IS NULL OR p_grade NOT IN ('A', 'B', 'C') THEN
        RAISE EXCEPTION 'Unsupported grade: %', p_grade;
    END IF;

    RETURN CASE p_grade
               WHEN 'A' THEN 5.00
               WHEN 'B' THEN 4.00
               ELSE 3.00
           END;
END;
$$ LANGUAGE plpgsql;

SELECT fn_maize_rate('A'), fn_maize_rate('B'), fn_maize_rate('C');
-- SELECT fn_maize_rate('D');       -- error: unsupported grade
-- SELECT fn_maize_rate(NULL);      -- error: NULL grade

-- ==== (c) Procedure: pr_receive_delivery ====
CREATE OR REPLACE PROCEDURE pr_receive_delivery(
    p_farmer_id INTEGER, p_grade TEXT, p_weight NUMERIC, p_date DATE)
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM 1 FROM farmers WHERE farmer_id = p_farmer_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown farmer: %', p_farmer_id;
    END IF;

    PERFORM fn_maize_rate(p_grade);               -- rejects NULL / unsupported grade

    IF p_weight IS NULL OR p_weight <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive (got %)', p_weight;
    END IF;
    IF p_date IS NULL THEN
        RAISE EXCEPTION 'Delivery date must not be NULL';
    END IF;

    -- Only the basic fields: the trigger supplies unit_rate and total_value
    INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
    VALUES (p_farmer_id, p_grade, p_weight, p_date, FALSE);
END;
$$;

-- ==== (d) Trigger: consistent pricing ====
CREATE OR REPLACE FUNCTION trg_fn_price_delivery() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive (got %)', NEW.weight_kg;
    END IF;

    NEW.unit_rate   := fn_maize_rate(NEW.grade);        -- overrides any supplied value
    NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_price_delivery
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW
EXECUTE FUNCTION trg_fn_price_delivery();

-- Seed: six deliveries covering all grades and both payment states.
-- unit_rate and total_value are NOT supplied; the trigger calculates them.
INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid) VALUES
    (1, 'A', 100.00, '2026-11-18', FALSE),
    (1, 'B',  50.50, '2026-11-19', TRUE),
    (2, 'C', 200.00, '2026-11-19', FALSE),
    (2, 'A',  75.00, '2026-11-20', TRUE),
    (3, 'B', 120.00, '2026-11-20', TRUE),
    (3, 'C',  60.00, '2026-11-20', TRUE);

-- A procedure-based delivery (is_paid FALSE)
CALL pr_receive_delivery(3, 'A', 40, '2026-11-21');

SELECT * FROM deliveries ORDER BY delivery_id;

-- Direct SQL cannot bypass the pricing rule:
-- INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on)
-- VALUES (1, 'C', 10, 99, 9999, '2026-11-21');   -- stored as rate 3.00, value 30.00
-- UPDATE deliveries SET weight_kg = 0 WHERE delivery_id = 1;   -- error: trigger

-- ==== (e) View: v_farmer_amount_due ====
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT f.farmer_number,
       f.full_name,
       COALESCE(SUM(d.total_value) FILTER (WHERE NOT d.is_paid), 0) AS total_unpaid
FROM farmers f
LEFT JOIN deliveries d ON d.farmer_id = f.farmer_id
GROUP BY f.farmer_id, f.farmer_number, f.full_name;

SELECT * FROM v_farmer_amount_due ORDER BY farmer_number;

-- ==== (f) Index ====
-- Justification: the query tests farmer_id by equality and delivered_on by
-- range. Equality column first, range column second, lets the B-tree go to
-- one farmer's entries and read the date range in order.
CREATE INDEX idx_deliveries_farmer_date ON deliveries (farmer_id, delivered_on);
ANALYZE deliveries;

SET enable_seqscan = off;   -- demo only: tiny tables would otherwise use a seq scan
EXPLAIN
SELECT delivery_id, grade, weight_kg, total_value
FROM deliveries
WHERE farmer_id = 1
  AND delivered_on BETWEEN '2026-11-18' AND '2026-11-20';
RESET enable_seqscan;

-- ==== (g) Scheduled job: pr_refresh_purchases ====
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_weight NUMERIC(14,2);
    v_value  NUMERIC(14,2);
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'Day must not be NULL';
    END IF;

    SELECT COALESCE(SUM(weight_kg), 0), COALESCE(SUM(total_value), 0)
    INTO v_weight, v_value
    FROM deliveries
    WHERE delivered_on = p_day;

    -- Totals are recalculated from deliveries and replace the old row
    INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
    VALUES (p_day, v_weight, v_value)
    ON CONFLICT (purchase_date) DO UPDATE
    SET total_weight = EXCLUDED.total_weight,
        total_value  = EXCLUDED.total_value;
END;
$$;

CALL pr_refresh_purchases('2026-11-20');
CALL pr_refresh_purchases('2026-11-20');          -- rerun: replaced, not added again
SELECT * FROM daily_purchases;

-- Schedule daily at 01:30 for the previous day (pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'refresh_purchases_daily',
    '30 1 * * *',
    $$CALL pr_refresh_purchases(CURRENT_DATE - 1)$$
);
SELECT jobid, jobname, schedule, command FROM cron.job;
