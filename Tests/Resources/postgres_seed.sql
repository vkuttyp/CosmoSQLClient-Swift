-- PostgreSQL seed data for sql-nio integration tests
-- Run against PostgresNioTestDb before executing PostgresNioTests
-- Idempotent: drops all objects before recreating

-- ─── Drop existing objects ────────────────────────────────────────────────────

DROP TABLE IF EXISTS order_items CASCADE;
DROP TABLE IF EXISTS orders CASCADE;
DROP TABLE IF EXISTS type_samples CASCADE;
DROP TABLE IF EXISTS employees CASCADE;
DROP TABLE IF EXISTS products CASCADE;
DROP TABLE IF EXISTS departments CASCADE;
DROP FUNCTION IF EXISTS add_numbers(INTEGER, INTEGER);
DROP FUNCTION IF EXISTS get_department_budget(INTEGER);
DROP FUNCTION IF EXISTS get_employee_count(INTEGER);

-- ─── Schema ───────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS departments (
    id     SERIAL PRIMARY KEY,
    name   TEXT          NOT NULL,
    budget NUMERIC(12,2) DEFAULT 0,
    active BOOLEAN       DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS employees (
    id            SERIAL PRIMARY KEY,
    department_id INT  NOT NULL REFERENCES departments(id),
    name          TEXT NOT NULL,
    email         TEXT UNIQUE,
    salary        NUMERIC(10,2) DEFAULT 0,
    is_manager    BOOLEAN       DEFAULT FALSE
);

CREATE TABLE IF NOT EXISTS type_samples (
    id          SERIAL PRIMARY KEY,
    col_bool    BOOLEAN,
    col_int2    SMALLINT,
    col_int4    INTEGER,
    col_int8    BIGINT,
    col_float4  REAL,
    col_float8  DOUBLE PRECISION,
    col_numeric NUMERIC(14,4),
    col_text    TEXT,
    col_varchar VARCHAR(100),
    col_date    DATE,
    col_ts      TIMESTAMP,
    col_uuid    UUID
);

CREATE TABLE IF NOT EXISTS products (
    id     SERIAL PRIMARY KEY,
    name   TEXT          NOT NULL,
    price  NUMERIC(10,2) DEFAULT 0,
    active BOOLEAN       DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS orders (
    id           SERIAL PRIMARY KEY,
    employee_id  INT NOT NULL REFERENCES employees(id),
    total_amount NUMERIC(10,2) DEFAULT 0
);

CREATE TABLE IF NOT EXISTS order_items (
    id         SERIAL PRIMARY KEY,
    order_id   INT NOT NULL REFERENCES orders(id),
    product_id INT NOT NULL REFERENCES products(id),
    quantity   INT DEFAULT 1
);

-- ─── Seed data ────────────────────────────────────────────────────────────────

INSERT INTO departments (name, budget, active) VALUES
    ('Engineering',  1500000.00, TRUE),
    ('Marketing',    200000.00, TRUE),
    ('Sales',        350000.00, TRUE),
    ('HR',           150000.00, TRUE),
    ('Operations',   250000.00, TRUE);

-- 8 employees: 3 in Engineering (id=1), others distributed
-- Alice Johnson is alphabetically first in dept=1 and highest paid overall
INSERT INTO employees (department_id, name, email, salary, is_manager) VALUES
    (1, 'Alice Johnson',   'alice@example.com',   120000.00, TRUE),
    (1, 'Bob Smith',       'bob@example.com',      95000.00, FALSE),
    (1, 'Charlie Brown',   'charlie@example.com',  88000.00, FALSE),
    (2, 'Diana Prince',    'diana@example.com',    75000.00, TRUE),
    (2, 'Eve Adams',       'eve@example.com',      72000.00, FALSE),
    (3, 'Frank Castle',    'frank@example.com',    80000.00, FALSE),
    (4, 'Grace Hopper',    'grace@example.com',    70000.00, FALSE),
    (5, 'Hank Pym',        'hank@example.com',     85000.00, FALSE);

INSERT INTO type_samples (col_bool, col_int2, col_int4, col_int8,
    col_float4, col_float8, col_numeric, col_text, col_varchar,
    col_date, col_ts, col_uuid)
VALUES (TRUE, 32767, 2147483647, 9223372036854775807,
    3.14, 2.718281828, 99999.9999, 'Hello PostgreSQL', 'VarChar Value',
    '2025-06-15', '2025-06-15 10:30:00',
    'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11');

INSERT INTO products (name, price, active) VALUES
    ('Widget A',      9.99,  TRUE),
    ('Widget B',     14.99,  TRUE),
    ('Gadget Pro',   49.99,  TRUE),
    ('Gadget Lite',  29.99,  TRUE),
    ('SuperTool',    99.99,  TRUE),
    ('Discontinued',  0.01,  FALSE);

INSERT INTO orders (employee_id, total_amount) VALUES
    (1, 150.00),
    (2,  49.99),
    (3, 299.97);

INSERT INTO order_items (order_id, product_id, quantity) VALUES
    (1, 1, 5),
    (1, 3, 1),
    (2, 3, 1),
    (3, 5, 3);

-- ─── Functions ────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION add_numbers(a INTEGER, b INTEGER) RETURNS INTEGER AS $$
BEGIN
    RETURN a + b;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION get_department_budget(dept_id INTEGER) RETURNS NUMERIC AS $$
DECLARE
    result NUMERIC;
BEGIN
    SELECT budget INTO result FROM departments WHERE id = dept_id;
    RETURN result;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION get_employee_count(dept_id INTEGER) RETURNS INTEGER AS $$
DECLARE
    cnt INTEGER;
BEGIN
    SELECT COUNT(*) INTO cnt FROM employees WHERE department_id = dept_id;
    RETURN cnt;
END;
$$ LANGUAGE plpgsql;
