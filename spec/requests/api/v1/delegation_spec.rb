# frozen_string_literal: true

require "rails_helper"

# The delegation projection over the mobile API: the same shared read model
# the settings page and Inbox consume, so no API client infers authority
# from labels, approvals, or queue state.
# @spec PROJECT-DELEGATION-005
RSpec.describe "Project delegation API" do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, created_by: user) }
  let(:plaintext) { "paid_pat_#{SecureRandom.urlsafe_base64(32)}" }
  let(:headers) { { "Authorization" => "Bearer #{plaintext}", "Content-Type" => "application/json" } }

  before do
    PersonalAccessToken.create!(
      user:, account:, name: "Inbox", scopes: [ "inbox" ], token_digest: PersonalAccessToken.digest(plaintext)
    )
    FeatureFlags.enable!(:project_delegation, project:)
  end

  it "returns the shared delegation projection for the project" do
    work_item = create(:issue, project:)
    create(:bounded_delegated_action, project:, issue: work_item, action: "review",
      evidence: Automation::DelegatedActionAdmission.admission_evidence(
        work_item: work_item, action: "review", acceptance_refs: [ "AC-1" ], stop_before_phase: "merge"
      ))

    get "/api/v1/projects/#{project.id}/delegation", headers: headers

    expect(response).to have_http_status(:ok)
    payload = response.parsed_body
    expect(payload.fetch("project_id")).to eq(project.id)
    expect(payload.fetch("authorizations")).to include(
      hash_including(
        "action" => "review", "in_force" => true, "stop_before_phase" => "merge",
        "authority" => hash_including("permitted" => true)
      )
    )
    expect(payload).not_to include("phase_authority")
    expect(payload).to include("signature")
  end

  # @spec PROJECT-DELEGATION-001
  it "returns the effective posture with its revision and remaining reviews" do
    get "/api/v1/projects/#{project.id}/delegation", headers: headers

    posture = response.parsed_body.fetch("posture")
    expect(posture).to include(
      "level" => "conservative",
      "source" => "default",
      "revision" => 0,
      "enabled_action_classes" => []
    )
    expect(posture.fetch("remaining_reviews")).to be_an(Array)
    expect(posture).to include("policy_signature")
  end

  it "matches the projection the settings surface renders" do
    projection = ProjectDelegation::Projection.for_project(project).to_h

    get "/api/v1/projects/#{project.id}/delegation", headers: headers

    expect(response.parsed_body.fetch("signature")).to eq(projection.fetch(:signature))
  end

  it "rejects an unauthenticated request" do
    get "/api/v1/projects/#{project.id}/delegation"

    expect(response).to have_http_status(:unauthorized)
  end

  it "returns not found until the project opts in" do
    FeatureFlags.disable!(:project_delegation, project:)

    get "/api/v1/projects/#{project.id}/delegation", headers: headers

    expect(response).to have_http_status(:not_found)
  end

  it "hides other accounts' projects" do
    other_project = create(:project)

    get "/api/v1/projects/#{other_project.id}/delegation", headers: headers

    expect(response).to have_http_status(:not_found)
  end
end
