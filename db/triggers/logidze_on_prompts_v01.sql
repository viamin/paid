CREATE TRIGGER "logidze_on_prompts"
BEFORE INSERT OR UPDATE ON "prompts"
FOR EACH ROW
WHEN (coalesce(current_setting('logidze.disabled', true), '') <> 'on')
EXECUTE PROCEDURE logidze_logger(null, 'updated_at');
