/* ============================================================
   Retail Analytics — Exploratory Analysis
   Database : itversity_retail_db (PostgreSQL 14)


   This file is read-only analysis. It is never loaded into
   Power BI — the reporting layer is built from 02_views.sql.

   NOTE ON CASTING
   order_item_subtotal is double precision. PostgreSQL's ROUND(x, n)
   only accepts numeric, so any expression derived from it must be
   cast *after* the arithmetic completes:
       ROUND( (100.0 * a / b)::numeric, 2 )   -- correct
       ROUND(  100.0 * a / b::numeric,  2 )   -- ERROR 42883
   ============================================================ */


/* ============================================================
   SECTION 0 — DATA QUALITY
   Run these before any analysis. Every finding below changed how
   the rest of this project was built.
   ============================================================ */

-- 0.1 Row counts and date coverage
SELECT
    (SELECT COUNT(*) FROM orders)        AS orders,
    (SELECT COUNT(*) FROM order_items)   AS order_items,
    (SELECT COUNT(*) FROM customers)     AS customers,
    (SELECT COUNT(*) FROM products)      AS products,
    (SELECT MIN(order_date) FROM orders) AS first_order,
    (SELECT MAX(order_date) FROM orders) AS last_order;
-- FINDING: 68,883 orders / 172,198 line items / 12,435 customers / 1,345 products.
-- Coverage runs 2013-07-25 to 2014-07-24. July 2013 and July 2014 are PARTIAL
-- months — their low revenue is a coverage artefact, not a business decline.


-- 0.2 Orphan check: line items pointing at non-existent orders
SELECT COUNT(*) AS orphan_items
FROM order_items oi
LEFT JOIN orders o ON oi.order_item_order_id = o.order_id
WHERE o.order_id IS NULL;
-- FINDING: 0. Referential integrity holds between orders and order_items.


-- 0.3 Orphan check: products pointing at non-existent categories
SELECT DISTINCT p.product_category_id
FROM products p
LEFT JOIN categories c ON p.product_category_id = c.category_id
WHERE c.category_id IS NULL
ORDER BY 1;
-- FINDING: category_id 59 is referenced by 264 products but absent from the
-- categories table (which ends at 58). Fixed in 02_views.sql by switching
-- dim_product to a LEFT JOIN so the catalogue count stays at 1,345 rather than
-- silently dropping to 1,081.


-- 0.4 Do those orphaned products actually matter?
SELECT
    COUNT(DISTINCT p.product_id)                    AS affected_products,
    ROUND(SUM(oi.order_item_subtotal)::numeric, 2)  AS revenue_affected
FROM products p
JOIN order_items oi ON p.product_id = oi.order_item_product_id
WHERE p.product_category_id = 59;
-- FINDING: zero products, zero revenue. All 264 items in the missing category
-- never sold — catalogue entries that were never launched. Impact on revenue
-- reporting: none. Impact on catalogue coverage metrics: material.


-- 0.5 Catalogue activation: how much of the catalogue actually sells?
SELECT
    COUNT(DISTINCT p.product_id)                                   AS catalogue_size,
    COUNT(DISTINCT oi.order_item_product_id)                       AS products_sold,
    ROUND(
        (100.0 * COUNT(DISTINCT oi.order_item_product_id)
              / COUNT(DISTINCT p.product_id))::numeric, 1
    )                                                              AS pct_active
FROM products p
LEFT JOIN order_items oi ON p.product_id = oi.order_item_product_id;
-- FINDING: only 100 of 1,345 products (7.4%) recorded a single sale in the full
-- year. A round 100 is not a plausible commercial outcome — transactions appear
-- to have been distributed across a fixed subset during data generation.


-- 0.6 Are customer names unique identifiers? (They are not.)
SELECT
    customer_fname || ' ' || customer_lname AS customer_name,
    COUNT(*)                                AS times_used
FROM customers
GROUP BY 1
HAVING COUNT(*) > 1
ORDER BY times_used DESC
LIMIT 10;
-- FINDING: names repeat heavily — "Mary Smith" alone appears hundreds of times.
-- Grouping revenue by name merges distinct customers and produced a phantom top
-- customer with 2,797 orders worth $1.68M; keying on customer_id corrected this
-- to $10,524 on 13 orders. ALL customer analysis must key on customer_id.
-- This single check changed the Power BI model.


-- 0.7 Geographic concentration
SELECT
    cu.customer_state,
    cu.customer_city,
    COUNT(DISTINCT cu.customer_id)                  AS customers,
    ROUND(SUM(oi.order_item_subtotal)::numeric, 2)  AS revenue,
    ROUND(
        (100.0 * SUM(oi.order_item_subtotal)
              / SUM(SUM(oi.order_item_subtotal)) OVER ())::numeric, 2
    )                                               AS pct_of_revenue
FROM customers cu
JOIN orders      o  ON cu.customer_id = o.order_customer_id
JOIN order_items oi ON o.order_id     = oi.order_item_order_id
GROUP BY 1, 2
ORDER BY revenue DESC
LIMIT 10;
-- FINDING: Caguas, Puerto Rico generates $12.1M — 37% of all revenue and 17x
-- the second city (Chicago, $719K). A city of ~100,000 cannot outsell Chicago,
-- Los Angeles and New York combined. "Caguas, PR" is the default location used
-- during data generation. Geographic analysis on this dataset is unreliable.


-- 0.8 Does subtotal agree with quantity x unit price?
SELECT
    COUNT(*) FILTER (
        WHERE ROUND((order_item_quantity * order_item_product_price)::numeric, 2)
           <> ROUND(order_item_subtotal::numeric, 2)
    ) AS mismatched_rows,
    COUNT(*) AS total_rows
FROM order_items;
-- FINDING: 0 mismatches across all 172,198 rows. order_item_subtotal is
-- internally consistent with quantity x unit price and can be trusted as the
-- revenue measure without recomputation.


-- 0.9 Order status distribution
SELECT
    order_status,
    COUNT(*)                                                      AS orders,
    ROUND((100.0 * COUNT(*) / SUM(COUNT(*)) OVER ())::numeric, 2) AS pct_of_total
FROM orders
GROUP BY 1
ORDER BY orders DESC;
-- FINDING: CANCELED and SUSPECTED_FRAUD are excluded from all revenue measures
-- via the is_valid_sale flag in bi.fact_sales. 68,883 total orders reduce to
-- ~55,000 revenue-generating orders.


/* ============================================================
   SECTION 1 — REVENUE OVERVIEW
   ============================================================ */

-- 1.1 Headline KPIs (revenue-generating orders only)
WITH order_totals AS (
    SELECT
        o.order_id,
        o.order_customer_id,
        SUM(oi.order_item_subtotal) AS order_value,
        SUM(oi.order_item_quantity) AS units
    FROM orders o
    JOIN order_items oi ON o.order_id = oi.order_item_order_id
    WHERE o.order_status NOT IN ('CANCELED', 'SUSPECTED_FRAUD')
    GROUP BY 1, 2
)
SELECT
    COUNT(*)                            AS orders,
    COUNT(DISTINCT order_customer_id)   AS customers,
    ROUND(SUM(order_value)::numeric, 2) AS revenue,
    ROUND(AVG(order_value)::numeric, 2) AS avg_order_value,
    SUM(units)                          AS units_sold
FROM order_totals;
-- FINDING: $32.86M revenue, ~55,000 orders, 12,297 active customers,
-- $598.18 average order value, ~360,000 units.
-- Note: 12,297 of 12,435 registered customers ordered — 138 never purchased.


-- 1.2 Monthly revenue with MoM growth and running total
WITH monthly AS (
    SELECT
        DATE_TRUNC('month', o.order_date)::date AS month,
        SUM(oi.order_item_subtotal)             AS revenue,
        COUNT(DISTINCT o.order_id)              AS orders
    FROM orders o
    JOIN order_items oi ON o.order_id = oi.order_item_order_id
    WHERE o.order_status NOT IN ('CANCELED', 'SUSPECTED_FRAUD')
    GROUP BY 1
)
SELECT
    month,
    ROUND(revenue::numeric, 2)                            AS revenue,
    orders,
    ROUND(LAG(revenue) OVER (ORDER BY month)::numeric, 2) AS prev_month,
    ROUND(
        (100.0 * (revenue - LAG(revenue) OVER (ORDER BY month))
              / NULLIF(LAG(revenue) OVER (ORDER BY month), 0))::numeric, 2
    )                                                     AS mom_growth_pct,
    ROUND(SUM(revenue) OVER (ORDER BY month)::numeric, 2) AS running_total
FROM monthly
ORDER BY month;
-- FINDING: revenue peaks at ~$3.0M in November 2013 (holiday season) then erodes
-- steadily through 2014 to ~$2.6M by June — roughly 13% decline over seven
-- months, with no underlying growth trend. Ignore the first and last rows:
-- both are partial months.


-- 1.3 Which weekday sells best?
SELECT
    TRIM(TO_CHAR(o.order_date, 'Day'))             AS weekday,
    EXTRACT(ISODOW FROM o.order_date)::int         AS dow,
    COUNT(DISTINCT o.order_id)                     AS orders,
    ROUND(SUM(oi.order_item_subtotal)::numeric, 2) AS revenue
FROM orders o
JOIN order_items oi ON o.order_id = oi.order_item_order_id
WHERE o.order_status NOT IN ('CANCELED', 'SUSPECTED_FRAUD')
GROUP BY 1, 2
ORDER BY dow;
-- FINDING: revenue is almost flat across the week — Monday $4.35M (lowest) to
-- Friday $4.94M (highest), a spread of only 13.5%. Saturday and Sunday are
-- indistinguishable from weekdays. Real e-commerce typically shows peak days at
-- roughly double the trough. Another synthetic-data signal.


/* ============================================================
   SECTION 2 — PRODUCT & CATEGORY PERFORMANCE
   ============================================================ */

-- 2.1 Top 10 products by revenue, with share of total
WITH product_rev AS (
    SELECT
        p.product_name,
        c.category_name,
        d.department_name,
        SUM(oi.order_item_subtotal) AS revenue,
        SUM(oi.order_item_quantity) AS units
    FROM order_items oi
    JOIN orders      o ON oi.order_item_order_id    = o.order_id
    JOIN products    p ON oi.order_item_product_id  = p.product_id
    JOIN categories  c ON p.product_category_id     = c.category_id
    JOIN departments d ON c.category_department_id  = d.department_id
    WHERE o.order_status NOT IN ('CANCELED', 'SUSPECTED_FRAUD')
    GROUP BY 1, 2, 3
)
SELECT
    product_name,
    category_name,
    department_name,
    ROUND(revenue::numeric, 2)                                  AS revenue,
    units,
    ROUND((100.0 * revenue / SUM(revenue) OVER ())::numeric, 2) AS pct_of_total,
    RANK() OVER (ORDER BY revenue DESC)                         AS revenue_rank
FROM product_rev
ORDER BY revenue DESC
LIMIT 10;
-- FINDING: Field & Stream Sportsman 16 Gun Fire Safe generates $6.64M — 21% of
-- ALL revenue from one SKU. Revenue and volume diverge sharply: the top seller
-- by units (Perfect Fitness Rip Deck, 70,575 units) earns $4.23M, while Field &
-- Stream earns 57% more from a quarter of the volume. Ranking by units would
-- have pointed inventory and marketing at the wrong product.


-- 2.2 Pareto: how concentrated is revenue?
WITH product_rev AS (
    SELECT
        p.product_name,
        SUM(oi.order_item_subtotal) AS revenue
    FROM order_items oi
    JOIN orders   o ON oi.order_item_order_id   = o.order_id
    JOIN products p ON oi.order_item_product_id = p.product_id
    WHERE o.order_status NOT IN ('CANCELED', 'SUSPECTED_FRAUD')
    GROUP BY 1
),
cumulative AS (
    SELECT
        product_name,
        revenue,
        SUM(revenue) OVER (ORDER BY revenue DESC) AS running_revenue,
        SUM(revenue) OVER ()                      AS total_revenue,
        ROW_NUMBER() OVER (ORDER BY revenue DESC) AS product_rank
    FROM product_rev
)
SELECT
    product_rank,
    product_name,
    ROUND(revenue::numeric, 2)                                   AS revenue,
    ROUND((100.0 * running_revenue / total_revenue)::numeric, 2) AS cumulative_pct
FROM cumulative
WHERE running_revenue <= total_revenue * 0.80
ORDER BY product_rank;
-- FINDING: 6 products reach 74% of revenue and the 7th crosses the 80%
-- threshold. Seven SKUs out of a 1,345-product catalogue (0.5%) generate four
-- fifths of all revenue. Even against the 100 products that actually sell, this
-- is far beyond a normal Pareto distribution.


-- 2.3 Best-selling product inside each department
WITH ranked AS (
    SELECT
        d.department_name,
        p.product_name,
        SUM(oi.order_item_subtotal) AS revenue,
        ROW_NUMBER() OVER (
            PARTITION BY d.department_name
            ORDER BY SUM(oi.order_item_subtotal) DESC
        ) AS rn
    FROM order_items oi
    JOIN orders      o ON oi.order_item_order_id   = o.order_id
    JOIN products    p ON oi.order_item_product_id = p.product_id
    JOIN categories  c ON p.product_category_id    = c.category_id
    JOIN departments d ON c.category_department_id = d.department_id
    WHERE o.order_status NOT IN ('CANCELED', 'SUSPECTED_FRAUD')
    GROUP BY 1, 2
)
SELECT department_name, product_name, ROUND(revenue::numeric, 2) AS revenue
FROM ranked
WHERE rn = 1
ORDER BY revenue DESC;
-- FINDING: Fan Shop dominates at ~$16M (roughly half of total revenue), with
-- Fitness under $1M. At category level Fishing alone reaches $6.7M (20%) —
-- essentially a single product carrying an entire category.


-- 2.4 Dead stock: products that never sold
SELECT
    p.product_id,
    p.product_name,
    COALESCE(c.category_name, 'Category 59 (missing)') AS category_name,
    p.product_price
FROM products p
LEFT JOIN categories  c  ON p.product_category_id = c.category_id
LEFT JOIN order_items oi ON p.product_id = oi.order_item_product_id
WHERE oi.order_item_id IS NULL
ORDER BY p.product_price DESC;
-- FINDING: 1,245 products (92.6% of the catalogue) never sold.


/* ============================================================
   SECTION 3 — CUSTOMER ANALYSIS
   All queries key on customer_id, never on name — see 0.6.
   ============================================================ */

-- 3.1 Top 20 customers by lifetime value
SELECT
    cu.customer_id,
    cu.customer_fname || ' ' || cu.customer_lname  AS customer_name,
    cu.customer_state,
    COUNT(DISTINCT o.order_id)                     AS orders,
    ROUND(SUM(oi.order_item_subtotal)::numeric, 2) AS lifetime_value,
    ROUND(
        (SUM(oi.order_item_subtotal) / COUNT(DISTINCT o.order_id))::numeric, 2
    )                                              AS avg_order_value
FROM customers cu
JOIN orders      o  ON cu.customer_id = o.order_customer_id
JOIN order_items oi ON o.order_id     = oi.order_item_order_id
WHERE o.order_status NOT IN ('CANCELED', 'SUSPECTED_FRAUD')
GROUP BY 1, 2, 3
ORDER BY lifetime_value DESC
LIMIT 20;
-- FINDING: top customer reaches $10,524 on 13 orders. The top 20 cluster
-- tightly between $8.5K and $10.5K on 11-15 orders each, with no long tail of
-- high-value outliers. Real customer bases are far more skewed.


-- 3.2 Revenue by state
SELECT
    cu.customer_state,
    COUNT(DISTINCT cu.customer_id)                  AS customers,
    COUNT(DISTINCT o.order_id)                      AS orders,
    ROUND(SUM(oi.order_item_subtotal)::numeric, 2)  AS revenue,
    ROUND(
        (100.0 * SUM(oi.order_item_subtotal)
              / SUM(SUM(oi.order_item_subtotal)) OVER ())::numeric, 2
    )                                               AS pct_of_revenue,
    RANK() OVER (ORDER BY SUM(oi.order_item_subtotal) DESC) AS state_rank
FROM customers cu
JOIN orders      o  ON cu.customer_id = o.order_customer_id
JOIN order_items oi ON o.order_id     = oi.order_item_order_id
WHERE o.order_status NOT IN ('CANCELED', 'SUSPECTED_FRAUD')
GROUP BY 1
ORDER BY revenue DESC;
-- FINDING: Puerto Rico leads with ~$13M, more than double California, despite
-- having 8% of its population. See 0.7 — this is a generation artefact.


-- 3.3 RFM segmentation using NTILE
WITH snapshot AS (
    SELECT MAX(order_date)::date AS as_of FROM orders
),
customer_rfm AS (
    SELECT
        cu.customer_id,
        cu.customer_fname || ' ' || cu.customer_lname          AS customer_name,
        (SELECT as_of FROM snapshot) - MAX(o.order_date)::date AS recency_days,
        COUNT(DISTINCT o.order_id)                             AS frequency,
        SUM(oi.order_item_subtotal)                            AS monetary
    FROM customers cu
    JOIN orders      o  ON cu.customer_id = o.order_customer_id
    JOIN order_items oi ON o.order_id     = oi.order_item_order_id
    WHERE o.order_status NOT IN ('CANCELED', 'SUSPECTED_FRAUD')
    GROUP BY 1, 2
),
scored AS (
    SELECT
        *,
        NTILE(5) OVER (ORDER BY recency_days DESC) AS r_score,
        NTILE(5) OVER (ORDER BY frequency)         AS f_score,
        NTILE(5) OVER (ORDER BY monetary)          AS m_score
    FROM customer_rfm
)
SELECT
    customer_id,
    customer_name,
    recency_days,
    frequency,
    ROUND(monetary::numeric, 2) AS monetary,
    r_score, f_score, m_score,
    CASE
        WHEN r_score >= 4 AND f_score >= 4 THEN 'Champions'
        WHEN r_score >= 3 AND f_score >= 3 THEN 'Loyal'
        WHEN r_score >= 4 AND f_score <= 2 THEN 'New / Promising'
        WHEN r_score <= 2 AND f_score >= 4 THEN 'At Risk'
        WHEN r_score <= 2 AND f_score <= 2 THEN 'Hibernating'
        ELSE 'Needs Attention'
    END AS segment
FROM scored
ORDER BY monetary DESC
LIMIT 50;
-- FINDING: NTILE forces equal-sized quintiles, so segment counts describe
-- relative position rather than absolute health. Given the flat retention curve
-- in 3.4 and the tight clustering in 3.1, the R/F/M spread here is narrow and
-- the segments carry little real discriminating power on this dataset.


-- 3.4 Monthly cohort retention
WITH first_order AS (
    SELECT
        order_customer_id,
        DATE_TRUNC('month', MIN(order_date))::date AS cohort_month
    FROM orders
    WHERE order_status NOT IN ('CANCELED', 'SUSPECTED_FRAUD')
    GROUP BY 1
),
activity AS (
    SELECT DISTINCT
        f.order_customer_id,
        f.cohort_month,
        DATE_TRUNC('month', o.order_date)::date AS activity_month
    FROM first_order f
    JOIN orders o ON f.order_customer_id = o.order_customer_id
    WHERE o.order_status NOT IN ('CANCELED', 'SUSPECTED_FRAUD')
),
sized AS (
    SELECT
        cohort_month,
        activity_month,
        (EXTRACT(YEAR  FROM AGE(activity_month, cohort_month)) * 12
       + EXTRACT(MONTH FROM AGE(activity_month, cohort_month)))::int AS month_number,
        COUNT(DISTINCT order_customer_id) AS active_customers
    FROM activity
    GROUP BY 1, 2, 3
)
SELECT
    cohort_month,
    month_number,
    active_customers,
    FIRST_VALUE(active_customers) OVER (
        PARTITION BY cohort_month ORDER BY month_number
    ) AS cohort_size,
    ROUND(
        (100.0 * active_customers / FIRST_VALUE(active_customers) OVER (
            PARTITION BY cohort_month ORDER BY month_number
        ))::numeric, 2
    ) AS retention_pct
FROM sized
ORDER BY cohort_month, month_number;
-- FINDING: the July 2013 cohort (1,424 customers) drops to 35.9% in month 1,
-- then holds between 33% and 38% for twelve consecutive months, ending at 28.2%.
-- Real cohorts decay steeply and continuously (roughly 35% -> 20% -> 12% -> 8%).
-- A curve this flat means repeat purchasing was distributed at random rather
-- than driven by customer behaviour. This is the single clearest synthetic
-- signal in the dataset.


-- 3.5 One-time vs repeat buyers
WITH per_customer AS (
    SELECT
        order_customer_id,
        COUNT(DISTINCT order_id) AS orders
    FROM orders
    WHERE order_status NOT IN ('CANCELED', 'SUSPECTED_FRAUD')
    GROUP BY 1
)
SELECT
    CASE WHEN orders = 1 THEN 'One-time' ELSE 'Repeat' END        AS buyer_type,
    COUNT(*)                                                      AS customers,
    ROUND((100.0 * COUNT(*) / SUM(COUNT(*)) OVER ())::numeric, 2) AS pct
FROM per_customer
GROUP BY 1;
-- FINDING: 94.7% repeat rate. Typical e-commerce sits between 20% and 40%.
-- This is not a business achievement to report — it is evidence that purchase
-- behaviour was randomly distributed across the customer base.


/* ============================================================
   SECTION 4 — OPERATIONAL HEALTH
   ============================================================ */

-- 4.1 Revenue at risk by status
SELECT
    o.order_status,
    COUNT(DISTINCT o.order_id)                     AS orders,
    ROUND(SUM(oi.order_item_subtotal)::numeric, 2) AS value_at_risk
FROM orders o
JOIN order_items oi ON o.order_id = oi.order_item_order_id
WHERE o.order_status IN ('CANCELED', 'SUSPECTED_FRAUD', 'PAYMENT_REVIEW', 'ON_HOLD')
GROUP BY 1
ORDER BY value_at_risk DESC;


-- 4.2 Is the problem rate trending?
SELECT
    DATE_TRUNC('month', order_date)::date AS month,
    COUNT(*)                              AS total_orders,
    COUNT(*) FILTER (
        WHERE order_status IN ('CANCELED', 'SUSPECTED_FRAUD')
    )                                     AS problem_orders,
    ROUND(
        (100.0 * COUNT(*) FILTER (
            WHERE order_status IN ('CANCELED', 'SUSPECTED_FRAUD')
        ) / COUNT(*))::numeric, 2
    )                                     AS problem_rate_pct
FROM orders
GROUP BY 1
ORDER BY month;


-- 4.3 Basket size distribution
WITH basket AS (
    SELECT
        order_item_order_id,
        COUNT(*)                 AS line_items,
        SUM(order_item_quantity) AS units,
        SUM(order_item_subtotal) AS order_value
    FROM order_items
    GROUP BY 1
)
SELECT
    line_items,
    COUNT(*)                            AS orders,
    ROUND(AVG(order_value)::numeric, 2) AS avg_order_value
FROM basket
GROUP BY 1
ORDER BY line_items;


-- 4.4 Market basket: product pairs bought together
SELECT
    p1.product_name AS product_a,
    p2.product_name AS product_b,
    COUNT(*)        AS times_bought_together
FROM order_items a
JOIN order_items b
      ON a.order_item_order_id    = b.order_item_order_id
     AND a.order_item_product_id  < b.order_item_product_id
JOIN products p1 ON a.order_item_product_id = p1.product_id
JOIN products p2 ON b.order_item_product_id = p2.product_id
GROUP BY 1, 2
HAVING COUNT(*) > 500
ORDER BY times_bought_together DESC
LIMIT 20;
-- FINDING: with only 100 active products, co-occurrence counts will be high
-- across the board. Check whether any pair stands out above the baseline — if
-- all pairs occur at similar rates, there are no genuine affinities to act on.
