# frozen_string_literal: true

require "rails_helper"

# @spec STAGED-CLOSEOUT-ADOPTION-001 STAGED-CLOSEOUT-ADOPTION-002
RSpec.describe "Staged closeout adoption settings" do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, created_by: owner, auto_merge_mode: "all") }

  before { sign_in owner }

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
end
