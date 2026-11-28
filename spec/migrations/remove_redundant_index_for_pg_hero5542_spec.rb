# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261127205124_remove_redundant_index_for_pg_hero5542")

RSpec.describe RemoveRedundantIndexForPgHero5542 do
  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }
  let(:removed_name) { "idx_on_facet_confidence_evaluation_id_2126f02a77" }
  let(:covering_name) { "idx_facet_confidence_evaluation_labels_case" }

  def indexes
    connection.indexes(:facet_confidence_evaluation_labels).to_h { |index| [ index.name, index ] }
  end

  def definition(index)
    [ index.columns, index.unique, index.using, index.where, index.orders, index.opclasses, index.comment ]
  end

  around do |example|
    unless indexes.key?(removed_name)
      connection.add_index :facet_confidence_evaluation_labels, :facet_confidence_evaluation_id, name: removed_name
    end
    example.run
  ensure
    if indexes.key?(removed_name)
      connection.remove_index :facet_confidence_evaluation_labels, name: removed_name
    end
  end

  # @spec POSTGRESQL-PERSISTENCE-022
  it "removes only the redundant index and recreates its definition on rollback" do
    original = definition(indexes.fetch(removed_name))
    covering = definition(indexes.fetch(covering_name))
    count = connection.select_value("SELECT COUNT(*) FROM facet_confidence_evaluation_labels")
    ActiveRecord::Migration.suppress_messages { migration.migrate(:up) }
    expect(indexes).not_to have_key(removed_name)
    expect(definition(indexes.fetch(covering_name))).to eq(covering)
    expect(connection.select_value("SELECT COUNT(*) FROM facet_confidence_evaluation_labels")).to eq(count)
    ActiveRecord::Migration.suppress_messages { migration.migrate(:down) }
    expect(definition(indexes.fetch(removed_name))).to eq(original)
  end
end
