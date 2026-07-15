# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApplicationHelper, :no_db do
  describe "#project_type_badge" do
    it "renders the mapped project-type label for a known language" do
      badge = helper.project_type_badge(Project.new(primary_language: "Ruby"))
      expect(badge).to include("Ruby on Rails")
      expect(badge).to include("bg-indigo-100")
      expect(badge).to include("text-indigo-700")
    end

    it "includes the raw language as a tooltip title" do
      badge = helper.project_type_badge(Project.new(primary_language: "Elixir"))
      expect(badge).to include('title="Elixir"')
      expect(badge).to include("Phoenix / Elixir")
    end

    it "falls back to the raw language when unmapped" do
      badge = helper.project_type_badge(Project.new(primary_language: "Brainfuck"))
      expect(badge).to include("Brainfuck")
    end

    it "renders nothing when no language is detected" do
      expect(helper.project_type_badge(Project.new(primary_language: nil))).to be_nil
    end
  end
end
