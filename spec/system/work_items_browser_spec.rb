# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Work-item browser", system_driver: :rack_test, type: :system do
  let!(:account) { create(:account) }
  let!(:user) { create(:user, :owner, account:, email: "owner@example.com", password: "password123") }
  let!(:project) { create(:project, account:, created_by: user) }
  let!(:work_item) { create(:work_item, account:, title: "Fix account navigation") }

  before do
    account.tenant_setting!.update!(features: { "unified_work_items" => true })
    create(:work_item_assignment, account:, work_item:, project:, default_execution: true)
  end

  def sign_in_as(user)
    visit new_user_session_path
    fill_in "Email", with: user.email
    fill_in "Password", with: "password123"
    click_button "Sign in"
  end

  # @spec UNIFIED-WORK-ITEMS-004 UNIFIED-WORK-ITEMS-005
  it "starts a run from an assigned browser ticket using its execution project" do
    sign_in_as(user)

    visit work_items_path

    expect(page).to have_content("Fix account navigation")
    click_link "Start run", match: :first

    expect(page).to have_current_path(new_project_agent_run_path(project, goal: "create_pr", work_item_id: work_item.id))
    expect(page).to have_content("Starting from linear ticket")
    expect(page).to have_field("work_item_id", type: "hidden", with: work_item.id.to_s)
  end
end
