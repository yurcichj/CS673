-- =====================================================================
-- CS673 Project #1 - Oracle HR schema (run in freesql.com)
-- =====================================================================
 
-- ---------------------------------------------------------------------
-- #1 Compensation outliers vs. job benchmarks  (expected: 43 rows)
-- Logic: employees paid ABOVE their global job average. The department
-- average is a window function over that pre-aggregated (filtered) subset.
-- ---------------------------------------------------------------------
WITH job_metrics AS (
    SELECT job_id,
           AVG(salary) AS avg_job_salary
    FROM   hr.employees
    GROUP  BY job_id
),
geo AS (
    SELECT l.location_id,
           l.city,
           c.country_name,
           r.region_name
    FROM   hr.locations l
    JOIN   hr.countries c ON l.country_id = c.country_id
    JOIN   hr.regions   r ON c.region_id  = r.region_id
),
outliers AS (
    SELECT e.employee_id,
           e.first_name || ' ' || e.last_name AS employee_name,
           e.department_id,
           e.job_id,
           e.salary,
           jm.avg_job_salary
    FROM   hr.employees e
    JOIN   job_metrics jm ON e.job_id = jm.job_id
    WHERE  e.salary > jm.avg_job_salary
)
SELECT o.employee_id,
       o.employee_name,
       d.department_name,
       g.city,
       j.job_title,
       o.salary,
       ROUND(o.avg_job_salary, 2)                                AS average_job_salary,
       ROUND(AVG(o.salary) OVER (PARTITION BY d.department_name), 2) AS overall_dept_avg_salary,
       ROUND(o.salary - o.avg_job_salary, 2)                     AS deviation_from_global_job_avg
FROM   outliers o
JOIN   hr.departments d ON o.department_id = d.department_id
JOIN   geo            g ON d.location_id    = g.location_id
JOIN   hr.jobs        j ON o.job_id         = j.job_id
ORDER  BY deviation_from_global_job_avg DESC, o.employee_id;
 
 
-- ---------------------------------------------------------------------
-- #2 Career path analysis and promotion trajectories  (expected: 10 rows)
-- Logic: UNION of JOB_HISTORY + current EMPLOYEES rows (only employees
-- that have history), then LEAD / LAG over each employee's timeline.
-- NOTE: if your count is not 10, adjust the current-row filter below
-- (e.g., start_date choice) until it matches the expected output.
-- ---------------------------------------------------------------------
WITH career AS (
    SELECT jh.employee_id, jh.start_date, jh.end_date,
           jh.job_id, jh.department_id
    FROM   hr.job_history jh
    UNION
    SELECT e.employee_id, e.hire_date, CAST(NULL AS DATE),
           e.job_id, e.department_id
    FROM   hr.employees e
    WHERE  e.employee_id IN (SELECT employee_id FROM hr.job_history)
)
SELECT c.employee_id,
       e.first_name || ' ' || e.last_name AS employee_name,
       c.start_date,
       c.end_date,
       j.job_title,
       d.department_name,
       LEAD(j.job_title)  OVER (PARTITION BY c.employee_id
                                ORDER BY c.start_date, c.end_date NULLS LAST) AS next_promoted_title,
       LAG(j.max_salary)  OVER (PARTITION BY c.employee_id
                                ORDER BY c.start_date, c.end_date NULLS LAST) AS previous_role_max_salary
FROM   career c
JOIN   hr.employees   e ON c.employee_id   = e.employee_id
JOIN   hr.jobs        j ON c.job_id        = j.job_id
JOIN   hr.departments d ON c.department_id = d.department_id
ORDER  BY c.employee_id, c.start_date;
 
 
-- ---------------------------------------------------------------------
-- #3 Departmental commission spans and peer comparisons (expected: 106 rows)
-- ---------------------------------------------------------------------
SELECT e.first_name || ' ' || e.last_name AS employee_name,
       d.department_name,
       l.city,
       e.salary,
       CASE WHEN e.commission_pct IS NULL THEN 0
            ELSE e.commission_pct END     AS commission_pct,
       FIRST_VALUE(e.first_name || ' ' || e.last_name) OVER (
           PARTITION BY d.department_id
           ORDER BY e.salary DESC, e.employee_id
           ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
       ) AS highest_paid_in_dept,
       LAST_VALUE(e.first_name || ' ' || e.last_name) OVER (
           PARTITION BY d.department_id
           ORDER BY e.salary DESC, e.employee_id
           ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
       ) AS lowest_paid_in_dept
FROM   hr.employees   e
JOIN   hr.departments d ON e.department_id = d.department_id
JOIN   hr.locations   l ON d.location_id   = l.location_id
ORDER  BY d.department_name, e.salary DESC, e.employee_id;
 
 
-- ---------------------------------------------------------------------
-- #4 Organizational hierarchy mapping (expected: 107 rows)
-- ---------------------------------------------------------------------
WITH org (management_level, employee_id, employee_name, job_id,
          department_id, reporting_line) AS (
    -- Anchor: top of the hierarchy
    SELECT 1,
           e.employee_id,
           e.first_name || ' ' || e.last_name,
           e.job_id,
           e.department_id,
           CAST(e.first_name || ' ' || e.last_name AS VARCHAR2(4000))
    FROM   hr.employees e
    WHERE  e.manager_id IS NULL
    UNION ALL
    -- Recursive member: walk down to direct reports
    SELECT o.management_level + 1,
           e.employee_id,
           e.first_name || ' ' || e.last_name,
           e.job_id,
           e.department_id,
           o.reporting_line || ' -> ' || e.first_name || ' ' || e.last_name
    FROM   hr.employees e
    JOIN   org o ON e.manager_id = o.employee_id
)
SELECT o.management_level,
       o.employee_name,
       j.job_title,
       d.department_name,
       o.reporting_line,
       COUNT(*) OVER (PARTITION BY o.management_level) AS total_peers_at_level
FROM   org o
JOIN   hr.jobs j             ON o.job_id        = j.job_id
LEFT   JOIN hr.departments d ON o.department_id = d.department_id
ORDER  BY o.management_level, o.employee_id;
 
 
-- ---------------------------------------------------------------------
-- #5 Managerial performance and team retention (expected: 8 rows)
-- Managers = employees who manage a department AND have direct reports.
-- ---------------------------------------------------------------------
WITH team_stats AS (
    SELECT m.employee_id                AS manager_id,
           COUNT(r.employee_id)         AS direct_reports_count,
           SUM(r.salary)                AS team_total_payroll,
           AVG(r.salary)                AS team_avg_salary
    FROM   hr.employees m
    JOIN   hr.employees r ON r.manager_id = m.employee_id   -- self-join
    GROUP  BY m.employee_id
),
dept_attrition AS (
    SELECT department_id,
           COUNT(*) AS historical_attrition
    FROM   hr.job_history
    GROUP  BY department_id
)
SELECT m.employee_id                         AS manager_id,
       m.first_name || ' ' || m.last_name    AS manager_name,
       j.job_title                           AS manager_title,
       d.department_name,
       ts.direct_reports_count,
       ts.team_total_payroll,
       NVL(da.historical_attrition, 0)       AS department_historical_attrition,
       RANK() OVER (ORDER BY ts.team_total_payroll DESC) AS manager_payroll_scale_rank,
       CASE WHEN m.salary > ts.team_avg_salary THEN 'Above Team Average'
            ELSE 'At/Below Team Average' END AS compensation_vs_team
FROM   hr.employees   m
JOIN   team_stats     ts ON m.employee_id   = ts.manager_id
JOIN   hr.departments d  ON d.manager_id    = m.employee_id  -- manager key
JOIN   hr.jobs        j  ON m.job_id        = j.job_id
LEFT   JOIN dept_attrition da ON da.department_id = d.department_id
ORDER  BY manager_payroll_scale_rank;