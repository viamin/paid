CREATE TRIGGER "logidze_on_docker_hosts"
BEFORE UPDATE OR INSERT ON "docker_hosts" FOR EACH ROW
WHEN (coalesce(current_setting('logidze.disabled', true), '') <> 'on')
-- Parameters: history_size_limit (integer), timestamp_column (text), filtered_columns (text[]),
-- include_columns (boolean), debounce_time_ms (integer), detached_loggable_type(text), log_data_table_name(text)
EXECUTE PROCEDURE logidze_logger(null, 'updated_at');
