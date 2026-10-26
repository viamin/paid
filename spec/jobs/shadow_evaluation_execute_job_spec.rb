# frozen_string_literal: true

require "rails_helper"

# The background execution job: honors a queued cancellation before the first
# reviewer invocation, records a precondition failure as a failed pass, never
# touches lifecycle state another worker owns, compiles available reports
# through the existing service, and marks interruption instead of stranding
# the evaluation as running.
# @spec INTENT-CONFORMANCE-ROLLOUT-007
# @spec INTENT-CONFORMANCE-ROLLOUT-011
RSpec.describe ShadowEvaluationExecuteJob, :job do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account: account) }
  let(:project) { create(:project, account: account, created_by: owner) }
  let(:dir) { Dir.mktmpdir }
  let(:cases) { %w[A-01 A-02].map { |id| corpus_case(id, "repository" => "#{project.owner}/#{project.repo}") } }
  let(:manifest_path) { write_corpus_manifest(dir, cases) }
  let(:evaluation) do
    create(:intent_conformance_shadow_evaluation, project: project, solo_maintainer: owner, created_by: owner,
      manifest_path: manifest_path, manifest_digest: Digest::SHA256.file(manifest_path).hexdigest)
  end
  let(:github_client) { instance_double(GithubClient) }

  before do
    allow_any_instance_of(Project).to receive(:client).and_return(github_client) # rubocop:disable RSpec/AnyInstance
  end

  after { FileUtils.remove_entry(dir) }

  def comparison
    { files: [ { filename: "app/models/widget.rb", status: "modified", additions: 3, deletions: 1, patch: "@@ widget code" } ] }
  end

  def llm_response(outcome)
    instance_double(AgentHarness::Response, success?: true, model: IntentConformance::ReviewerLlm::DEFAULT_MODEL,
      output: { outcome: outcome, cited_design_claims: [ "blue" ], cited_diff_locations: [ { "file" => "app/models/widget.rb", "note" => "color" } ], reasoning_summary: "ok" }.to_json,
      metadata: { cost_cents: 42 })
  end

  def prepare_labels!
    IntentConformance::ShadowEvaluation::RecordLabel.call(evaluation: evaluation, actor: owner, case_id: "A-01",
      outcome: "within_scope", cited_design_claim: "claim", reason: "matches")
    IntentConformance::ShadowEvaluation::RecordLabel.call(evaluation: evaluation, actor: owner, case_id: "A-02",
      outcome: "material_drift", cited_design_claim: "claim", reason: "drifts")
    evaluation.update!(status: "frozen", labels_frozen_at: Time.current)
  end

  it "executes the reviewer in the background and compiles the report through the existing service" do
    prepare_labels!
    allow(github_client).to receive_messages(file_content: "# design", compare_summary: comparison)
    allow(AgentHarness).to receive(:send_message).and_return(llm_response("within_scope"))
    evaluation.update!(status: "queued", execution_queued_at: Time.current)

    described_class.perform_now(evaluation.id)

    evaluation.reload
    expect(evaluation).to be_completed
    expect(evaluation.runs.count).to eq(2)
    expect(evaluation.report_markdown).to be_present
  end

  it "honors a cancellation requested while queued before any reviewer invocation" do
    prepare_labels!
    evaluation.update!(status: "queued", execution_queued_at: Time.current, cancel_requested_at: Time.current)
    allow(AgentHarness).to receive(:send_message)

    described_class.perform_now(evaluation.id)

    evaluation.reload
    expect(evaluation).to be_cancelled
    expect(evaluation.runs).to be_empty
    expect(AgentHarness).not_to have_received(:send_message)
  end

  it "records a precondition failure after enqueue as a failed pass with the reason" do
    prepare_labels!
    evaluation.update!(status: "queued", execution_queued_at: Time.current)
    evaluation.update_column(:manifest_digest, "stale")

    described_class.perform_now(evaluation.id)

    evaluation.reload
    expect(evaluation).to be_failed
    expect(evaluation.last_failure_reason).to include("manifest changed")
  end

  it "leaves the lifecycle alone when another worker already owns the advisory lock" do
    prepare_labels!
    evaluation.update!(status: "running", execute_started_at: Time.current, execution_heartbeat_at: 1.second.ago)
    allow(AgentHarness).to receive(:send_message)
    other_session = PG.connect(*raw_pg_args)
    begin
      other_session.exec_params("SELECT pg_try_advisory_lock($1, $2)",
        [ IntentConformance::ShadowEvaluation::ExecuteReviewer::ADVISORY_LOCK_NAMESPACE, evaluation.id ])

      described_class.perform_now(evaluation.id)

      evaluation.reload
      expect(evaluation).to be_running
      expect(AgentHarness).not_to have_received(:send_message)
    ensure
      other_session.close
    end
  end

  it "marks an interrupted pass from persisted evidence instead of stranding it as running" do
    prepare_labels!
    evaluation.update!(status: "running", execute_started_at: Time.current, execution_heartbeat_at: Time.current)
    evaluation.runs.create!(case_id: "A-01", verdict: "within_scope", reviewer_run_id: "r1",
      reviewer_model: IntentConformance::ReviewerLlm::DEFAULT_MODEL, prompt_digest: "d", cost_cents: 7, recorded_at: Time.current)
    allow(github_client).to receive_messages(file_content: "# design", compare_summary: comparison)
    # A provider hang surfacing as an unexpected error escapes ReviewerLlm's
    # harness rescue; the worker dies mid-pass like a killed process would.
    allow(AgentHarness).to receive(:send_message).and_raise(Timeout::Error)

    expect { described_class.perform_now(evaluation.id) }.to raise_error(Timeout::Error)

    evaluation.reload
    expect(evaluation).to be_partial
    expect(evaluation.last_failure_reason).to include("interrupted")
    expect(evaluation.report_markdown).to be_present
  end

  it "is a no-op for a missing or terminal evaluation" do
    expect { described_class.perform_now(-1) }.not_to raise_error

    evaluation.update!(status: "completed")
    allow(AgentHarness).to receive(:send_message)

    expect { described_class.perform_now(evaluation.id) }.not_to raise_error
    expect(AgentHarness).not_to have_received(:send_message)
  end

  private

  def raw_pg_args
    db_config = ActiveRecord::Base.connection_db_config.configuration_hash
    [ { host: db_config[:host], port: db_config[:port], dbname: db_config[:database],
        user: db_config[:username], password: db_config[:password] } ]
  end
end
