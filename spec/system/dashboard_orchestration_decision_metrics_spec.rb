# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Dashboard orchestration decision metrics", type: :system do
  def create_decision(project:, status:, decision_type:, actor:, run_trait:, created_at:)
    create(:orchestration_decision,
      project: project,
      agent_run: create(:agent_run, run_trait, project: project),
      decision_type: decision_type,
      actor: actor,
      context: { decision_status: status },
      created_at: created_at)
  end

  def sign_in_as(user)
    visit new_user_session_path
    fill_in "Email", with: user.email
    fill_in "Password", with: "password123"
    click_button "Sign in"
  end

  def create_status_breakdown(project)
    create_decision(
      project: project,
      status: "applied",
      decision_type: "retry",
      actor: "timeout_auto_retry",
      run_trait: :completed,
      created_at: Time.current
    )
    create_decision(
      project: project,
      status: "deferred",
      decision_type: "escalate",
      actor: "coordination_escalation_service",
      run_trait: :failed,
      created_at: 1.hour.ago
    )
  end

  let!(:account) { create(:account) }
  let!(:user) do
    create(:user, :owner, account: account, email: "owner@example.com", password: "password123")
  end
  let!(:project) { create(:project, account: account, name: "Alpha", owner: "acme", repo: "alpha") }

  it "renders deferred decision metrics frame wiring on the dashboard shell" do
    sign_in_as(user)

    frame = page.find("turbo-frame#dashboard-decision-metrics", visible: false)

    expect(page).to have_content("Cumulative / Periodic Metrics")
    expect(frame["data-dashboard-frames-src"]).to eq(dashboard_decision_metrics_path(time_range: "cumulative"))
    expect(frame["src"]).to be_nil
    expect(page.find("[data-controller~='dashboard-frames']", visible: false)).to be_present
  end

  it "renders decision metrics sections and actor context in the frame endpoint" do
    create_status_breakdown(project)
    sign_in_as(user)
    visit dashboard_decision_metrics_path(time_range: "cumulative")

    expect(page).to have_content("Orchestration Decision Metrics")
    expect(page).to have_content("Outcomes by Decision Type")
    expect(page).to have_content("Recorded Decision Statuses")
    expect(page).to have_content("Decision Actors")
    expect(page).to have_content("timeout_auto_retry")
    expect(page).to have_content("Project Context")
  end
end
