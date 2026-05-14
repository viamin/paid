CREATE TRIGGER "logidze_on_project_memberships"
BEFORE INSERT OR UPDATE ON "project_memberships"
FOR EACH ROW
WHEN (coalesce(current_setting('logidze.disabled', true), '') <> 'on')
EXECUTE PROCEDURE logidze_logger(null, 'updated_at');
