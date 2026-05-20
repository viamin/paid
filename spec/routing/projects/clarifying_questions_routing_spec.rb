# frozen_string_literal: true

require "rails_helper"

RSpec.describe "projects clarifying questions routing", :no_db do
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

  it "uses the plural clarifying_questions helper for the issue wizard" do
    expect(route_helpers.project_issue_clarifying_questions_path("1", "2")).to eq(
      "/projects/1/issues/2/clarifying_questions"
    )
  end
end
