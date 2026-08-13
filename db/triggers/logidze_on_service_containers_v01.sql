CREATE TRIGGER "logidze_on_service_containers"
BEFORE INSERT OR UPDATE ON "service_containers"
FOR EACH ROW
WHEN (coalesce(current_setting('logidze.disabled', true), '') <> 'on')
-- Exclude secrets and high-churn metric summaries so log_data only captures
-- audit-relevant configuration changes.
EXECUTE PROCEDURE logidze_logger(
  null,
  'updated_at',
  '{env,status,docker_container_id,peak_cpu_percent,peak_memory_bytes,avg_cpu_percent,avg_memory_bytes,container_metrics_count}'
);
