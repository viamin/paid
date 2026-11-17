# frozen_string_literal: true

# Rails does not natively serialize PostgreSQL row-level security. Keep the
# canonical Ruby schema complete so db:schema:load recreates the same database
# boundary as migrations.
module SchemaRowLevelSecurity
  # @spec POSTGRESQL-PERSISTENCE-012
  def tables(stream)
    super
    dump_row_level_security(stream)
  end

  private

  def dump_row_level_security(stream)
    policies = row_level_security_policies
    return if policies.empty?

    stream.puts
    stream.puts "  # PostgreSQL row-level security policies."
    policies.each do |policy|
      stream.puts
      stream.puts "  execute <<~SQL"
      stream.puts "    ALTER TABLE #{qualified_table(policy)} ENABLE ROW LEVEL SECURITY;"
      stream.puts "    ALTER TABLE #{qualified_table(policy)} FORCE ROW LEVEL SECURITY;" if policy.fetch("force")
      stream.puts "    #{policy_sql(policy)};"
      stream.puts "  SQL"
    end
  end

  def row_level_security_policies
    @connection.select_all(<<~SQL.squish)
      SELECT n.nspname AS schema_name, c.relname AS table_name,
        c.relforcerowsecurity AS force, p.polname AS policy_name,
        p.polpermissive AS permissive, p.polcmd AS command,
        pg_get_expr(p.polqual, p.polrelid) AS qual,
        pg_get_expr(p.polwithcheck, p.polrelid) AS with_check,
        COALESCE(array_to_string(ARRAY(
          SELECT quote_ident(r.rolname)
          FROM unnest(p.polroles) AS role_id
          JOIN pg_roles r ON r.oid = role_id
          WHERE role_id <> 0
          ORDER BY r.rolname
        ), ', '), '') AS roles
      FROM pg_policy p
      JOIN pg_class c ON c.oid = p.polrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = ANY (current_schemas(false))
      ORDER BY n.nspname, c.relname, p.polname
    SQL
  end

  def qualified_table(policy)
    [ policy.fetch("schema_name"), policy.fetch("table_name") ].map { |name| @connection.quote_table_name(name) }.join(".")
  end

  def policy_sql(policy)
    parts = [
      "CREATE POLICY #{@connection.quote_column_name(policy.fetch('policy_name'))} ON #{qualified_table(policy)}",
      (policy.fetch("permissive") ? "AS PERMISSIVE" : "AS RESTRICTIVE"),
      "FOR #{policy_command(policy.fetch('command'))}"
    ]
    parts << "TO #{policy.fetch('roles')}" if policy.fetch("roles").present?
    parts << "USING (#{policy.fetch('qual')})" if policy.fetch("qual").present?
    parts << "WITH CHECK (#{policy.fetch('with_check')})" if policy.fetch("with_check").present?
    parts.join("\n      ")
  end

  def policy_command(command)
    { "r" => "SELECT", "a" => "INSERT", "w" => "UPDATE", "d" => "DELETE", "*" => "ALL" }.fetch(command)
  end
end

Rails.application.config.after_initialize do
  dumper = ActiveRecord::SchemaDumper
  dumper.prepend(SchemaRowLevelSecurity) unless dumper.ancestors.include?(SchemaRowLevelSecurity)
end
