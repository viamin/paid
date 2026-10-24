# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-CONFORMANCE-ROLLOUT-010
RSpec.describe IntentConformanceShadowEvaluationExecutionJob do
  include ShadowEvaluationCorpusHelper
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account: account) }
  let(:project) { create(:project, account: account, created_by: owner) }
  let(:directory) { Dir.mktmpdir }
  let(:cases) { [ corpus_case("A-01"), corpus_case("A-02") ] }
  let(:manifest_path) { write_corpus_manifest(directory, cases) }
  let(:evaluation) do
    create(:intent_conformance_shadow_evaluation, project: project, solo_maintainer: owner, created_by: owner,
      manifest_path: manifest_path, manifest_digest: Digest::SHA256.file(manifest_path).hexdigest)
  end
  let(:github_client) { instance_double(GithubClient) }

  before do
    label_all!(evaluation)
    freeze!(evaluation)
    evaluation.update!(status: "queued", execution_heartbeat_at: Time.current)
    project.update!(owner: "acme", repo: "widgets")
    allow(GithubClient).to receive(:new).and_return(github_client)
    allow(github_client).to receive_messages(
      file_content: "# RDR",
      compare_summary: { files: [ { filename: "widget.rb", status: "modified", additions: 1, deletions: 1, patch: "widget" } ] }
    )
  end

  after { FileUtils.remove_entry(directory) }

  it "does not start a worker after queued execution is cancelled" do
    evaluation.update!(status: "cancelled", cancellation_requested_at: Time.current)

    described_class.perform_now(evaluation.id, evaluation.execution_attempt)

    expect(evaluation.reload).to be_cancelled
    expect(evaluation.runs).to be_empty
  end

  it "ignores a superseded queued attempt" do
    evaluation.update!(execution_attempt: 2)

    described_class.perform_now(evaluation.id, 1)

    expect(evaluation.reload).to be_queued
    expect(evaluation.runs).to be_empty
  end
end
