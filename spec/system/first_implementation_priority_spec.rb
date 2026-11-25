# frozen_string_literal: true

require "rails_helper"
require "warden/test/helpers"

RSpec.describe "First implementation priority request", type: :system do
  include Warden::Test::Helpers

  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, created_by: user, auto_pick_enabled: true, active: true) }

  before do
    Warden.test_mode!
    login_as(user, scope: :user)
  end

  after { Warden.test_reset! }

  it "renders a confirmation-gated request for an eligible queued run" do # @spec QUEUE-TIER-010
    issue = create(:issue, project:, github_state: "open")
    run = create(:agent_run, :queued, :automatic, project:, issue:, goal: "create_pr", auto_pick: true,
      initiating_user: user, execution_origin: "paid_native")

    visit project_agent_run_path(project, run)

    form = page.find("form[action='#{prioritize_first_implementation_project_agent_runs_path(project)}']")
    expect(form).to have_field("agent_run_id", type: :hidden, with: run.id)
    expect(form).to have_field("confirmed", type: :hidden, with: "true")
    expect(form["data-turbo-confirm"]).to include("scheduling priority")
    expect(form).to have_button("Request priority")
  end

  it "does not render the request for an operator without run permission" do # @spec QUEUE-TIER-010
    viewer = create(:user, :viewer, account:)
    issue = create(:issue, project:, github_state: "open")
    run = create(:agent_run, :queued, :automatic, project:, issue:, goal: "create_pr", auto_pick: true,
      initiating_user: user, execution_origin: "paid_native")
    logout(:user)
    login_as(viewer, scope: :user)

    visit project_agent_run_path(project, run)

    expect(page).not_to have_css(
      "form[action='#{prioritize_first_implementation_project_agent_runs_path(project)}']"
    )
  end
end
