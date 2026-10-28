# frozen_string_literal: true

require "rails_helper"

# End-to-end UI flow for the facet-confidence closeout evaluation from the
# partial-closeout Inbox entry point: start/resume a persisted evaluation for
# the originating closeout, record blinded reference judgments (expectations
# and shapes hidden), freeze, and read the compiled report that returns to the
# Inbox item — with authorization and tenant isolation enforced on direct
# links and actions.
# @spec FACET-CONFIDENCE-020
# @spec FACET-CONFIDENCE-021
# @spec FACET-CONFIDENCE-022
RSpec.describe "Projects::FacetConfidenceEvaluations" do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account: account) }
  let(:member) { create(:user, :member, account: account) }
  let(:github_token) { create(:github_token, account: account, created_by: owner) }
  let(:project) do
    create(:project, account: account, github_token: github_token, created_by: owner,
      owner: "acme", repo: "alpha", auto_pick_enabled: true, active: true)
  end
  # A stalled closeout that is continuation-eligible: merged child-PR evidence,
  # no unresolved blockers — the state the Inbox packet renders as ready.
  let(:issue) { create(:issue, project: project, github_number: 30, paid_state: "in_progress") }

  before do
    create(:issue, :pull_request, project: project, github_number: 31, github_state: "closed",
      pr_review_phase: "merged", parent_issue_id: issue.id, created_at: 2.days.ago)
    sign_in owner
  end

  def entry_id(entry_kind, record)
    "#{entry_kind}:#{record.id}"
  end

  def start_evaluation!(issue_id: issue.id)
    post project_facet_confidence_evaluations_path(project), params: { issue_id: issue_id }
    evaluation = issue.facet_confidence_evaluations.find_by(issue_id: issue_id)
    expect(response).to redirect_to(project_facet_confidence_evaluation_path(project, evaluation))
    evaluation
  end

  def judgment_params(corpus_case, overrides = {})
    expected = corpus_case.fetch("expected")
    references = corpus_case.fetch("evidence").map { |item| item.fetch("reference") }
    {
      verdict: expected.fetch("status"),
      intent_band: expected.fetch("intent_band"),
      technical_band: expected.fetch("technical_band"),
      readiness: expected.fetch("readiness"),
      cited_evidence_reference: (expected["must_cite"] || references).first,
      reason: "Re-derived from the cited statements."
    }.merge(overrides)
  end

  def label!(evaluation, corpus_case, overrides = {})
    post label_project_facet_confidence_evaluation_path(project, evaluation),
      params: { case_id: corpus_case.fetch("id"), **judgment_params(corpus_case, overrides) }
  end

  def label_all!(evaluation)
    evaluation.corpus.cases.each { |corpus_case| label!(evaluation, corpus_case) }
  end

  it "starts from the Inbox entry point and resumes the same evaluation on repeated clicks" do
    evaluation = start_evaluation!

    expect(evaluation).to have_attributes(status: "labeling", issue: issue, created_by: owner)

    post project_facet_confidence_evaluations_path(project), params: { issue_id: issue.id }

    expect(issue.facet_confidence_evaluations.count).to eq(1)
    expect(response).to redirect_to(project_facet_confidence_evaluation_path(project, evaluation))
  end

  it "starts from a typed Action Required escalation while preserving Inbox context" do
    notification = create(:notification, :error, account:, subject: issue,
      source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE, blocking: true,
      title: "Remediation Required", description: "Independent maintainers have entered and frozen the blinded reference judgments.",
      metadata: { "workflow" => FacetConfidence::CloseoutEvaluation::InboxEscalation::WORKFLOW })
    action_entry_id = entry_id(Inbox::Queue::ACTION_REQUIRED_KIND, notification)

    get inbox_entry_path(action_entry_id, project_id: project.id, kind: Inbox::Queue::ACTION_REQUIRED_KIND, sort: "newest")

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Independent evaluation needed", "independently reviews each frozen test case")
    expect(response.body).to include("0 of 8 judgments recorded; 8 remaining.")
    expect(response.body).to include("Start evaluation")
    expect(response.body).not_to include("Independent maintainers have entered and frozen the blinded reference judgments.")

    post project_facet_confidence_evaluations_path(project), params: {
      issue_id: issue.id, inbox_kind: Inbox::Queue::ACTION_REQUIRED_KIND, inbox_sort: "newest", inbox_entry_id: action_entry_id
    }
    evaluation = issue.facet_confidence_evaluations.sole

    expect(response).to redirect_to(project_facet_confidence_evaluation_path(project, evaluation,
      inbox_kind: Inbox::Queue::ACTION_REQUIRED_KIND, inbox_sort: "newest", inbox_entry_id: action_entry_id))
  end

  it "shows state-specific typed escalation progress and actions" do
    notification = create(:notification, :error, account:, subject: issue,
      source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE, blocking: true,
      title: "Remediation Required", description: "Internal closeout prose.",
      metadata: { "workflow" => FacetConfidence::CloseoutEvaluation::InboxEscalation::WORKFLOW })
    action_entry_id = entry_id(Inbox::Queue::ACTION_REQUIRED_KIND, notification)
    evaluation = start_evaluation!

    get inbox_entry_path(action_entry_id, project_id: project.id, kind: Inbox::Queue::ACTION_REQUIRED_KIND)
    expect(response.body).to include("Resume evaluation", "0 of 8 judgments recorded; 8 remaining.")

    label!(evaluation, evaluation.corpus.find_case("FC-CORPUS-01"))
    get inbox_entry_path(action_entry_id, project_id: project.id, kind: Inbox::Queue::ACTION_REQUIRED_KIND)
    expect(response.body).to include("Continue judging", "1 of 8 judgments recorded; 7 remaining.")

    evaluation.corpus.cases.drop(1).each { |corpus_case| label!(evaluation, corpus_case) }
    get inbox_entry_path(action_entry_id, project_id: project.id, kind: Inbox::Queue::ACTION_REQUIRED_KIND)
    expect(response.body).to include("Freeze judgments", "8 of 8 judgments recorded; 0 remaining.")
  end

  it "refuses to start for an originating work item outside the project" do
    other_project = create(:project, account: account, created_by: owner)
    other_issue = create(:issue, project: other_project, github_number: 99)

    post project_facet_confidence_evaluations_path(project), params: { issue_id: other_issue.id }

    expect(response).to have_http_status(:not_found)
    expect(other_issue.facet_confidence_evaluations).to be_empty
  end

  it "hides frozen expectations and shapes from the labeling screen until the reference set is frozen" do
    evaluation = start_evaluation!
    label!(evaluation, evaluation.corpus.find_case("FC-CORPUS-01"))

    get project_facet_confidence_evaluation_path(project, evaluation)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Case FC-CORPUS-02")
    expect(response.body).not_to include("provisional_direction")
    expect(response.body).not_to include("boundary_79_80")
    expect(response.body).not_to include("Tentative exploration is not explicit direction")
    expect(response.body).to include("Answers stay hidden until you freeze")
  end

  it "falls back to the next pending case for a case id outside the corpus" do
    evaluation = start_evaluation!
    label!(evaluation, evaluation.corpus.find_case("FC-CORPUS-01"))

    get project_facet_confidence_evaluation_path(project, evaluation, case_id: "FC-CORPUS-99")

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Case FC-CORPUS-02")
    expect(response.body).not_to include("Every case is judged")
  end

  it "shows the judge's own saved judgment for save/resume without revealing it to other members" do
    evaluation = start_evaluation!
    label!(evaluation, evaluation.corpus.find_case("FC-CORPUS-01"),
      reason: "quoth-the-raven-reason")

    get project_facet_confidence_evaluation_path(project, evaluation, case_id: "FC-CORPUS-01")
    expect(response.body).to include("quoth-the-raven-reason")

    sign_in member
    get project_facet_confidence_evaluation_path(project, evaluation, case_id: "FC-CORPUS-01")

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("quoth-the-raven-reason")
  end

  it "records judgments, freezes the reference set, and shows the compiled report" do
    evaluation = start_evaluation!
    label_all!(evaluation)

    post freeze_project_facet_confidence_evaluation_path(project, evaluation)

    expect(evaluation.reload).to be_frozen
    expect(response).to redirect_to(project_facet_confidence_evaluation_path(project, evaluation))
    follow_redirect!

    expect(response.body).to include("Reference set frozen")
    expect(response.body).to include("FC-CORPUS-01")
    expect(response.body).to include("Frozen expectations")
    expect(response.body).not_to include("Execute reviewer")
  end

  it "lets the sole judge append and inspect post-freeze corrections from the report" do
    evaluation = start_evaluation!
    label_all!(evaluation)
    post freeze_project_facet_confidence_evaluation_path(project, evaluation)

    corpus_case = evaluation.corpus.find_case("FC-CORPUS-01")
    post revise_project_facet_confidence_evaluation_path(project, evaluation),
      params: { case_id: corpus_case.fetch("id"), **judgment_params(corpus_case, reason: "Corrected after review.") }

    expect(response).to redirect_to(project_facet_confidence_evaluation_path(project, evaluation))
    expect(evaluation.labels.find_by!(case_id: corpus_case.fetch("id")).revisions).to have_attributes(count: 1)

    follow_redirect!

    expect(response.body).to include("Append correction")
    expect(response.body).to include("Corrections")
    expect(response.body).to include("Corrected after review.")
  end

  it "rejects labeling by anyone other than the operator who started the evaluation" do
    evaluation = start_evaluation!
    sign_in member

    label!(evaluation, evaluation.corpus.find_case("FC-CORPUS-01"))

    expect(response).to redirect_to(root_path)
    expect(evaluation.labels).to be_empty
  end

  it "validates project ownership on direct links (tenant isolation)" do
    evaluation = start_evaluation!
    outsider = create(:user, :owner, account: create(:account))
    sign_in outsider

    get project_facet_confidence_evaluation_path(project, evaluation)

    expect(response).to have_http_status(:not_found)
  end

  it "returns to the validated originating Inbox context and ignores arbitrary return URLs" do
    evaluation = start_evaluation!

    get project_facet_confidence_evaluation_path(project, evaluation,
      inbox_kind: "partial_closeout", inbox_sort: "newest", inbox_entry_id: "unknown",
      return_to: "https://evil.example.com/steal")

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("/inbox?kind=partial_closeout&amp;project_id=#{project.id}&amp;sort=newest")
  end

  it "surfaces the Start/Resume entry point on the partial-closeout Inbox item" do
    start_link = new_project_facet_confidence_evaluation_path(project, issue_id: issue.id,
      inbox_entry_id: entry_id(Inbox::Queue::PARTIAL_CLOSEOUT_KIND, issue), inbox_kind: Inbox::Queue::PARTIAL_CLOSEOUT_KIND)

    get inbox_entry_path(entry_id(Inbox::Queue::PARTIAL_CLOSEOUT_KIND, issue),
      project_id: project.id, kind: Inbox::Queue::PARTIAL_CLOSEOUT_KIND)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(start_link.gsub("&", "&amp;"))
    expect(response.body).not_to include("operator-runbook.md")

    evaluation = start_evaluation!
    get inbox_entry_path(entry_id(Inbox::Queue::PARTIAL_CLOSEOUT_KIND, issue),
      project_id: project.id, kind: Inbox::Queue::PARTIAL_CLOSEOUT_KIND)

    expect(response.body).to include(project_facet_confidence_evaluation_path(project, evaluation))

    label_all!(evaluation)
    post freeze_project_facet_confidence_evaluation_path(project, evaluation)
    get inbox_entry_path(entry_id(Inbox::Queue::PARTIAL_CLOSEOUT_KIND, issue),
      project_id: project.id, kind: Inbox::Queue::PARTIAL_CLOSEOUT_KIND)

    expect(response.body).to include("Open evaluation and report")
  end

  it "keeps the entry point blocked while the closeout records an unresolved prerequisite" do
    prerequisite = create(:issue, project: project, github_number: 41, github_state: "open")
    create(:issue_dependency, issue: issue, depends_on_issue: prerequisite)

    get inbox_entry_path(entry_id(Inbox::Queue::PARTIAL_CLOSEOUT_KIND, issue),
      project_id: project.id, kind: Inbox::Queue::PARTIAL_CLOSEOUT_KIND)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Evaluation is not ready")
    expect(response.body).to include("#41")
    expect(response.body).not_to include("/facet_confidence_evaluations/new")
  end
end
