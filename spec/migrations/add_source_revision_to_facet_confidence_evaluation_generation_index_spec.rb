# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261106235102_add_source_revision_to_facet_confidence_evaluation_generation_index")

# The evaluation-generation unique key includes the closeout's recorded source
# revision, so a revision change can start a new generation instead of
# stranding the operator on a frozen row (#4902 review).
# @spec FACET-CONFIDENCE-020 @spec FACET-CONFIDENCE-023
RSpec.describe AddSourceRevisionToFacetConfidenceEvaluationGenerationIndex, :aggregate_failures do
  self.use_transactional_tests = false

  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }
  let(:index_name) { described_class::INDEX_NAME }

  around do |example|
    tables_existed = connection.table_exists?(:facet_confidence_evaluations)

    example.run
  ensure
    migration.up if tables_existed
    clear_schema_metadata!
  end

  it "keys one evaluation generation on issue, corpus digest, and source revision" do
    migration.up

    index = connection.indexes(:facet_confidence_evaluations).find { |candidate| candidate.name == index_name }
    expect(index.unique).to be(true)
    expect(index.columns).to eq(%w[issue_id corpus_digest source_revision])
    expect(index.nulls_not_distinct).to be(true)
  end

  it "rolls back to the legacy issue-and-digest generation key" do
    migration.up

    expect { migration.down }.not_to raise_error

    index = connection.indexes(:facet_confidence_evaluations).find { |candidate| candidate.name == index_name }
    expect(index.unique).to be(true)
    expect(index.columns).to eq(%w[issue_id corpus_digest])
  end

  private

  def clear_schema_metadata!
    connection.schema_cache.clear!
    connection.schema_cache.clear_data_source_cache!(:facet_confidence_evaluations)
    FacetConfidenceEvaluation.reset_column_information
  end
end
