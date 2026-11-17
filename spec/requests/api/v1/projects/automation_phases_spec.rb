# frozen_string_literal: true

require "rails_helper"

# @spec AUTOMATION-PHASES-002 @spec AUTOMATION-PHASES-008
# @spec AUTOMATION-PHASES-009 @spec AUTOMATION-PHASES-016
RSpec.describe "Project automation phases API" do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, created_by: owner) }
  let(:plaintext) { "paid_pat_#{SecureRandom.urlsafe_base64(32)}" }
  let(:headers) { { "Authorization" => "Bearer #{plaintext}", "Content-Type" => "application/json" } }

  before do
    PersonalAccessToken.create!(user: owner, account:, name: "Automation", scopes: [ "inbox" ],
      token_digest: PersonalAccessToken.digest(plaintext))
  end

  it "inspects all phase controls, retained values, and active grants" do
    project.update!(automation_phase_settings: { "phases" => { "coding" => false }, "release" => true, "deployment" => false })
    grant = create(:work_item_continuation_grant, project:, issue: create(:issue, project:), start_phase: "coding", endpoint: "merge")

    get "/api/v1/projects/#{project.id}/automation_phases", headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      "rollout_enabled" => false,
      "settings" => hash_including("phases" => include("coding" => false), "release" => true, "deployment" => false),
      "continuation_notice" => include("does not disable independent project automation")
    )
    expect(response.parsed_body.fetch("grants")).to include(hash_including("id" => grant.id, "endpoint" => "merge"))
  end

  it "updates settings through the validated transition service" do
    project.update!(automation_phase_settings: {
      "phases" => { "discovery" => true, "coding" => false }, "release" => false, "deployment" => false
    })

    patch "/api/v1/projects/#{project.id}/automation_phases", params: {
      automation_phase_settings: { phases: { coding: true }, release: true, deployment: false }
    }.to_json, headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("enabled_transitions")).to include("coding")
    expect(Automation::PhaseSettings.call(project.reload)).to have_attributes(
      release_enabled?: true, deployment_enabled?: false, phases: include("discovery" => true, "coding" => true)
    )
  end

  it "revokes idempotently and extends only with merge delegation" do
    grant = create(:work_item_continuation_grant, project:, issue: create(:issue, project:), start_phase: "coding", endpoint: "coding")

    patch "/api/v1/projects/#{project.id}/automation_phases/continuation_grants/#{grant.id}",
      params: { endpoint: "merge" }.to_json, headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("extended" => true, "grant" => hash_including("endpoint" => "merge"))

    delete "/api/v1/projects/#{project.id}/automation_phases/continuation_grants/#{grant.id}", headers: headers
    expect(response.parsed_body).to include("revoked" => true)
    delete "/api/v1/projects/#{project.id}/automation_phases/continuation_grants/#{grant.id}", headers: headers
    expect(response.parsed_body).to include("revoked" => false)
  end

  it "does not expose another tenant's project or grant" do
    other_project = create(:project)
    get "/api/v1/projects/#{other_project.id}/automation_phases", headers: headers
    expect(response).to have_http_status(:not_found)
  end

  it "rejects an inactive grant extension" do
    grant = create(:work_item_continuation_grant, project:, issue: create(:issue, project:), completed_at: Time.current)

    patch "/api/v1/projects/#{project.id}/automation_phases/continuation_grants/#{grant.id}",
      params: { endpoint: "merge" }.to_json, headers: headers

    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body.dig("error", "message")).to include("inactive")
  end

  it "forbids a viewer from changing settings or grants" do
    viewer = create(:user, :viewer, account:)
    viewer_token = "paid_pat_#{SecureRandom.urlsafe_base64(32)}"
    PersonalAccessToken.create!(user: viewer, account:, name: "Viewer", scopes: [ "inbox" ], token_digest: PersonalAccessToken.digest(viewer_token))
    viewer_headers = headers.merge("Authorization" => "Bearer #{viewer_token}")

    patch "/api/v1/projects/#{project.id}/automation_phases", params: { automation_phase_settings: { phases: { coding: true } } }.to_json, headers: viewer_headers

    expect(response).to have_http_status(:forbidden)
  end
end
