begin
  v = "20260628132627"
  present = ActiveRecord::Base.connection.select_value("SELECT 1 FROM schema_migrations WHERE version='#{v}'")
  puts "update_trigger v2 migration #{v} recorded: #{present ? 'YES' : 'NO'}"
  versions = ActiveRecord::Base.connection.select_values("SELECT version FROM schema_migrations WHERE version LIKE '20260628%' ORDER BY version")
  puts "20260628 versions: #{versions.inspect}"
  # Check the actual logidze_logger call signature in the trigger
  tdef = ActiveRecord::Base.connection.select_value(
    "SELECT pg_get_triggerdef(oid) FROM pg_trigger WHERE tgname = 'logidze_on_runner_credentials'"
  )
  puts "LIVE TRIGGER: #{tdef}"
rescue => e
  puts "ERROR: #{e.class}: #{e.message}"
end
