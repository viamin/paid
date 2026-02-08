# frozen_string_literal: true

require "rails_helper"

RSpec.describe Prompts::BuildForIssue do
  let(:project) { create(:project) }
  let(:issue) do
    create(:issue,
      project: project,
      title: "Fix login redirect",
      github_number: 42,
      body: "Users are redirected to the wrong page after login.")
  end

  describe ".call" do
    it "builds a prompt containing the issue title and number" do
      prompt = described_class.call(issue: issue, project: project)

      expect(prompt).to include("Fix login redirect")
      expect(prompt).to include("#42")
    end

    it "includes the issue body" do
      prompt = described_class.call(issue: issue, project: project)

      expect(prompt).to include("Users are redirected to the wrong page after login.")
    end

    it "includes instructions for the agent" do
      prompt = described_class.call(issue: issue, project: project)

      expect(prompt).to include("Analyze the issue")
      expect(prompt).to include("Make the necessary code changes")
      expect(prompt).to include("commit all your changes")
      expect(prompt).to include("Do not push")
    end

    it "includes test command for ruby projects" do
      prompt = described_class.call(issue: issue, project: project)

      expect(prompt).to include("bundle exec rspec")
    end

    it "includes lint command for ruby projects" do
      prompt = described_class.call(issue: issue, project: project)

      expect(prompt).to include("bundle exec rubocop")
    end

    context "when project responds to detected_language" do
      let(:project_with_language) do
        proj = create(:project)
        proj.define_singleton_method(:detected_language) { "python" }
        proj
      end
      let(:issue) do
        create(:issue,
          project: project_with_language,
          title: "Fix login redirect",
          github_number: 42,
          body: "Users are redirected to the wrong page after login.")
      end

      it "uses the detected language for test commands" do
        prompt = described_class.call(issue: issue, project: project_with_language)

        expect(prompt).to include("pytest")
      end

      it "uses the detected language for lint commands" do
        prompt = described_class.call(issue: issue, project: project_with_language)

        expect(prompt).to include("ruff check .")
      end
    end

    context "when project has unknown language" do
      let(:project_with_language) do
        proj = create(:project)
        proj.define_singleton_method(:detected_language) { "haskell" }
        proj
      end
      let(:issue) do
        create(:issue,
          project: project_with_language,
          title: "Fix login redirect",
          github_number: 42,
          body: "Users are redirected to the wrong page after login.")
      end

      it "uses fallback commands" do
        prompt = described_class.call(issue: issue, project: project_with_language)

        expect(prompt).to include("No test command configured")
        expect(prompt).to include("No lint command configured")
      end
    end

    context "when issue body is nil" do
      let(:issue) do
        create(:issue,
          project: project,
          title: "Quick fix",
          github_number: 99,
          body: nil)
      end

      it "builds prompt without body content" do
        prompt = described_class.call(issue: issue, project: project)

        expect(prompt).to include("Quick fix")
        expect(prompt).to include("#99")
      end
    end
  end
end
