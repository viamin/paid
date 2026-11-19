# frozen_string_literal: true

require "rails_helper"

class PgHeroResetPermissions < Pathname
end

RSpec.describe PgHeroResetPermissions do
  # @spec RAILS-CONTROL-PLANE-020
  it "revokes a former application role's helper access while preserving the owner's access" do
    connection = ActiveRecord::Base.connection
    schema = "pghero_acl_#{SecureRandom.hex(6)}"
    connection.execute("CREATE SCHEMA #{schema}")
    connection.execute("CREATE FUNCTION #{schema}.reset_query_stats() RETURNS void LANGUAGE sql AS 'SELECT NULL::void'")
    connection.execute("GRANT EXECUTE ON FUNCTION #{schema}.reset_query_stats() TO pg_monitor")
    owner = connection.select_value("SELECT current_user")

    source = Rails.root.join("config/development_query_stats.sql").read
    permissions_sql = source[/REVOKE ALL ON FUNCTION paid_diagnostics\.reset_query_stats\(\) FROM PUBLIC;.*?GRANT EXECUTE ON FUNCTION paid_diagnostics\.reset_query_stats\(\) TO :"app_role";/m]
      .gsub("paid_diagnostics", schema).gsub(':"app_role"', connection.quote_column_name(owner))
    connection.execute(permissions_sql)

    expect(connection.select_value("SELECT has_function_privilege('pg_monitor', '#{schema}.reset_query_stats()', 'EXECUTE')")).to be(false)
    expect(connection.select_value("SELECT has_function_privilege(current_user, '#{schema}.reset_query_stats()', 'EXECUTE')")).to be(true)
  end
end
