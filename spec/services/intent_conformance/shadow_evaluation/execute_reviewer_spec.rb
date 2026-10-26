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

  def llm_response(outcome, model: "claude-sonnet-4-6")
    instance_double(AgentHarness::Response, success?: true, model: model,
      output: { outcome: outcome, cited_design_claims: [ "blue" ], cited_diff_locations: [ { "file" => "app/models/widget.rb", "note" => "color" } ], reasoning_summary: "ok" }.to_json,
      metadata: { cost_cents: 42 })
  end

  def prepare_frozen!
    label_all!(evaluation)
    freeze!(evaluation)
  end

  # A distinct PG backend/session standing in for a second operator's
  # process; see the contention example for why the checked-out Rails
  # connection cannot play that role.
  def raw_pg_session
    db_config = ActiveRecord::Base.connection_db_config.configuration_hash
    PG.connect(
      host: db_config[:host], port: db_config[:port], dbname: db_config[:database],
      user: db_config[:username], password: db_config[:password]
    )
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

  it "executes the reviewer pinned by the manifest" do
    manifest_path = write_corpus_manifest(dir, cases, "reviewer" => {
      "model" => "claude-opus-4-6",
      "prompt_version" => IntentConformance::ReviewerLlm::PROMPT_VERSION,
      "prompt_sha256" => Digest::SHA256.hexdigest(IntentConformance::ReviewerLlm::PROMPT)
    })
    pinned_evaluation = create(:intent_conformance_shadow_evaluation, project: project, solo_maintainer: owner, created_by: owner,
      manifest_path: manifest_path, manifest_digest: Digest::SHA256.file(manifest_path).hexdigest)
    label_all!(pinned_evaluation)
    freeze!(pinned_evaluation)
    allow(github_client).to receive(:compare_summary).and_return(comparison)
    allow(AgentHarness).to receive(:send_message).and_return(llm_response("within_scope", model: "claude-opus-4-6"))

    result = described_class.call(evaluation: pinned_evaluation)

    expect(result).to be_success
    expect(AgentHarness).to have_received(:send_message).with(anything, hash_including(model: "claude-opus-4-6")).twice
    expect(pinned_evaluation.runs.pluck(:reviewer_model)).to all(eq("claude-opus-4-6"))
  end

  it "refuses an unexecutable manifest reviewer identity before invoking the reviewer" do
    manifest_path = write_corpus_manifest(dir, cases, "reviewer" => {
      "model" => "claude-opus-4-6",
      "prompt_version" => "retired-reviewer-prompt",
      "prompt_sha256" => "stale-prompt-digest"
    })
    pinned_evaluation = create(:intent_conformance_shadow_evaluation, project: project, solo_maintainer: owner, created_by: owner,
      manifest_path: manifest_path, manifest_digest: Digest::SHA256.file(manifest_path).hexdigest)
    label_all!(pinned_evaluation)
    freeze!(pinned_evaluation)
    allow(AgentHarness).to receive(:send_message)

    result = described_class.call(evaluation: pinned_evaluation)

    expect(result).not_to be_success
    expect(result.error).to include("prompt version")
    expect(AgentHarness).not_to have_received(:send_message)
  end

  it "does not count a response from a different model as an evaluated verdict" do
    manifest_path = write_corpus_manifest(dir, cases, "reviewer" => {
      "model" => "claude-opus-4-6",
      "prompt_version" => IntentConformance::ReviewerLlm::PROMPT_VERSION,
      "prompt_sha256" => Digest::SHA256.hexdigest(IntentConformance::ReviewerLlm::PROMPT)
    })
    pinned_evaluation = create(:intent_conformance_shadow_evaluation, project: project, solo_maintainer: owner, created_by: owner,
      manifest_path: manifest_path, manifest_digest: Digest::SHA256.file(manifest_path).hexdigest)
    label_all!(pinned_evaluation)
    freeze!(pinned_evaluation)
    allow(github_client).to receive(:compare_summary).and_return(comparison)
    allow(AgentHarness).to receive(:send_message).and_return(llm_response("within_scope"))

    result = described_class.call(evaluation: pinned_evaluation)

    expect(result.failed).to eq(2)
    expect(pinned_evaluation.runs).to all(have_attributes(verdict: "not_evaluated", failure_reason: "reviewer_model_mismatch", reviewer_model: "claude-sonnet-4-6", cost_cents: 42))
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

  # @spec INTENT-CONFORMANCE-ROLLOUT-009
  it "stops between cases when an authorized cancellation has been persisted" do
    prepare_frozen!
    allow(github_client).to receive(:compare_summary).and_return(comparison)
    allow(AgentHarness).to receive(:send_message) do
      evaluation.update!(status: "cancelled", execution_cancelled_at: Time.current)
      llm_response("within_scope")
    end

    result = described_class.call(evaluation: evaluation)

    expect(result).to be_success
    expect(evaluation.reload).to be_cancelled
    expect(evaluation.runs.count).to eq(1)
    expect(evaluation.runs.first).to be_evaluated
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
    File.write(v2_path, { "cases" => [ corpus_case("A-01"), other_case ], "reviewer" => reviewer_identity }.to_yaml)
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

  # @spec INTENT-CONFORMANCE-ROLLOUT-007 — any project operator may execute,
  # so two concurrent POSTs would both observe "no run row" for a case, both
  # invoke the paid reviewer, and the loser's write would then race the
  # unique (shadow_evaluation_id, case_id) index after duplicated LLM spend.
  # A genuinely separate PG session is required to prove the contention: the
  # transactional fixtures pin every connection checked out on this thread
  # to the same backend/session, so advisory locks taken that way would just
  # re-enter a lock this thread already holds. Session-scoped
  # pg_try_advisory_lock only contends across distinct backends, so the
  # second operator's process is simulated with a raw `pg` connection.
  it "refuses to start when another invocation is already executing this evaluation" do
    prepare_frozen!
    allow(AgentHarness).to receive(:send_message)

    other_session = raw_pg_session
    begin
      other_session.exec_params(
        "SELECT pg_try_advisory_lock($1, $2)",
        [ described_class::ADVISORY_LOCK_NAMESPACE, evaluation.id ]
      )

      result = described_class.call(evaluation: evaluation)

      expect(result).not_to be_success
      expect(result.error).to include("already in progress")
      expect(AgentHarness).not_to have_received(:send_message)
      expect(evaluation.reload).to be_frozen
      expect(evaluation.runs).to be_empty
    ensure
      other_session.close
    end
  end

  it "releases the execution lock when it finishes so a retry can proceed" do
    prepare_frozen!
    allow(github_client).to receive(:compare_summary).and_return(comparison)
    allow(AgentHarness).to receive(:send_message)
      .and_return(instance_double(AgentHarness::Response, success?: false, model: nil, output: nil, metadata: {}))
    described_class.call(evaluation: evaluation)

    allow(AgentHarness).to receive(:send_message).and_return(llm_response("within_scope"))
    second = described_class.call(evaluation: evaluation)

    expect(second).to be_success
    expect(second.executed).to eq(2)
    expect(evaluation.reload).to be_completed
  end
end
