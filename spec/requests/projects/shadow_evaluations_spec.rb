# frozen_string_literal: true

require "rails_helper"

# End-to-end UI flow for the solo-maintainer shadow evaluation: start from
# the Inbox entry point, label blinded (answers hidden), skip and resume,
# freeze, execute the reviewer, and revise — with tenant isolation and
# authorization enforced on direct links and actions.
# @spec INTENT-CONFORMANCE-ROLLOUT-005
# @spec INTENT-CONFORMANCE-ROLLOUT-006
# @spec INTENT-CONFORMANCE-ROLLOUT-009
RSpec.describe "Projects::ShadowEvaluations" do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account: account) }
  let(:member) { create(:user, :member, account: account) }
  let(:project) { create(:project, account: account, created_by: owner) }
  let(:manifest_path) { "docs/intent/intent-conformance-rollout/shadow-evaluation-manifest-2026-10-13.yml" }
  let(:manifest_commit) { `git rev-parse HEAD`.strip }
  let(:corpus_dir) { Dir.mktmpdir }

  before { sign_in owner }

  after { FileUtils.remove_entry(corpus_dir) }

  def start_evaluation!(actor: owner)
    post project_shadow_evaluations_path(project),
      params: { purpose: "rdr-067-measured-rollout", policy: "solo", manifest_path: manifest_path, manifest_commit: manifest_commit }
    evaluation = project.intent_conformance_shadow_evaluations.last
    expect(response).to redirect_to(project_shadow_evaluation_path(project, evaluation))
    evaluation
  end

  # The committed 2026-10-13 corpus pins a frozen reviewer prompt whose digest
  # the identity gate rejects by design, so reviewer-execution flows start
  # from a throwaway committed corpus carrying the current reviewer identity
  # (the same fixture shape the service specs use).
  def start_evaluation_from_committed_corpus!
    init_git_repo(corpus_dir)
    commit = git_write!(corpus_dir, "corpus-manifest.yml",
      { "cases" => full_strata_corpus_cases, "reviewer" => reviewer_identity }.to_yaml,
      "add corpus manifest")
    allow(Rails).to receive(:root).and_return(Pathname.new(corpus_dir))

    post project_shadow_evaluations_path(project),
      params: {
        purpose: "rdr-067-measured-rollout", policy: "solo",
        manifest_path: File.join(corpus_dir, "corpus-manifest.yml"), manifest_commit: commit
      }
    allow(Rails).to receive(:root).and_call_original

    evaluation = project.intent_conformance_shadow_evaluations.last
    expect(response).to redirect_to(project_shadow_evaluation_path(project, evaluation))
    evaluation
  end

  def label!(evaluation, case_id:, outcome:, claim: "approved claim", reason: "matches design")
    post label_project_shadow_evaluation_path(project, evaluation),
      params: { case_id: case_id, outcome: outcome, cited_design_claim: claim, reason: reason }
  end

  def skip!(evaluation, case_id:)
    post skip_project_shadow_evaluation_path(project, evaluation), params: { case_id: case_id }
  end

  def freeze!(evaluation)
    post freeze_project_shadow_evaluation_path(project, evaluation)
  end

  def expect_execution_queued_log(evaluation)
    expect(Rails.logger).to have_received(:info).with(
      hash_including(
        message: "intent_conformance.shadow_evaluation_execution_queued",
        project_id: project.id,
        shadow_evaluation_id: evaluation.id,
        actor_user_id: owner.id
      )
    )
  end

  it "starts from the Inbox entry point and resumes the same evaluation on repeated clicks" do
    evaluation = start_evaluation!
    expect(evaluation).to have_attributes(policy: "solo", status: "labeling", solo_maintainer: owner)

    post project_shadow_evaluations_path(project),
      params: { purpose: "rdr-067-measured-rollout", policy: "solo", manifest_path: manifest_path }

    expect(project.intent_conformance_shadow_evaluations.count).to eq(1)
    expect(response).to redirect_to(project_shadow_evaluation_path(project, evaluation))
  end

  it "refuses to start from a manifest that fails the CLI corpus-shape checks" do
    post project_shadow_evaluations_path(project),
      params: { purpose: "rdr-067-measured-rollout", policy: "solo", manifest_path: "tmp/undersized.yml" }

    expect(response).to redirect_to(new_project_shadow_evaluation_path(project))
    expect(flash[:alert]).to include("was not found")
    expect(project.intent_conformance_shadow_evaluations).to be_empty
  end

  it "hides strata, selection rationale, and reviewer outputs from the labeling screen until the reference set is frozen" do
    evaluation = start_evaluation!
    label!(evaluation, case_id: "A-01", outcome: "within_scope")

    get project_shadow_evaluation_path(project, evaluation)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("review_context_#{evaluation.id}_A-02")
    expect(response.body).not_to include("intentionally_drifted")
    expect(response.body).not_to include("stratum")
    expect(response.body).not_to include("Dependency maintenance commit")
    expect(response.body).to include("AI results stay hidden until you finish your review")
  end

  it "loads the change overview first without asking for a citation before evidence is ready" do # @spec INTENT-CONFORMANCE-ROLLOUT-013
    evaluation = start_evaluation!

    get project_shadow_evaluation_path(project, evaluation)

    expect(response).to have_http_status(:ok)
    page = Nokogiri::HTML(response.body)
    expect(page.at_css('turbo-frame[src*="review_context"]')).to be_present
    expect(page.at_css('[name="cited_design_claim"]')).to be_nil
    expect(response.body).to include("Finish my review", "does not approve individual pull requests")
    expect(response.body).not_to include("selection_rationale")
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-013
  it "recovers legacy requirements at the approved revision and keeps patches collapsed" do
    project.update!(owner: "viamin", repo: "paid")
    evaluation = start_evaluation!
    client = instance_double(GithubClient)
    allow(GithubClient).to receive(:new).and_return(client)
    allow(client).to receive(:compare).and_return(files: [
      { filename: "docs/intent/queue/queue-design.md", patch: "+<script>attack()</script>", additions: 1 }
    ])
    allow(client).to receive(:file_content).with("viamin/paid", path: "docs/intent/queue/queue-design.md", ref: "abe405ef806fdc32c31aa53d7aa61f026f9681a5")
      .and_return("# Queue requirements\nExplicit labels control selection.")

    get evidence_project_shadow_evaluation_path(project, evaluation, case_id: "A-01", kind: "review_context")

    page = Nokogiri::HTML(response.body)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Queue requirements", "What changed", "What was agreed", "&lt;script&gt;")
    expect(page.css("details[data-file-diff][open]")).to be_empty
    expect(page.at_css('select[name="cited_design_claim"]')).to be_present
    expect(evaluation.corpus.matches_recorded_digest?).to be(true)
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-013
  it "shows an evidence-preparation state instead of an impossible citation form" do
    project.update!(owner: "viamin", repo: "paid")
    evaluation = start_evaluation!
    client = instance_double(GithubClient)
    allow(GithubClient).to receive(:new).and_return(client)
    allow(client).to receive_messages(compare: { files: [] }, file_content: nil)

    get evidence_project_shadow_evaluation_path(project, evaluation, case_id: "A-01", kind: "review_context")

    expect(response.body).to include("Requirements need preparing", "Continue to the next change")
    expect(Nokogiri::HTML(response.body).at_css('[name="cited_design_claim"]')).to be_nil
    expect(evaluation.labels).to be_empty
  end

  it "keeps a skip route when pinned review evidence cannot be loaded" do # @spec INTENT-CONFORMANCE-ROLLOUT-013
    project.update!(owner: "viamin", repo: "paid")
    evaluation = start_evaluation!
    client = instance_double(GithubClient)
    allow(GithubClient).to receive(:new).and_return(client)
    allow(client).to receive(:compare).and_raise(Faraday::TimeoutError, "timed out")

    get evidence_project_shadow_evaluation_path(project, evaluation, case_id: "A-01", kind: "review_context")

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("The review evidence could not be loaded")
    expect(response.body).to include(skip_project_shadow_evaluation_path(project, evaluation))
  end

  it "allows uncertainty without inventing an approved requirement" do # @spec INTENT-CONFORMANCE-ROLLOUT-012
    evaluation = start_evaluation!
    label!(evaluation, case_id: "A-01", outcome: "uncertain", claim: "", reason: "No approved requirement is linked.")

    expect(evaluation.labels.find_by!(case_id: "A-01")).to have_attributes(outcome: "uncertain", cited_design_claim: "")
    label!(evaluation, case_id: "A-02", outcome: "within_scope", claim: "", reason: "Looks correct.")
    expect(evaluation.labels.find_by(case_id: "A-02")).to be_nil
  end

  it "supports durable save/resume and skips without counting skipped cases as completed" do
    evaluation = start_evaluation!
    label!(evaluation, case_id: "A-01", outcome: "within_scope")
    skip!(evaluation, case_id: "A-02")

    get project_shadow_evaluation_path(project, evaluation)

    expect(response.body).to include("1 of 30 reviewed").and include("1 left for later")
    expect(evaluation.reload.progress).to include(labeled: 1, skipped: 1, total: 30)

    freeze!(evaluation)
    follow_redirect!
    expect(response.body).to include("unlabeled or skipped")

    label!(evaluation, case_id: "A-02", outcome: "material_drift")
    (evaluation.corpus.case_ids - %w[A-01 A-02]).each { |case_id| label!(evaluation, case_id: case_id, outcome: "within_scope") }
    freeze!(evaluation)

    expect(evaluation.reload).to be_frozen
  end

  it "reveals answers only after freeze and never executes the reviewer before it" do
    evaluation = start_evaluation!
    label!(evaluation, case_id: "A-01", outcome: "within_scope")

    post execute_project_shadow_evaluation_path(project, evaluation)
    follow_redirect!

    expect(response.body).to include("frozen reference label set")
    expect(evaluation.runs).to be_empty

    label_all!(evaluation)
    freeze!(evaluation)
    get project_shadow_evaluation_path(project, evaluation)

    expect(response.body).to include("Intentionally drifted")
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-011
  it "queues reviewer execution promptly, then the worker records failures and its report" do
    evaluation = start_evaluation_from_committed_corpus!
    label_all!(evaluation)
    freeze!(evaluation)

    # Corpus cases reference a repository outside this project, so every
    # reviewer attempt fails closed and is recorded as not evaluated —
    # prerequisite validation is never presented as execution.
    allow(Rails.logger).to receive(:info)
    expect { post execute_project_shadow_evaluation_path(project, evaluation) }
      .to have_enqueued_job(ShadowEvaluationExecutionJob).with(project.id, evaluation.id)
    follow_redirect!

    expect(evaluation.reload).to be_queued
    expect(response.body).to include("Reviewer execution queued")
    expect_execution_queued_log(evaluation)

    ShadowEvaluationExecutionJob.perform_now(project.id, evaluation.id)

    expect(evaluation.reload).to be_failed
    evaluation.runs.each do |run|
      expect(run).to be_not_evaluated
      expect(run.failure_reason).to eq("case_repository_outside_project")
    end

    get project_shadow_evaluation_path(project, evaluation)

    expect(response.body).to include("Comparison report")
    expect(response.body).to include("solo")
  end

  it "re-establishes the background job for a durably queued evaluation" do
    evaluation = start_evaluation_from_committed_corpus!
    label_all!(evaluation)
    freeze!(evaluation)
    evaluation.update!(status: "queued", execution_enqueued_at: 1.minute.ago)

    expect { post execute_project_shadow_evaluation_path(project, evaluation) }
      .to have_enqueued_job(ShadowEvaluationExecutionJob).with(project.id, evaluation.id)
  end

  it "does not offer a retry action after execution completed" do
    evaluation = start_evaluation!
    label_all!(evaluation)
    freeze!(evaluation)
    evaluation.update!(status: "completed", completed_at: Time.current)

    get project_shadow_evaluation_path(project, evaluation)

    expect(response.body).not_to include("Retry remaining reviewer cases")
    expect(response.body).not_to include("Execute reviewer now")
  end

  it "appends post-result revisions without overwriting the original blinded label" do
    evaluation = start_evaluation!
    label_all!(evaluation)
    freeze!(evaluation)
    evaluation.runs.create!(case_id: "A-01", verdict: "material_drift", reviewer_run_id: "r1", reviewer_model: "m",
      prompt_digest: "d", cost_cents: 0, recorded_at: Time.current)
    evaluation.update_column(:status, "completed")

    post revise_project_shadow_evaluation_path(project, evaluation),
      params: { case_id: "A-01", revised_outcome: "material_drift", reason: "reviewer cited a constraint I missed" }
    follow_redirect!

    label = evaluation.labels.find_by(case_id: "A-01")
    expect(label.outcome).to eq("within_scope")
    expect(label.revised_outcome).to eq("material_drift")
    expect(response.body).to include("material_drift (was within_scope)")
  end

  it "rejects labeling by anyone other than the declared maintainer" do
    evaluation = start_evaluation!
    sign_in member

    label!(evaluation, case_id: "A-01", outcome: "within_scope")

    # Pundit denies the member's label action outright.
    expect(response).to redirect_to(root_path)
    expect(evaluation.labels).to be_empty
  end

  it "never reveals the maintainer's saved label to another account member before freeze" do
    evaluation = start_evaluation!
    label!(evaluation, case_id: "A-01", outcome: "within_scope", claim: "quoth-the-raven-claim", reason: "nevermore-reason")
    sign_in member

    get project_shadow_evaluation_path(project, evaluation, case_id: "A-01")

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("quoth-the-raven-claim")
    expect(response.body).not_to include("nevermore-reason")
  end

  it "validates project ownership on direct links (tenant isolation)" do
    evaluation = start_evaluation!
    outsider = create(:user, :owner, account: create(:account))
    sign_in outsider

    get project_shadow_evaluation_path(project, evaluation)

    expect(response).to have_http_status(:not_found)
  end

  it "validates tenant ownership before opening case evidence" do
    evaluation = start_evaluation!
    outsider = create(:user, :owner, account: create(:account))
    sign_in outsider

    get evidence_project_shadow_evaluation_path(project, evaluation, case_id: "A-01", kind: "diff")

    expect(response).to have_http_status(:not_found)
  end

  it "refuses evidence navigation when the corpus manifest no longer matches the frozen corpus" do
    evaluation = start_evaluation!
    evaluation.update!(manifest_digest: "stale")

    get evidence_project_shadow_evaluation_path(project, evaluation, case_id: "A-01", kind: "diff")

    expect(response).to redirect_to(project_shadow_evaluation_path(project, evaluation, case_id: "A-01"))
    expect(flash[:alert]).to eq("corpus manifest changed since the evaluation was created — start a new evaluation")
  end

  it "shows the corpus-changed warning when a frozen evaluation's manifest no longer matches" do
    evaluation = start_evaluation!
    label_all!(evaluation)
    freeze!(evaluation)
    evaluation.update!(manifest_digest: "changed")

    get project_shadow_evaluation_path(project, evaluation)

    expect(response.body).to include("The review sample has changed")
  end

  it "returns to the validated originating Inbox context and ignores arbitrary return URLs" do
    evaluation = start_evaluation!

    get project_shadow_evaluation_path(project, evaluation, inbox_kind: "partial_closeout", inbox_sort: "newest", inbox_entry_id: "unknown", return_to: "https://evil.example.com/steal")

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("/inbox?kind=partial_closeout&amp;project_id=#{project.id}&amp;sort=newest")
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-009
  it "uses action-oriented copy without exposing the internal purpose on evaluation screens" do
    get new_project_shadow_evaluation_path(project)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Review code changes against requirements")
    expect(response.body).to include("Start review")
    expect(response.body).to include("Your decisions help check whether the AI reviewer can reliably spot changes to agreed requirements.")
    expect(response.body).to include("Technical details")
    expect(response.body).not_to include("RDR-067")
    expect(response.body).not_to include("rdr-067-measured-rollout")
    expect(response.body).not_to include('name="purpose"')

    evaluation = start_evaluation!
    get project_shadow_evaluation_path(project, evaluation)

    expect(response.body).to include("Review code changes against requirements")
    expect(response.body).not_to include(evaluation.purpose)
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-009
  it "hides the internal identifier in a persisted report from before the copy change" do
    evaluation = start_evaluation!
    label_all!(evaluation)
    freeze!(evaluation)
    evaluation.update!(
      report_markdown: "# RDR-067 Solo-Maintainer Shadow Evaluation Report\n\nRecorded evidence.")

    get project_shadow_evaluation_path(project, evaluation)

    expect(response.body).to include("Conformance Review Evaluation Report")
    expect(response.body).not_to include("RDR-067")
    expect(evaluation.reload.report_markdown).to include("RDR-067")
  end
end
