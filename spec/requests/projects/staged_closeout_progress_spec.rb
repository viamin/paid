# frozen_string_literal: true

require "rails_helper"

# @spec STAGED-CLOSEOUT-ADOPTION-014
RSpec.describe "Staged closeout progress" do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, created_by: owner) }
  let(:issue) { create(:issue, project:) }

  around do |example|
    prior = ENV["PAID_DEPLOYED_REVISION"]
    ENV["PAID_DEPLOYED_REVISION"] = "fixture-progress-request-target"
    example.run
  ensure
    ENV["PAID_DEPLOYED_REVISION"] = prior
  end

  before do
    sign_in owner
    FeatureFlags.enable!(:automation_phases, project:)
    Automation::PhaseSettings::Update.call(project:, user: owner, params: { "phases" => { "operations" => true } })
    StagedCloseoutAdoption::Enroll.call(project:, actor: owner, enabled: true)
    create(:agent_run, :completed, project:, issue:, goal: "analyze_issue", result_commit_sha: nil,
      reconciliation: { "assessment" => {
        "source_revision" => PartialCloseouts::Assessment.source_revision_for(issue),
        "intent_revision" => PartialCloseouts::Assessment.intent_revision_for(issue),
        "criteria" => [ { "criterion" => "Live request criterion", "state" => "unmet" } ], "gaps" => []
      } })
    StagedCloseoutAdoption::Mappings.approve(project:, actor: owner, issue:, attributes: {
      criterion_key: "Live request criterion", stage: "live_environment", phase: "operations", target_shape: "live_signal",
      execution_path: "trusted_measurement", target_key: "agent_planning_hold_reconciliation_closed_count",
      environment_class: Rails.env.to_s, freshness_seconds: 60 })
    CloseoutVerifications::AdmitLiveTarget.call(project:)
  end

  it "shows queued progress on the existing selected-issue acceptance page without starting another run" do
    expect do
      get project_staged_closeout_adoption_path(project), params: { issue_id: issue.id }
    end.not_to change(AgentRun, :count)
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("Scheduler not implemented")
    expect(response.body).to include("Acceptance verification", "Live request criterion", "Run state: Queued", "fixture-progress-request-target")
  end

  it "exposes the same selected progress through authenticated JSON and bearer-token API" do
    get project_staged_closeout_adoption_path(project), params: { issue_id: issue.id }, as: :json
    expect(response).to have_http_status(:ok)
    operator_progress = response.parsed_body.fetch("progress")
    expect(operator_progress.find { |row| row["id"] == "closeout_verification" }.fetch("state")).to eq("waiting")
    plaintext = "paid_pat_#{SecureRandom.urlsafe_base64(32)}"
    PersonalAccessToken.create!(user: owner, account:, name: "Fixture progress", scopes: %w[inbox],
      token_digest: PersonalAccessToken.digest(plaintext))
    get "/api/v1/projects/#{project.id}/staged_closeout_adoption", params: { issue_id: issue.id },
      headers: { "Authorization" => "Bearer #{plaintext}" }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("progress")).to eq(operator_progress)
  end

  it "rejects a selected issue belonging to another project" do
    other = create(:issue, project: create(:project, account:))
    get project_staged_closeout_adoption_path(project), params: { issue_id: other.id }, as: :json
    expect(response).to have_http_status(:not_found)
  end

  it "rejects bulk identifiers instead of treating them as a single selected issue" do
    get project_staged_closeout_adoption_path(project), params: { issue_id: [ issue.id ] }, as: :json
    expect(response).to have_http_status(:bad_request)
  end
end
