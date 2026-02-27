-- MySQL seed data for sql-nio integration tests
-- Run against MySQLNioTestDb before executing MySQLNioTests

-- ─── Schema ───────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS departments (
    id      INT AUTO_INCREMENT PRIMARY KEY,
    name    VARCHAR(100) NOT NULL,
    budget  DECIMAL(12,2) DEFAULT 0.00,
    active  TINYINT(1)   DEFAULT 1
);

CREATE TABLE IF NOT EXISTS employees (
    id            INT AUTO_INCREMENT PRIMARY KEY,
    department_id INT          NOT NULL,
    name          VARCHAR(100) NOT NULL,
    email         VARCHAR(150) NOT NULL UNIQUE,
    salary        DECIMAL(10,2) DEFAULT 0.00,
    is_manager    TINYINT(1)   DEFAULT 0,
    FOREIGN KEY (department_id) REFERENCES departments(id)
);

CREATE TABLE IF NOT EXISTS type_samples (
    id          INT AUTO_INCREMENT PRIMARY KEY,
    col_bool    TINYINT(1),
    col_tinyint TINYINT,
    col_smallint SMALLINT,
    col_int     INT,
    col_bigint  BIGINT,
    col_float   FLOAT,
    col_double  DOUBLE,
    col_decimal DECIMAL(12,5),
    col_varchar VARCHAR(100),
    col_text    TEXT,
    col_date    DATE,
    col_datetime DATETIME
);

CREATE TABLE IF NOT EXISTS products (
    id     INT AUTO_INCREMENT PRIMARY KEY,
    name   VARCHAR(100) NOT NULL,
    price  DECIMAL(10,2) DEFAULT 0.00,
    active TINYINT(1)   DEFAULT 1
);

CREATE TABLE IF NOT EXISTS orders (
    id           INT AUTO_INCREMENT PRIMARY KEY,
    employee_id  INT NOT NULL,
    total_amount DECIMAL(10,2) DEFAULT 0.00,
    FOREIGN KEY (employee_id) REFERENCES employees(id)
);

CREATE TABLE IF NOT EXISTS order_items (
    id       INT AUTO_INCREMENT PRIMARY KEY,
    order_id INT NOT NULL,
    product_id INT NOT NULL,
    quantity INT DEFAULT 1,
    FOREIGN KEY (order_id) REFERENCES orders(id),
    FOREIGN KEY (product_id) REFERENCES products(id)
);

-- ─── Seed data ────────────────────────────────────────────────────────────────

INSERT INTO departments (name, budget, active) VALUES
    ('Engineering',  1500000.00, 1),
    ('Marketing',    200000.00, 1),
    ('Sales',        350000.00, 1),
    ('HR',           150000.00, 1),
    ('Operations',   250000.00, 1);

-- 8 employees: 3 in Engineering (dept=1), 1 or 2 in each other dept
-- Alice Johnson is alphabetically first in dept=1 and has the highest salary overall
INSERT INTO employees (department_id, name, email, salary, is_manager) VALUES
    (1, 'Alice Johnson',   'alice@example.com',   120000.00, 1),
    (1, 'Bob Smith',       'bob@example.com',      95000.00, 0),
    (1, 'Charlie Brown',   'charlie@example.com',  88000.00, 0),
    (2, 'Diana Prince',    'diana@example.com',    75000.00, 1),
    (2, 'Eve Adams',       'eve@example.com',      72000.00, 0),
    (3, 'Frank Castle',    'frank@example.com',    80000.00, 0),
    (4, 'Grace Hopper',    'grace@example.com',    70000.00, 0),
    (5, 'Hank Pym',        'hank@example.com',     85000.00, 0);

INSERT INTO type_samples (col_bool, col_tinyint, col_smallint, col_int, col_bigint,
    col_float, col_double, col_decimal, col_varchar, col_text, col_date, col_datetime)
VALUES (1, 127, 32767, 2147483647, 9223372036854775807,
    3.14, 2.718281828, 99999.99999, 'VarChar Value', 'Hello MySQL',
    '2025-06-15', '2025-06-15 10:30:00');

INSERT INTO products (name, price, active) VALUES
    ('Widget A',      9.99,  1),
    ('Widget B',     14.99,  1),
    ('Gadget Pro',   49.99,  1),
    ('Gadget Lite',  29.99,  1),
    ('SuperTool',    99.99,  1),
    ('Discontinued', 0.01,   0);

INSERT INTO orders (employee_id, total_amount) VALUES
    (1, 150.00),
    (2,  49.99),
    (3, 299.97);

INSERT INTO order_items (order_id, product_id, quantity) VALUES
    (1, 1, 5),
    (1, 3, 1),
    (2, 3, 1),
    (3, 5, 3);

-- ─── Stored procedures ────────────────────────────────────────────────────────

DELIMITER $$

CREATE PROCEDURE add_numbers(IN a INT, IN b INT, OUT result INT)
BEGIN
    SET result = a + b;
END$$

CREATE PROCEDURE get_department_budget(IN dept_id INT, OUT budget DECIMAL(12,2))
BEGIN
    SELECT d.budget INTO budget FROM departments d WHERE d.id = dept_id;
END$$

CREATE PROCEDURE get_employee_count(IN dept_id INT, OUT cnt INT)
BEGIN
    SELECT COUNT(*) INTO cnt FROM employees WHERE department_id = dept_id;
END$$

DELIMITER ;
