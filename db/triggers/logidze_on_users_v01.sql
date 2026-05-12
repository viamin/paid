CREATE TRIGGER "logidze_on_users"
BEFORE INSERT OR UPDATE ON "users"
FOR EACH ROW
WHEN (coalesce(current_setting('logidze.disabled', true), '') <> 'on')
EXECUTE PROCEDURE logidze_logger(null, 'updated_at');
