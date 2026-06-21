SELECT
    CASE
        WHEN elb_status_code BETWEEN 400 AND 499 THEN '4xx'
        WHEN elb_status_code BETWEEN 500 AND 599 THEN '5xx'
        WHEN elb_status_code BETWEEN 200 AND 299 THEN '2xx'
        ELSE 'other'
    END AS status_category,
    COUNT(*) AS count
FROM alb_logs
GROUP BY 1
ORDER BY count DESC
