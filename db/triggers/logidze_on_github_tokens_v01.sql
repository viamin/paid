CREATE TRIGGER "logidze_on_github_tokens"
BEFORE UPDATE OR INSERT ON "github_tokens" FOR EACH ROW
WHEN (coalesce(current_setting('logidze.disabled', true), '') <> 'on')
-- Excludes routine usage/cache fields so token proxy traffic and repository
-- syncs do not bury revocation or scope changes in log_data noise.
-- Parameters: history_size_limit (integer), timestamp_column (text), filtered_columns (text[]),
-- include_columns (boolean), debounce_time_ms (integer), detached_loggable_type(text), log_data_table_name(text)
EXECUTE PROCEDURE logidze_logger(null, 'updated_at', '{token,last_used_at,repositories_synced_at,accessible_repositories}');
