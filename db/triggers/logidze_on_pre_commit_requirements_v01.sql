CREATE TRIGGER "logidze_on_pre_commit_requirements"
BEFORE INSERT OR UPDATE ON "pre_commit_requirements"
FOR EACH ROW
WHEN (coalesce(current_setting('logidze.disabled', true), '') <> 'on')
EXECUTE PROCEDURE logidze_logger(null, 'updated_at');
