# frozen_string_literal: true

require "rails_helper"

# The background half of the #4642 execution lifecycle: per-case work runs
# on the worker (never in the HTTP request), terminal outcomes compile the
# report through the existing service, a pre-start cancellation is honored,
# and a lost/unowned execution never strands the record as queued/running.
# @spec INTENT-CONFORMANCE-ROLLOUT-007
# @spec INTENT-CONFORMANCE-ROLLOUT-011
RSpec.describe IntentConformance::ShadowEvaluations::ExecuteJob do
  include ActiveJob::TestHelper

  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account: account) }
  let(:project) { create(:project, account: account, created_by: owner) }
  let(:dir) { Dir.mktmpdir }
  let(:cases) { [ corpus_case("A-01"), corpus_case("A-02") ] }
  let(:manifest_path) { write_corpus_manifest(dir, cases) }
  let(:evaluation) do
    create(:intent_conformance_shadow_evaluation, project: project, solo_maintainer: owner, created_by: owner,
      manifest_path: manifest_path, manifest_digest: Digest::SHA256.file(manifest_path).hexdigest)
  end
  let(:github_client) { instance_double(GithubClient) }

  before do
    allow(project).to receive_messages(full_name: "acme/widgets", client: github_client)
    allow(github_client).to receive(:file_content).and_return("# RDR-999\n\nThe widget SHALL always be blue.")
  end

  after { FileUtils.remove_entry(dir) }

  def comparison
    { files: [ { filename: "app/models/widget.rb", status: "modified", additions: 3, deletions: 1, patch: "@@ -1,2 +1,3 @@\n widget code" } ] }
  end

  def llm_response(outcome)
    instance_double(AgentHarness::Response, success?: true, model: IntentConformance::ReviewerLlm::DEFAULT_MODEL,
      output: { outcome: outcome, cited_design_claims: [ "blue" ], cited_diff_locations: [ { "file" => "app/models/widget.rb", "note" => "color" } ], reasoning_summary: "ok" }.to_json,
      metadata: { cost_cents: 42 })
  end

  # The worker loads the evaluation by id, which would return a fresh
  # instance whose project association lacks this example's repository
  # stubs; the service specs own the repository boundary, so the lookup is
  # pinned to the crafted record (the same seam review_job_spec stubs).
  def queue_execution!
    label_all!(evaluation)
    freeze!(evaluation)
    allow(IntentConformanceShadowEvaluation).to receive(:find).with(evaluation.id).and_return(evaluation)
    IntentConformance::ShadowEvaluation::EnqueueExecution.call(evaluation: evaluation)
  end

  # A genuinely separate PG session standing in for a concurrent holder of
  # the advisory execution lock (see execute_reviewer_spec.rb for why the
  # transactional-fixture connection cannot play that role).
  def raw_pg_session
    db_config = ActiveRecord::Base.connection_db_config.configuration_hash
    PG.connect(
      host: db_config[:host], port: db_config[:port], dbname: db_config[:database],
      user: db_config[:username], password: db_config[:password]
    )
  end

  it "executes every case on the worker, ends completed, and compiles the report" do
    queue_execution!
    allow(github_client).to receive(:compare_summary).and_return(comparison)
    allow(AgentHarness).to receive(:send_message).and_return(llm_response("within_scope"))

    perform_enqueued_jobs(only: described_class)

    evaluation.reload
    expect(evaluation).to be_completed
    expect(evaluation.runs.count).to eq(2)
    expect(evaluation.report_markdown).to be_present
  end

  it "records provider failures as not evaluated and ends failed with a report" do
    queue_execution!
    allow(github_client).to receive(:compare_summary).and_return(comparison)
    allow(AgentHarness).to receive(:send_message)
      .and_return(instance_double(AgentHarness::Response, success?: false, model: nil, output: nil, metadata: {}))

    perform_enqueued_jobs(only: described_class)

    evaluation.reload
    expect(evaluation).to be_failed
    expect(evaluation.runs).to all(be_not_evaluated)
    expect(evaluation.report_markdown).to be_present
  end

  it "ends partial when only some cases hold an evaluated verdict" do
    queue_execution!
    allow(github_client).to receive(:compare_summary).and_return(comparison)
    responses = [ llm_response("within_scope"),
                  instance_double(AgentHarness::Response, success?: false, model: nil, output: nil, metadata: {}) ]
    allow(AgentHarness).to receive(:send_message).and_return(*responses)

    perform_enqueued_jobs(only: described_class)

    evaluation.reload
    expect(evaluation).to be_partial
    expect(evaluation.last_failure_reason).to include("1 case(s)")
    expect(evaluation.report_markdown).to be_present
  end

  it "honors a cancellation requested while still queued, preserving collected evidence" do
    queue_execution!
    evaluation.runs.create!(case_id: "A-01", verdict: "within_scope", reviewer_run_id: "r1",
      reviewer_model: "m", prompt_digest: "d", cost_cents: 42, recorded_at: Time.current)
    IntentConformance::ShadowEvaluation::CancelExecution.call(evaluation: evaluation)
    allow(AgentHarness).to receive(:send_message)

    perform_enqueued_jobs(only: described_class)

    evaluation.reload
    expect(evaluation).to be_cancelled
    expect(evaluation.runs.count).to eq(1)
    expect(AgentHarness).not_to have_received(:send_message)
    expect(evaluation.report_markdown).to be_present
  end

  it "retries without repeating completed-case spend and ends completed" do
    queue_execution!
    allow(github_client).to receive(:compare_summary).and_return(comparison)
    responses = [ llm_response("within_scope"),
                  instance_double(AgentHarness::Response, success?: false, model: nil, output: nil, metadata: {}) ]
    allow(AgentHarness).to receive(:send_message).and_return(*responses)
    perform_enqueued_jobs(only: described_class)
    # Persisted status read — reloading the crafted instance here would drop
    # its pinned (stubbed) project association before the retry perform.
    expect(IntentConformanceShadowEvaluation.where(id: evaluation.id).pick(:status)).to eq("partial")

    IntentConformance::ShadowEvaluation::EnqueueExecution.call(evaluation: evaluation)
    allow(AgentHarness).to receive(:send_message).and_return(llm_response("material_drift"))

    perform_enqueued_jobs(only: described_class)

    evaluation.reload
    expect(evaluation).to be_completed
    # One invocation for A-01 (first pass) + one for A-02 (first pass) + one retry for A-02 only.
    expect(AgentHarness).to have_received(:send_message).exactly(3).times
  end

  it "releases the queued claim when another holder owns the advisory lock" do
    queue_execution!
    other = raw_pg_session
    begin
      other.exec_params("SELECT pg_try_advisory_lock($1, $2)",
        [ IntentConformance::ShadowEvaluation::ExecuteReviewer::ADVISORY_LOCK_NAMESPACE, evaluation.id ])
      allow(AgentHarness).to receive(:send_message)

      perform_enqueued_jobs(only: described_class)

      evaluation.reload
      expect(evaluation).to be_frozen
      expect(evaluation.last_failure_reason).to include("already in progress")
      expect(AgentHarness).not_to have_received(:send_message)
    ensure
      other.close
    end
  end

  it "marks a failed claim when validation refuses execution after the enqueue" do
    queue_execution!
    # Corpus changes between enqueue and the worker running: a new evidence
    # generation, refused closed by the executor.
    File.write(manifest_path, { "cases" => cases + [ corpus_case("A-03") ], "reviewer" => reviewer_identity }.to_yaml)

    perform_enqueued_jobs(only: described_class)

    evaluation.reload
    expect(evaluation).to be_failed
    expect(evaluation.last_failure_reason).to include("manifest changed")
    expect(evaluation.runs).to be_empty
  end

  it "discards cleanly when the evaluation no longer exists" do
    expect { described_class.perform_now(123_456_789) }.not_to raise_error
  end
end
