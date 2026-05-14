CREATE TRIGGER "logidze_on_pr_templates"
BEFORE INSERT OR UPDATE ON "pr_templates"
FOR EACH ROW
WHEN (coalesce(current_setting('logidze.disabled', true), '') <> 'on')
EXECUTE PROCEDURE logidze_logger(null, 'updated_at');
