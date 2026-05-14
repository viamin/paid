CREATE TRIGGER "logidze_on_style_guides"
BEFORE INSERT OR UPDATE ON "style_guides"
FOR EACH ROW
WHEN (coalesce(current_setting('logidze.disabled', true), '') <> 'on')
EXECUTE PROCEDURE logidze_logger(null, 'updated_at');
