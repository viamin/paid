CREATE TRIGGER "logidze_on_mcp_server_definitions"
BEFORE INSERT OR UPDATE ON "mcp_server_definitions"
FOR EACH ROW
WHEN (coalesce(current_setting('logidze.disabled', true), '') <> 'on')
EXECUTE PROCEDURE logidze_logger(null, 'updated_at');
