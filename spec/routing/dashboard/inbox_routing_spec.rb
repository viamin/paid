# frozen_string_literal: true

require "rails_helper"

RSpec.describe "dashboard inbox routing", :no_db do
  around do |example|
    Rails.application.reload_routes!
    example.run
  ensure
    Rails.application.reload_routes!
  end

  let(:route_helpers) do
    Class.new do
      include Rails.application.routes.url_helpers
    end.new
  end

  it "exposes the inbox index path under /dashboard/inbox" do
    expect(route_helpers.dashboard_inbox_path).to eq("/dashboard/inbox")
  end

  it "exposes the inbox detail frame path under /dashboard/inbox/entries" do
    expect(route_helpers.dashboard_inbox_entry_path(entry_kind: "clarifying_questions", entry_id: "42")).to eq(
      "/dashboard/inbox/entries/clarifying_questions/42"
    )
  end

  it "routes every registered inbox entry kind through the detail endpoint" do
    Inbox::Queue::KINDS.each do |kind|
      expect(get: "/dashboard/inbox/entries/#{kind}/42").to route_to(
        controller: "dashboard",
        action: "inbox_detail",
        entry_kind: kind,
        entry_id: "42"
      )
    end
  end

  it "rejects unknown inbox entry kinds" do
    expect(get: "/dashboard/inbox/entries/not-a-kind/42").not_to be_routable
  end
end
