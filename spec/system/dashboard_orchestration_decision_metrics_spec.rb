# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Dashboard orchestration decision metrics", type: :system do
  let!(:account) { create(:account) }
  let!(:user) do
    create(:user, :owner, account: account, email: "owner@example.com", password: "password123")
  end

  it "renders deferred decision metrics frame wiring on the dashboard shell" do
    visit new_user_session_path

    fill_in "Email", with: user.email
    fill_in "Password", with: "password123"
    click_button "Sign in"

    frame = page.find("turbo-frame#dashboard-decision-metrics", visible: false)

    expect(page).to have_content("Cumulative / Periodic Metrics")
    expect(frame["data-dashboard-frames-src"]).to eq(dashboard_decision_metrics_path(time_range: "cumulative"))
    expect(frame["src"]).to be_nil
    expect(page.find("[data-controller~='dashboard-frames']", visible: false)).to be_present
  end
end
