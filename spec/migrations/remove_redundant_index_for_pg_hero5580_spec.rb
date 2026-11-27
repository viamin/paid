# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261127211119_remove_redundant_index_for_pg_hero5580")

RSpec.describe RemoveRedundantIndexForPgHero5580 do
  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }
  let(:removed_name) { "idx_on_shadow_evaluation_id_faf0701cf6" }
  let(:covering_name) { "idx_shadow_evaluation_labels_case" }

  def indexes
    connection.indexes(:intent_conformance_shadow_evaluation_labels).to_h { |index| [ index.name, index ] }
  end

  def definition(index)
    [ index.columns, index.unique, index.using, index.where, index.orders, index.opclasses, index.comment ]
  end

  # @spec POSTGRESQL-PERSISTENCE-022
  it "removes only the redundant index and recreates its definition on rollback" do
    original = definition(indexes.fetch(removed_name))
    covering = definition(indexes.fetch(covering_name))
    count = connection.select_value("SELECT COUNT(*) FROM intent_conformance_shadow_evaluation_labels")
    ActiveRecord::Migration.suppress_messages { migration.migrate(:up) }
    expect(indexes).not_to have_key(removed_name)
    expect(definition(indexes.fetch(covering_name))).to eq(covering)
    expect(connection.select_value("SELECT COUNT(*) FROM intent_conformance_shadow_evaluation_labels")).to eq(count)
    ActiveRecord::Migration.suppress_messages { migration.migrate(:down) }
    expect(definition(indexes.fetch(removed_name))).to eq(original)
  ensure
    ActiveRecord::Migration.suppress_messages { migration.migrate(:down) } unless indexes.key?(removed_name)
  end
end
