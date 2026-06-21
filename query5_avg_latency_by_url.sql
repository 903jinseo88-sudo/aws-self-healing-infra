SELECT
    request_url,
    COUNT(*) AS request_count,
    ROUND(AVG(target_processing_time), 4) AS avg_latency_sec,
    ROUND(MAX(target_processing_time), 4) AS max_latency_sec
FROM alb_logs
GROUP BY request_url
ORDER BY avg_latency_sec DESC
LIMIT 10
