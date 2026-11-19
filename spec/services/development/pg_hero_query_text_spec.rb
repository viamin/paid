# frozen_string_literal: true

require "rails_helper"
require "pg_query"

RSpec.describe Development::PgHeroQueryText, :no_db do
  # @spec RAILS-CONTROL-PLANE-020
  it "uses byte offsets to remove comments after multibyte quoted identifiers" do
    filtered = described_class.call("SELECT 'private-value' AS \"café--keep\" /* private-token */ -- private-tail\n")

    expect(filtered).to eq('SELECT $1 AS "café--keep"')
    expect(filtered.encoding).to eq(Encoding::UTF_8)
    expect(filtered).to be_valid_encoding
  end

  # @spec RAILS-CONTROL-PLANE-020
  it "filters utility strings containing comment delimiters without discarding the statement's structure" do
    filtered = described_class.call("COMMENT ON TABLE issues IS 'private-value /* not a comment */ -- still literal'")

    expect(filtered).to eq("COMMENT ON TABLE issues IS '[filtered]'")
    expect { PgQuery.parse(filtered) }.not_to raise_error
  end

  # @spec RAILS-CONTROL-PLANE-020
  it "does not retain malformed SQL when filtering fails" do
    expect(described_class.call("SELECT 'private-unclosed-string")).to eq("<unable to filter data>")
  end
end
