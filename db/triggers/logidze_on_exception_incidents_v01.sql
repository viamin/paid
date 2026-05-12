CREATE TRIGGER "logidze_on_exception_incidents"
BEFORE INSERT OR UPDATE ON "exception_incidents"
FOR EACH ROW
WHEN (coalesce(current_setting('logidze.disabled', true), '') <> 'on')
EXECUTE PROCEDURE logidze_logger(null, 'updated_at');
