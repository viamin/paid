CREATE TRIGGER "logidze_on_exception_incidents"
BEFORE INSERT OR UPDATE ON "exception_incidents"
FOR EACH ROW
WHEN (coalesce(current_setting('logidze.disabled', true), '') <> 'on')
-- Exclude occurrence counters and raw exception payloads to avoid noisy
-- version churn and retaining sensitive details in log_data.
EXECUTE PROCEDURE logidze_logger(
  null,
  'updated_at',
  '{occurrence_count,last_occurred_at,backtrace,context}'
);
