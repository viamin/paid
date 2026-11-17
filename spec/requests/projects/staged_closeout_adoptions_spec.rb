# frozen_string_literal: true

require "rails_helper"

# @spec STAGED-CLOSEOUT-ADOPTION-001 STAGED-CLOSEOUT-ADOPTION-002
RSpec.describe "Staged closeout adoption settings" do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, created_by: owner, auto_merge_mode: "all") }

  before { sign_in owner }

  # @spec STAGED-CLOSEOUT-ADOPTION-002
  it "offers enrollment and mapping review through an HTML operator page" do
    get project_staged_closeout_adoption_path(project)

    expect(response.media_type).to eq("text/html")
    expect(response.body).to include("Acceptance checks", "Enable acceptance checks")

    patch project_staged_closeout_adoption_path(project), params: { enabled: true }

    expect(response).to redirect_to(project_staged_closeout_adoption_path(project))
    follow_redirect!
    expect(response.body).to include("Disable acceptance checks", "Review a check")
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-006
  it "lets a maintainer inspect, replace and revoke a reviewed check without JSON requests" do
    StagedCloseoutAdoption::Enroll.call(project:, actor: owner, enabled: true)
    issue = create(:issue, project:)
    recipe = create(:pre_commit_requirement, project:, account:)
    original = approve_mapping(issue:, recipe:)

    get project_staged_closeout_adoption_path(project), params: { issue_id: issue.id }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("The report renders", "Approve reviewed check", recipe.name, "Reviewed by", "Reviewed at", "Review history")

    post mappings_project_staged_closeout_adoption_path(project), params: {
      issue_id: issue.id,
      mapping: { criterion_key: "The report renders", review_stage: "pre_merge:coding",
                 target_reference: "technical_prerequisite:#{recipe.id}",
                 freshness_seconds: 7200, retry_policy: { max_attempts: 1 } }
    }
    expect(response).to redirect_to(project_staged_closeout_adoption_path(project))
    expect(original.reload.status).to eq("superseded")
    replacement = project.staged_closeout_mappings.order(:revision).last
    expect(replacement).to have_attributes(revision: 2, reviewed_by: owner, freshness_seconds: 7200)

    delete mapping_project_staged_closeout_adoption_path(project, replacement.id)
    expect(response).to redirect_to(project_staged_closeout_adoption_path(project))
    expect(replacement.reload.status).to eq("revoked")
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-006
  it "renders an actionable HTML error for an invalid mapping without changing review history" do
    StagedCloseoutAdoption::Enroll.call(project:, actor: owner, enabled: true)
    issue = create(:issue, project:)
    recipe = create(:pre_commit_requirement, project:, account:)
    original = approve_mapping(issue:, recipe:)

    post mappings_project_staged_closeout_adoption_path(project), params: {
      issue_id: issue.id, mapping: { criterion_key: "Invented", target_reference: nil, review_stage: nil }
    }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include("missing required mapping attributes", 'role="alert"')
    expect(original.reload.status).to eq("approved")
    expect(project.staged_closeout_mappings.count).to eq(1)
  end

  def approve_mapping(issue:, recipe:, mapping_project: project)
    create(:agent_run, :completed, project: mapping_project, issue:, reconciliation: { "assessment" => {
      "source_revision" => PartialCloseouts::Assessment.source_revision_for(issue),
      "intent_revision" => PartialCloseouts::Assessment.intent_revision_for(issue),
      "criteria" => [ { "criterion" => "The report renders", "state" => "unmet" } ], "gaps" => []
    } })
    StagedCloseoutAdoption::Mappings.approve(
      project: mapping_project, actor: owner, issue:,
      attributes: { criterion_key: "The report renders", stage: "pre_merge", phase: "coding",
                    target_shape: "source_pr_head", execution_path: "technical_prerequisite",
                    target_key: recipe.id, freshness_seconds: 3600 }
    )
  end

  it "shows an inspectable default-off reason and lets an owner explicitly enroll" do
    get project_staged_closeout_adoption_path(project), as: :json

    expect(response.parsed_body).to include("enrollment" => { "enabled" => false }, "automatic_run_reason" => "project_not_enrolled")

    patch project_staged_closeout_adoption_path(project), params: { enabled: true }, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("enrollment", "enabled")).to be(true)
    expect(project.staged_closeout_enrollment.reload.reviewed_by).to eq(owner)
  end

  it "does not let an ordinary member alter adoption" do
    sign_in create(:user, :member, account:)

    patch project_staged_closeout_adoption_path(project), params: { enabled: true }, as: :json

    expect(response).to redirect_to(root_path)
    expect(project.staged_closeout_enrollment).to be_nil
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-004
  it "reports approved and revoked mapping eligibility precisely" do
    StagedCloseoutAdoption::Enroll.call(project:, actor: owner, enabled: true)
    issue = create(:issue, project:)
    recipe = create(:pre_commit_requirement, project:, account:)
    mapping = approve_mapping(issue:, recipe:)

    get project_staged_closeout_adoption_path(project), as: :json

    expect(response.parsed_body).to include("automatic_run_reason" => "scheduler_not_implemented")
    expect(response.parsed_body.fetch("mappings").sole).to include("eligibility_reason" => nil)

    StagedCloseoutAdoption::Mappings.revoke(mapping:, project:, actor: owner, issue:, attributes: {})
    get project_staged_closeout_adoption_path(project), as: :json

    expect(response.parsed_body).to include("automatic_run_reason" => "mapping_not_current")
    expect(response.parsed_body.fetch("mappings").sole).to include("eligibility_reason" => "mapping_not_current")
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-004
  it "reports stale assessments and target changes precisely" do
    StagedCloseoutAdoption::Enroll.call(project:, actor: owner, enabled: true)
    issue = create(:issue, project:)
    recipe = create(:pre_commit_requirement, project:, account:)
    approve_mapping(issue:, recipe:)

    issue.update!(body: "Changed acceptance intent")
    get project_staged_closeout_adoption_path(project), as: :json
    expect(response.parsed_body).to include("automatic_run_reason" => "closeout assessment is stale")

    target_project = create(:project, account:, created_by: owner)
    StagedCloseoutAdoption::Enroll.call(project: target_project, actor: owner, enabled: true)
    target_issue = create(:issue, project: target_project)
    target_recipe = create(:pre_commit_requirement, project: target_project, account:)
    approve_mapping(issue: target_issue, recipe: target_recipe, mapping_project: target_project)
    target_recipe.update!(command: "bin/changed-check")
    get project_staged_closeout_adoption_path(target_project), as: :json
    expect(response.parsed_body).to include("automatic_run_reason" => "target_changed_or_unavailable")
  end
end
