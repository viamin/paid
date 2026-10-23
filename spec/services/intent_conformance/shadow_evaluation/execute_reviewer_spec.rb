# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-CONFORMANCE-ROLLOUT-006
# @spec INTENT-CONFORMANCE-ROLLOUT-007
RSpec.describe IntentConformance::ShadowEvaluation::ExecuteReviewer do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account: account) }
  let(:project) { create(:project, account: account, created_by: owner) }
  let(:dir) { Dir.mktmpdir }
  let(:cases) { [ corpus_case("A-01"), corpus_case("A-02", "stratum" => "intentionally_drifted") ] }
  let(:manifest_path) { write_corpus_manifest(dir, cases) }
  let(:evaluation) do
    create(:intent_conformance_shadow_evaluation, project: project, solo_maintainer: owner, created_by: owner,
      manifest_path: manifest_path, manifest_digest: Digest::SHA256.file(manifest_path).hexdigest)
  end
  let(:github_client) { instance_double(GithubClient) }

  before do
    allow(project).to receive(:client).and_return(github_client)
    allow(project).to receive_messages(full_name: "acme/widgets", client: github_client)
    allow(github_client).to receive(:file_content).with("acme/widgets", path: "docs/rdrs/RDR-999-example.md", ref: "c" * 40)
      .and_return("# RDR-999\n\nThe widget SHALL always be blue.")
  end

  after { FileUtils.remove_entry(dir) }

  def comparison(files = [ { filename: "app/models/widget.rb", status: "modified", additions: 3, deletions: 1, patch: "@@ -1,2 +1,3 @@\n widget code" } ])
    { files: files }
  end

  def llm_response(outcome)
    instance_double(AgentHarness::Response, success?: true, model: "claude-sonnet-4-6",
      output: { outcome: outcome, cited_design_claims: [ "blue" ], cited_diff_locations: [ { "file" => "app/models/widget.rb", "note" => "color" } ], reasoning_summary: "ok" }.to_json,
      metadata: { cost_cents: 42 })
  end

  def prepare_frozen!
    label_all!(evaluation)
    freeze!(evaluation)
  end

  it "refuses to execute before the reference set is frozen (blinding boundary)" do
    result = described_class.call(evaluation: evaluation)

    expect(result).not_to be_success
    expect(result.error).to include("frozen reference label set")
    expect(evaluation.runs).to be_empty
  end

  it "executes the real reviewer through agent_harness and records actual verdicts" do
    prepare_frozen!
    allow(github_client).to receive(:compare_summary).with("acme/widgets", "a" * 40, "b" * 40).and_return(comparison)
    allow(AgentHarness).to receive(:send_message).and_return(llm_response("within_scope"))

    result = described_class.call(evaluation: evaluation)

    expect(result).to be_success
    expect(result.executed).to eq(2)
    expect(AgentHarness).to have_received(:send_message).twice
    expect(evaluation.reload).to be_completed
    runs = evaluation.runs.index_by(&:case_id)
    expect(runs["A-01"]).to have_attributes(verdict: "within_scope", reviewer_model: "claude-sonnet-4-6", cost_cents: 42, failure_reason: nil)
    expect(runs["A-01"].prompt_digest).to be_present
  end

  it "records missing or failed reviewer output as not_evaluated, never as agreement" do
    prepare_frozen!
    allow(github_client).to receive(:compare_summary).and_return(comparison)
    allow(AgentHarness).to receive(:send_message).and_return(instance_double(AgentHarness::Response, success?: false, model: nil, output: nil, metadata: {}))

    result = described_class.call(evaluation: evaluation)

    expect(result).to be_success
    expect(result.failed).to eq(2)
    expect(evaluation.reload).to be_failed
    expect(evaluation.last_failure_reason).to include("without an evaluated reviewer verdict")
    evaluation.runs.each do |run|
      expect(run).to be_not_evaluated
      expect(run.failure_reason).to eq("unsuccessful_response")
    end
  end

  it "fails closed when the manifest changed since labels were frozen" do
    prepare_frozen!
    File.write(manifest_path, { "cases" => cases + [ corpus_case("A-03") ] }.to_yaml)

    result = described_class.call(evaluation: evaluation)

    expect(result).not_to be_success
    expect(result.error).to include("manifest changed")
    expect(evaluation.runs).to be_empty
  end

  it "fails closed when a case's repository is outside the project" do
    evaluation
    other_case = corpus_case("A-03", "repository" => "someone/else")
    v2_path = File.join(dir, "corpus-manifest-v2.yml")
    File.write(v2_path, { "cases" => [ corpus_case("A-01"), other_case ] }.to_yaml)
    evaluation.update!(manifest_path: v2_path, manifest_digest: Digest::SHA256.file(v2_path).hexdigest)
    label_all!(evaluation)
    freeze!(evaluation)
    allow(github_client).to receive(:compare_summary).and_return(comparison)
    allow(AgentHarness).to receive(:send_message).and_return(llm_response("within_scope"))

    result = described_class.call(evaluation: evaluation)

    expect(result.executed).to eq(1)
    expect(result.failed).to eq(1)
    expect(evaluation.runs.find_by(case_id: "A-03")).to be_not_evaluated
  end

  it "retries only cases that lack an evaluated verdict" do
    prepare_frozen!
    allow(github_client).to receive(:compare_summary).and_return(comparison)
    allow(AgentHarness).to receive(:send_message)
      .and_return(instance_double(AgentHarness::Response, success?: false, model: nil, output: nil, metadata: {}))
    described_class.call(evaluation: evaluation)

    allow(AgentHarness).to receive(:send_message).and_return(llm_response("material_drift"))
    result = described_class.call(evaluation: evaluation)

    expect(result).to be_success
    expect(result.executed).to eq(2)
    expect(result.failed).to eq(0)
    expect(evaluation.reload).to be_completed
    expect(evaluation.runs.count).to eq(2)
  end
end
