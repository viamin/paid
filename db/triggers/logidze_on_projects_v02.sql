CREATE TRIGGER "logidze_on_projects"
BEFORE UPDATE OR INSERT ON "projects" FOR EACH ROW
WHEN (coalesce(current_setting('logidze.disabled', true), '') <> 'on')
-- Excludes high-frequency operational timestamps (touch_last_*_at) to avoid
-- log_data bloat from poll cycles and sync events. Also excludes metrics
-- counters that update on every agent run.
-- Parameters: history_size_limit, timestamp_column, filtered_columns, include_columns, debounce_time_ms
EXECUTE PROCEDURE logidze_logger(null, 'updated_at', '{last_polled_at,last_agent_run_at,last_github_activity_at,last_issue_sync_at,total_cost_cents,total_tokens_used}');
