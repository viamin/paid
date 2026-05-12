CREATE TRIGGER "logidze_on_users"
BEFORE INSERT OR UPDATE ON "users"
FOR EACH ROW
WHEN (coalesce(current_setting('logidze.disabled', true), '') <> 'on')
-- Exclude auth-sensitive columns to prevent secrets persisting in log_data
EXECUTE PROCEDURE logidze_logger(null, 'updated_at', '{encrypted_password,reset_password_token}');
