# frozen_string_literal: true

require "rails_helper"

# @spec PROJECT-READINESS-007 PROJECT-READINESS-011
RSpec.describe Projects::Readiness::BuildBootstrapPrompt do
  describe ".call" do
    it "frames verification-only setup around the screenshot configuration" do
      project = build(
        :project,
        tdd_mode: "off",
        readiness_gaps: [ {
          "kind" => "verification_configuration_invalid",
          "description" => "Interactive verification configuration is invalid and must be repaired."
        } ]
      )

      prompt = described_class.call(project:)

      expect(prompt).to include("Establish the missing interactive-verification prerequisites")
      expect(prompt).to include(".paid/screenshots.yml")
      expect(prompt).not_to include("later test-writing run owns the intentionally failing red phase")
    end

    it "frames test-harness setup around runnable test execution" do
      project = build(
        :project,
        readiness_gaps: [ {
          "kind" => "missing_ci",
          "description" => "TDD requires a CI configuration."
        } ]
      )

      prompt = described_class.call(project:)

      expect(prompt).to include("Establish the missing test-harness prerequisites")
      expect(prompt).to include("Configure real test execution")
      expect(prompt).to include("later test-writing run owns the intentionally failing red phase")
    end

    it "includes each capability's setup instruction when both have gaps" do
      project = build(
        :project,
        readiness_gaps: [
          { "kind" => "missing_ci", "description" => "TDD requires a CI configuration." },
          { "kind" => "app_start_command_unavailable", "description" => "Interactive verification needs a start command." }
        ]
      )

      prompt = described_class.call(project:)

      expect(prompt).to include("Configure real test execution")
      expect(prompt).to include(".paid/screenshots.yml")
    end
  end
end
