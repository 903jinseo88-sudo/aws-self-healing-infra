SELECT
    date_trunc('hour', date_parse(time, '%Y-%m-%dT%H:%i:%s.%fZ')) AS hour,
    COUNT(*) AS total_requests,
    SUM(CASE WHEN elb_status_code >= 500 THEN 1 ELSE 0 END) AS error_5xx_count,
    ROUND(100.0 * SUM(CASE WHEN elb_status_code >= 500 THEN 1 ELSE 0 END) / COUNT(*), 2) AS error_rate_pct
FROM alb_logs
GROUP BY 1
ORDER BY 1 DESC
