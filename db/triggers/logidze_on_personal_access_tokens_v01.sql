CREATE TRIGGER "logidze_on_personal_access_tokens"
BEFORE UPDATE OR INSERT ON "personal_access_tokens" FOR EACH ROW
WHEN (coalesce(current_setting('logidze.disabled', true), '') <> 'on')
-- Excludes the throttled usage stamp so polling traffic does not bury
-- revocation events in log_data noise.
-- Parameters: history_size_limit (integer), timestamp_column (text), filtered_columns (text[]),
-- include_columns (boolean), debounce_time_ms (integer), detached_loggable_type(text), log_data_table_name(text)
EXECUTE PROCEDURE logidze_logger(null, 'updated_at', '{last_used_at}');
