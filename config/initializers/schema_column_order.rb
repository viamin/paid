# frozen_string_literal: true

require "delegate"

# Keep schema output independent of PostgreSQL's physical column order without
# changing the connection used by application queries or fx's schema extensions.
module SchemaColumnOrder
  class Connection < SimpleDelegator
    def columns(table_name)
      super.sort_by(&:name)
    end
  end

  # @spec POSTGRESQL-PERSISTENCE-009
  def initialize(connection, options = {})
    super(Connection.new(connection), options)
  end
end

ActiveRecord::SchemaDumper.prepend(SchemaColumnOrder)
