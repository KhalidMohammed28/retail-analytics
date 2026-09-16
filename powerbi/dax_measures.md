# DAX Measures — Retail Analytics

Create a blank table called `_Measures` (Home → Enter Data → name it `_Measures` → Load), then add every measure below to it. Hide its dummy column. This keeps measures separate from the data tables.

## Model relationships

Build these in Model view, all one-to-many, single direction, with `fact_sales` on the many side:

| From | To |
|---|---|
| `dim_date[date_key]` | `fact_sales[order_date]` |
| `dim_customer[customer_id]` | `fact_sales[customer_id]` |
| `dim_product[product_id]` | `fact_sales[product_id]` |
| `dim_order_status[order_status]` | `fact_sales[order_status]` |

Mark `dim_date` as a date table: select it → Table tools → Mark as date table → `date_key`.

---

## Core measures

```dax
Total Revenue =
CALCULATE(
    SUM( fact_sales[revenue] ),
    fact_sales[is_valid_sale] = TRUE
)
```

```dax
Total Orders =
CALCULATE(
    DISTINCTCOUNT( fact_sales[order_id] ),
    fact_sales[is_valid_sale] = TRUE
)
```

```dax
Units Sold =
CALCULATE(
    SUM( fact_sales[quantity] ),
    fact_sales[is_valid_sale] = TRUE
)
```

```dax
Active Customers =
CALCULATE(
    DISTINCTCOUNT( fact_sales[customer_id] ),
    fact_sales[is_valid_sale] = TRUE
)
```

```dax
Average Order Value =
DIVIDE( [Total Revenue], [Total Orders] )
```

```dax
Revenue per Customer =
DIVIDE( [Total Revenue], [Active Customers] )
```

---

## Share and ranking

```dax
Revenue % of Total =
DIVIDE(
    [Total Revenue],
    CALCULATE( [Total Revenue], REMOVEFILTERS() )
)
```

```dax
Revenue % of Department =
DIVIDE(
    [Total Revenue],
    CALCULATE( [Total Revenue], REMOVEFILTERS( dim_product[category_name], dim_product[product_name] ) )
)
```

```dax
Product Rank =
RANKX(
    ALLSELECTED( dim_product[product_name] ),
    [Total Revenue],
    ,
    DESC,
    DENSE
)
```

---

## Time intelligence

Requires `dim_date` marked as a date table.

```dax
Revenue LY =
CALCULATE( [Total Revenue], SAMEPERIODLASTYEAR( dim_date[date_key] ) )
```

```dax
Revenue YoY % =
DIVIDE( [Total Revenue] - [Revenue LY], [Revenue LY] )
```

```dax
Revenue PM =
CALCULATE( [Total Revenue], DATEADD( dim_date[date_key], -1, MONTH ) )
```

```dax
Revenue MoM % =
DIVIDE( [Total Revenue] - [Revenue PM], [Revenue PM] )
```

```dax
Revenue YTD =
TOTALYTD( [Total Revenue], dim_date[date_key] )
```

```dax
Revenue 3M Moving Avg =
AVERAGEX(
    DATESINPERIOD( dim_date[date_key], MAX( dim_date[date_key] ), -3, MONTH ),
    [Total Revenue]
)
```

---

## Operational quality

```dax
Lost Revenue =
CALCULATE(
    SUM( fact_sales[revenue] ),
    fact_sales[is_valid_sale] = FALSE
)
```

```dax
Cancellation Rate =
VAR CancelledOrders =
    CALCULATE(
        DISTINCTCOUNT( fact_sales[order_id] ),
        fact_sales[is_valid_sale] = FALSE
    )
VAR AllOrders = DISTINCTCOUNT( fact_sales[order_id] )
RETURN
    DIVIDE( CancelledOrders, AllOrders )
```

```dax
Orders Pending Payment =
CALCULATE(
    DISTINCTCOUNT( fact_sales[order_id] ),
    dim_order_status[status_group] = "Awaiting Payment"
)
```

---

## Customer behaviour

```dax
Repeat Customers =
VAR CustomerOrders =
    ADDCOLUMNS(
        VALUES( fact_sales[customer_id] ),
        "@Orders",
        CALCULATE( DISTINCTCOUNT( fact_sales[order_id] ), fact_sales[is_valid_sale] = TRUE )
    )
RETURN
    COUNTROWS( FILTER( CustomerOrders, [@Orders] > 1 ) )
```

```dax
Repeat Rate =
DIVIDE( [Repeat Customers], [Active Customers] )
```

```dax
Avg Basket Size =
DIVIDE( [Units Sold], [Total Orders] )
```

---

## Dynamic title (nice touch for the report header)

```dax
Report Title =
VAR SelectedDept =
    IF(
        ISFILTERED( dim_product[department_name] ),
        CONCATENATEX( VALUES( dim_product[department_name] ), dim_product[department_name], ", " ),
        "All Departments"
    )
VAR Period =
    MIN( dim_date[year_month] ) & " to " & MAX( dim_date[year_month] )
RETURN
    "Sales Performance — " & SelectedDept & "  |  " & Period
```

Place a Card visual at the top of each page bound to this measure.

---

## Formatting

Set these once per measure in the Measure tools ribbon:

- Revenue measures → Currency, 0 decimals, thousands separator
- Percentage measures → Percentage, 1 decimal
- Count measures → Whole number, thousands separator
