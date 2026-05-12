CREATE TRIGGER "logidze_on_service_containers"
BEFORE INSERT OR UPDATE ON "service_containers"
FOR EACH ROW
WHEN (coalesce(current_setting('logidze.disabled', true), '') <> 'on')
EXECUTE PROCEDURE logidze_logger(null, 'updated_at');
