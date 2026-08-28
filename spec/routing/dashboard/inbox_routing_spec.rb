# frozen_string_literal: true

require "rails_helper"

RSpec.describe "inbox routing", :no_db do
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

  it "exposes the inbox index path under /inbox" do
    expect(route_helpers.inbox_path).to eq("/inbox")
  end

  it "exposes the inbox member path under /inbox/:entry_id" do
    expect(route_helpers.inbox_entry_path("clarifying_questions:42")).to eq("/inbox/clarifying_questions:42")
  end

  it "routes /inbox to the dedicated inbox controller" do
    expect(get: "/inbox").to route_to(controller: "inbox", action: "index")
  end

  it "routes /inbox/:entry_id to the dedicated inbox controller" do
    expect(get: "/inbox/clarifying_questions:42").to route_to(
      controller: "inbox",
      action: "show",
      entry_id: "clarifying_questions:42"
    )
  end

  it "keeps the legacy dashboard collection alias routable" do
    expect(get: "/dashboard/inbox").to route_to(controller: "legacy_inbox_redirects", action: "index")
  end

  it "keeps the legacy dashboard member alias routable" do
    expect(get: "/dashboard/inbox/entries/clarifying_questions/42").to route_to(
      controller: "legacy_inbox_redirects",
      action: "show",
      entry_kind: "clarifying_questions",
      entry_id: "42"
    )
  end
end
