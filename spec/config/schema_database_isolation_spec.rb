# frozen_string_literal: true

require "spec_helper"
require "pathname"

class SchemaDatabaseIsolation < Pathname
end

RSpec.describe SchemaDatabaseIsolation, :no_db do
  # @spec POSTGRESQL-PERSISTENCE-010
  it "keeps cable tables out of the primary schema" do
    schema_root = File.expand_path("../../db", __dir__)
    tables = %w[schema.rb cable_schema.rb].map do |filename|
      File.read(File.join(schema_root, filename)).scan(/^\s*create_table\s+["']([^"']+)["']/).flatten
    end

    expect(tables.first).not_to be_empty, "Primary schema must define tables"
    expect(tables.last).not_to be_empty, "Cable schema must define tables"
    expect(tables.first & tables.last).to be_empty,
      "Primary and cable schemas share tables: #{(tables.first & tables.last).join(', ')}"
  end
end
