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
  let(:dir) { Dir.mktmpdir }
  let(:cases) { full_strata_corpus_cases }
  let(:manifest_path) { write_corpus_manifest(dir, cases) }
  let(:manifest_commit) { "e" * 40 }

  before { sign_in owner }

  after { FileUtils.remove_entry(dir) }

  def start_evaluation!(actor: owner)
    post project_shadow_evaluations_path(project),
      params: { purpose: "rdr-067-measured-rollout", policy: "solo", manifest_path: manifest_path, manifest_commit: manifest_commit }
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

  it "starts from the Inbox entry point and resumes the same evaluation on repeated clicks" do
    evaluation = start_evaluation!
    expect(evaluation).to have_attributes(policy: "solo", status: "labeling", solo_maintainer: owner)

    post project_shadow_evaluations_path(project),
      params: { purpose: "rdr-067-measured-rollout", policy: "solo", manifest_path: manifest_path }

    expect(project.intent_conformance_shadow_evaluations.count).to eq(1)
    expect(response).to redirect_to(project_shadow_evaluation_path(project, evaluation))
  end

  it "refuses to start from a manifest that fails the CLI corpus-shape checks" do
    undersized = File.join(dir, "undersized.yml")
    File.write(undersized, { "cases" => [ corpus_case("A-01") ] }.to_yaml)

    post project_shadow_evaluations_path(project),
      params: { purpose: "rdr-067-measured-rollout", policy: "solo", manifest_path: undersized }

    expect(response).to redirect_to(new_project_shadow_evaluation_path(project, purpose: "rdr-067-measured-rollout"))
    expect(flash[:alert]).to include("at least ten cases in each stratum")
    expect(project.intent_conformance_shadow_evaluations).to be_empty
  end

  it "hides strata and reviewer outputs from the labeling screen until the reference set is frozen" do
    evaluation = start_evaluation!
    label!(evaluation, case_id: "A-01", outcome: "within_scope")

    get project_shadow_evaluation_path(project, evaluation)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Case A-02")
    expect(response.body).not_to include("intentionally_drifted")
    expect(response.body).not_to include("stratum")
    expect(response.body).to include("Answers stay hidden until you freeze")
  end

  it "supports durable save/resume and skips without counting skipped cases as completed" do
    evaluation = start_evaluation!
    label!(evaluation, case_id: "A-01", outcome: "within_scope")
    skip!(evaluation, case_id: "A-02")

    get project_shadow_evaluation_path(project, evaluation)

    expect(response.body).to include("1 labeled").and include("1 skipped")
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

    expect(response.body).to include("intentionally_drifted")
  end

  it "executes the real reviewer through agent_harness, records failures as not evaluated, and shows the report" do
    evaluation = start_evaluation!
    label_all!(evaluation)
    freeze!(evaluation)

    # Corpus cases reference a repository outside this project, so every
    # reviewer attempt fails closed and is recorded as not evaluated —
    # prerequisite validation is never presented as execution.
    post execute_project_shadow_evaluation_path(project, evaluation)
    follow_redirect!

    expect(response.body).to include("not evaluated")
    expect(evaluation.reload).to be_failed
    evaluation.runs.each do |run|
      expect(run).to be_not_evaluated
      expect(run.failure_reason).to eq("case_repository_outside_project")
    end

    get project_shadow_evaluation_path(project, evaluation)

    expect(response.body).to include("Reproducible report")
    expect(response.body).to include("solo")
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

  it "shows the corpus-changed warning when a frozen evaluation's manifest no longer matches" do
    evaluation = start_evaluation!
    label_all!(evaluation)
    freeze!(evaluation)
    File.write(manifest_path, { "cases" => cases + [ corpus_case("A-99") ] }.to_yaml)

    get project_shadow_evaluation_path(project, evaluation)

    expect(response.body).to include("corpus manifest has changed")
  end

  it "returns only to the fixed Inbox context, never an arbitrary external return URL" do
    evaluation = start_evaluation!

    get project_shadow_evaluation_path(project, evaluation, return_to: "https://evil.example.com/steal")

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Back to Inbox")
  end

  it "surfaces the Start/Resume entry point on the partial-closeout Inbox item" do
    get new_project_shadow_evaluation_path(project, purpose: "rdr-067-measured-rollout")

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Start evaluation")
  end
end
