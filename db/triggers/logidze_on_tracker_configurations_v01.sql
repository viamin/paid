CREATE TRIGGER "logidze_on_tracker_configurations"
BEFORE INSERT OR UPDATE ON "tracker_configurations"
FOR EACH ROW
WHEN (coalesce(current_setting('logidze.disabled', true), '') <> 'on')
EXECUTE PROCEDURE logidze_logger(null, 'updated_at');
