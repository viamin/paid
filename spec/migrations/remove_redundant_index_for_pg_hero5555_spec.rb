# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261127205524_remove_redundant_index_for_pg_hero5555")

RSpec.describe RemoveRedundantIndexForPgHero5555 do
  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }
  let(:removed_name) { "idx_on_feature_intent_facet_id_b98fb4f64a" }
  let(:covering_name) { "idx_on_feature_intent_facet_id_name_f5a6e56431" }

  def indexes
    connection.indexes(:feature_intent_facet_directions).to_h { |index| [ index.name, index ] }
  end

  def definition(index)
    [ index.columns, index.unique, index.using, index.where, index.orders, index.opclasses, index.comment ]
  end

  # @spec POSTGRESQL-PERSISTENCE-022
  it "removes only the redundant index and recreates its definition on rollback" do
    original = definition(indexes.fetch(removed_name))
    covering = definition(indexes.fetch(covering_name))
    count = connection.select_value("SELECT COUNT(*) FROM feature_intent_facet_directions")
    ActiveRecord::Migration.suppress_messages { migration.migrate(:up) }
    expect(indexes).not_to have_key(removed_name)
    expect(definition(indexes.fetch(covering_name))).to eq(covering)
    expect(connection.select_value("SELECT COUNT(*) FROM feature_intent_facet_directions")).to eq(count)
    ActiveRecord::Migration.suppress_messages { migration.migrate(:down) }
    expect(definition(indexes.fetch(removed_name))).to eq(original)
  ensure
    ActiveRecord::Migration.suppress_messages { migration.migrate(:down) } unless indexes.key?(removed_name)
  end
end
