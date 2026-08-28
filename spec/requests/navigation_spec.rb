# frozen_string_literal: true

require "rails_helper"

# @spec OPERATOR-INBOX-010
RSpec.describe "Navigation" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }

  before { sign_in user }

  it "places Inbox as a top-level desktop nav item right after Dashboard and before Projects" do
    get dashboard_path

    expect(response).to have_http_status(:ok)
    document = Nokogiri::HTML(response.body)
    desktop_nav = document.at_css("div.hidden.lg\\:flex.lg\\:items-center")
    top_level_links = desktop_nav.css("a").map { |link| link.text.strip }

    dashboard_index = top_level_links.index("Dashboard")
    inbox_index = top_level_links.index("Inbox")
    projects_index = top_level_links.index("Projects")

    expect(inbox_index).to eq(dashboard_index + 1)
    expect(projects_index).to eq(inbox_index + 1)
  end

  it "places Inbox in the mobile menu right after Dashboard and before Projects" do
    get dashboard_path

    document = Nokogiri::HTML(response.body)
    mobile_menu = document.at_css("#mobile-menu")
    top_level_links = mobile_menu.css("a").map { |link| link.text.strip }

    dashboard_index = top_level_links.index("Dashboard")
    inbox_index = top_level_links.index("Inbox")
    projects_index = top_level_links.index("Projects")

    expect(inbox_index).to eq(dashboard_index + 1)
    expect(projects_index).to eq(inbox_index + 1)
  end

  it "removes Inbox from the Insights dropdown on desktop and mobile" do
    get dashboard_path

    document = Nokogiri::HTML(response.body)
    insights_menu = document.at_css("#insights-menu")
    mobile_menu = document.at_css("#mobile-menu")

    expect(insights_menu.css("a").map { |link| link.text.strip }).not_to include("Inbox")
    expect(insights_menu.at_css(%(a[href="#{inbox_path}"]))).to be_nil
    expect(mobile_menu.css(%(a[href="#{inbox_path}"])).size).to eq(1)
  end

  it "renders the Inbox nav badge as a lazy Turbo Frame pointing at the count endpoint, not an inline count" do
    get dashboard_path

    document = Nokogiri::HTML(response.body)
    desktop_frame = document.at_css("turbo-frame#inbox_nav_badge_desktop")
    mobile_frame = document.at_css("turbo-frame#inbox_nav_badge_mobile")

    expect(desktop_frame["loading"]).to eq("lazy")
    expect(desktop_frame["src"]).to eq(inbox_count_path)
    expect(mobile_frame["loading"]).to eq("lazy")
    expect(mobile_frame["src"]).to eq(inbox_count_path)
  end
end
