# frozen_string_literal: true

require "rails_helper"

# @spec STAGED-CLOSEOUT-ADOPTION-001 STAGED-CLOSEOUT-ADOPTION-002 STAGED-CLOSEOUT-ADOPTION-004
RSpec.describe "Staged closeout adoption API" do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, created_by: owner) }
  let(:plaintext) { "paid_pat_#{SecureRandom.urlsafe_base64(32)}" }
  let(:headers) do
    PersonalAccessToken.create!(user: owner, account:, name: "API", scopes: %w[inbox],
      token_digest: PersonalAccessToken.digest(plaintext))
    { "Authorization" => "Bearer #{plaintext}" }
  end

  def mapping_dependencies
    issue = create(:issue, project:)
    recipe = create(:pre_commit_requirement, project:, account:)
    create(:agent_run, :completed, project:, issue:, reconciliation: { "assessment" => {
      "source_revision" => PartialCloseouts::Assessment.source_revision_for(issue),
      "intent_revision" => PartialCloseouts::Assessment.intent_revision_for(issue),
      "criteria" => [ { "criterion" => "API parity", "state" => "unmet" } ], "gaps" => []
    } })
    [ issue, recipe ]
  end

  it "lets an authorized API maintainer inspect and manage enrollment and mappings" do
    patch "/api/v1/projects/#{project.id}/staged_closeout_adoption",
      params: { enabled: true }, headers:, as: :json
    expect(response).to have_http_status(:ok)

    issue, recipe = mapping_dependencies
    post "/api/v1/projects/#{project.id}/staged_closeout_adoption/mappings", params: {
      issue_id: issue.id,
      mapping: { criterion_key: "API parity", stage: "pre_merge", phase: "coding",
                 target_shape: "source_pr_head", execution_path: "technical_prerequisite",
                 target_key: recipe.id, freshness_seconds: 60 }
    }, headers:, as: :json
    expect(response).to have_http_status(:created)
    expect(response.parsed_body.fetch("mapping")).to include("reviewed_by_id" => owner.id)
    mapping_id = response.parsed_body.dig("mapping", "id")

    get "/api/v1/projects/#{project.id}/staged_closeout_adoption", headers: headers
    expect(response.parsed_body).to include("automatic_run_reason" => "waiting_for_source_pr_verification")
    expect(response.parsed_body.fetch("enrollment")).to include("reviewed_by_id" => owner.id)

    delete "/api/v1/projects/#{project.id}/staged_closeout_adoption/mappings/#{mapping_id}", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("mapping", "status")).to eq("revoked")
  end

  it "enforces the same ProjectPolicy update authorization as the operator surface" do
    viewer = create(:user, :viewer, account:)
    viewer_plaintext = "paid_pat_#{SecureRandom.urlsafe_base64(32)}"
    PersonalAccessToken.create!(user: viewer, account:, name: "Viewer", scopes: %w[inbox],
      token_digest: PersonalAccessToken.digest(viewer_plaintext))

    patch "/api/v1/projects/#{project.id}/staged_closeout_adoption", params: { enabled: true },
      headers: { "Authorization" => "Bearer #{viewer_plaintext}" }, as: :json

    expect(response).to have_http_status(:forbidden)
    expect(project.staged_closeout_enrollment).to be_nil
  end
end
