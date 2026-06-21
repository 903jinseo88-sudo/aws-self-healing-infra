SELECT
    client_ip,
    user_agent,
    COUNT(*) AS request_count
FROM alb_logs
GROUP BY client_ip, user_agent
ORDER BY request_count DESC
LIMIT 10
