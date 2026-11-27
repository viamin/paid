# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261127193848_validate_feature_intent_decisions_source_agent_run_foreign_key")

RSpec.describe ValidateFeatureIntentDecisionsSourceAgentRunForeignKey do
  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }

  def reference
    connection.foreign_keys(:feature_intent_decisions).find { |key| key.column == "source_agent_run_id" }
  end

  around do |example|
    original = reference
    connection.remove_foreign_key :feature_intent_decisions, column: :source_agent_run_id
    connection.add_foreign_key :feature_intent_decisions, :agent_runs,
      column: :source_agent_run_id, name: original.name, validate: false
    connection.transaction do
      example.run
      raise ActiveRecord::Rollback
    end
  ensure
    connection.validate_foreign_key :feature_intent_decisions, :agent_runs,
      column: :source_agent_run_id if original&.validated?
  end

  # @spec POSTGRESQL-PERSISTENCE-018
  it "validates existing references without changing their definition or rows" do
    original = reference.to_h
    count = connection.select_value("SELECT COUNT(*) FROM feature_intent_decisions")
    ActiveRecord::Migration.suppress_messages { migration.migrate(:up) }
    expect(reference).to be_validated
    expect(reference.to_h).to eq(original.merge(options: original.fetch(:options).merge(validate: true)))
    expect(connection.select_value("SELECT COUNT(*) FROM feature_intent_decisions")).to eq(count)
  end

  # @spec POSTGRESQL-PERSISTENCE-018
  it "preserves validation and the foreign key on rollback" do
    ActiveRecord::Migration.suppress_messages do
      migration.migrate(:up)
      migration.migrate(:down)
    end
    expect(reference).to be_validated
  end
end
