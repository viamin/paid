# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-CONFORMANCE-ROLLOUT-011
RSpec.describe IntentConformance::ShadowEvaluation::EnqueueExecution do
  let(:manifest_dir) { Dir.mktmpdir }
  let(:manifest_path) { File.join(manifest_dir, "corpus.yml") }
  let(:evaluation) do
    File.write(manifest_path, { "cases" => [ { "id" => "A-01" } ] }.to_yaml)
    create(:intent_conformance_shadow_evaluation, :frozen,
      manifest_path:, manifest_digest: Digest::SHA256.file(manifest_path).hexdigest)
  end

  after { FileUtils.remove_entry(manifest_dir) }

  it "enqueues the durable job in the same transaction as the queued state" do
    transaction_open = nil
    allow(ShadowEvaluationExecutionJob).to receive(:perform_later) do
      transaction_open = IntentConformanceShadowEvaluation.connection.transaction_open?
    end

    result = described_class.call(evaluation: evaluation, actor: evaluation.created_by)

    expect(result).to be_success
    expect(transaction_open).to be(true)
  end
end
