CREATE TRIGGER "logidze_on_service_containers"
BEFORE INSERT OR UPDATE ON "service_containers"
FOR EACH ROW
WHEN (coalesce(current_setting('logidze.disabled', true), '') <> 'on')
-- Exclude env column to prevent passwords/secrets persisting in log_data
EXECUTE PROCEDURE logidze_logger(null, 'updated_at', '{env}');
