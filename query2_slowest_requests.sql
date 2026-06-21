SELECT
    time,
    client_ip,
    request_url,
    target_processing_time,
    elb_status_code
FROM alb_logs
ORDER BY target_processing_time DESC
LIMIT 10
