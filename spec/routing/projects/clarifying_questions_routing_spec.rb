# frozen_string_literal: true

require "rails_helper"

RSpec.describe "projects clarifying questions routing", :no_db do
  include Rails.application.routes.url_helpers

  it "uses the plural clarifying_questions helper for the issue wizard" do
    expect(project_issue_clarifying_questions_path("1", "2")).to eq(
      "/projects/1/issues/2/clarifying_questions"
    )
  end
end
