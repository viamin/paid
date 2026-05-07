# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Dashboard orchestration decision metrics", type: :system do
  let!(:account) { create(:account) }
  let!(:user) do
    create(:user, :owner, account: account, email: "owner@example.com", password: "password123")
  end

  it "shows the lazy-loaded decision metrics frame on the dashboard" do
    visit new_user_session_path

    fill_in "Email", with: user.email
    fill_in "Password", with: "password123"
    click_button "Sign in"

    frame = page.find("turbo-frame#dashboard-decision-metrics", visible: false)

    expect(page).to have_content("Cumulative / Periodic Metrics")
    expect(frame["src"]).to eq(dashboard_decision_metrics_path(time_range: "cumulative"))
    expect(frame["loading"]).to eq("lazy")
  end
end
