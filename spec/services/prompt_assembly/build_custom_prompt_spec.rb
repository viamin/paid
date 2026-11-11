# frozen_string_literal: true

require "rails_helper"
require "ostruct"

# @spec PROMPT-ASSEMBLY-019, PROMPT-ASSEMBLY-020, PROMPT-ASSEMBLY-021,
#       PROMPT-ASSEMBLY-022, PROMPT-ASSEMBLY-025
RSpec.describe PromptAssembly::BuildCustomPrompt do
  let(:project) { create(:project, allowed_github_usernames: [ "viamin" ]) }
  let(:agent_run) { create(:agent_run, project: project, custom_prompt: "Do the thing") }

  before do
    allow(Knowledge::ContextBundle::Build).to receive(:call).and_return(
      content: "", sections: [], total_tokens: 0, queries_made: 0
    )
    allow(project).to receive(:github_token).and_return(nil)
  end

  describe ".call" do
    it "returns a PromptAssembly::Result" do
      result = described_class.call(custom_prompt: "Do the thing", project: project, agent_run: agent_run)

      expect(result).to be_a(PromptAssembly::Result)
    end

    it "preserves the custom task text verbatim" do
      custom_text = "Custom task: implement the feature, with details and constraints."

      result = described_class.call(custom_prompt: custom_text, project: project, agent_run: agent_run)

      expect(result.text).to include(custom_text)
      task_section = result.sections.find { |s| s.key == :task_custom }
      expect(task_section).to be_present
      expect(task_section.content).to eq(custom_text)
    end

    it "marks the task_custom section as required" do
      result = described_class.call(custom_prompt: "Do the thing", project: project, agent_run: agent_run)

      task_section = result.sections.find { |s| s.key == :task_custom }
      expect(task_section).to be_required
      expect(task_section.trust_level).to eq(:trusted)
    end
  end

  describe "mandatory safety and settings sections" do
    it "always includes the safety_rules section" do
      result = described_class.call(custom_prompt: "Do the thing", project: project, agent_run: agent_run)

      expect(result.text).to include("MUST pass before every commit")
      expect(result.text).to include("Never use `--no-verify`")
      expect(result.text).to include("Fix forward")
      section = result.sections.find { |s| s.key == :safety_rules }
      expect(section).to be_required
      expect(section.trust_level).to eq(:trusted)
    end

    it "always includes the service_environment section" do
      result = described_class.call(custom_prompt: "Do the thing", project: project, agent_run: agent_run)

      section = result.sections.find { |s| s.key == :service_environment }
      expect(section).to be_required
      expect(section.trust_level).to eq(:trusted)
    end

    it "keeps the safety_rules section even when a profile disables it" do
      profile = PromptAssembly::Profile.new(disabled_sections: [ :safety_rules ])
      allow(PromptAssembly::ProfileResolution).to receive(:resolve).and_return(profile)

      result = described_class.call(custom_prompt: "Do the thing", project: project, agent_run: agent_run)

      expect(result.text).to include("MUST pass before every commit")
      expect(result.skipped.map { |s| s[:key] }).not_to include(:safety_rules)
    end

    it "keeps the service_environment section even when a profile disables it" do
      profile = PromptAssembly::Profile.new(disabled_sections: [ :service_environment ])
      allow(PromptAssembly::ProfileResolution).to receive(:resolve).and_return(profile)

      result = described_class.call(custom_prompt: "Do the thing", project: project, agent_run: agent_run)

      expect(result.sections.map(&:key)).to include(:service_environment)
    end

    # @spec PROMPT-ASSEMBLY-025
    it "includes the effective merge and review posture for create-PR custom prompts" do
      result = described_class.call(custom_prompt: "Do the thing", project: project, agent_run: agent_run)

      section = result.sections.find { |entry| entry.key == :effective_merge_review_posture }
      expect(result.text).to include("# Effective Merge and Review Posture")
      expect(section).to be_required
      expect(section.trust_level).to eq(:trusted)
      expect(section.metadata).to include(
        :auto_merge_mode,
        :auto_merge_phase_authorized,
        :bot_authored_pr_auto_merge,
        :review_methods,
        :manual_review_enabled,
        :human_approval,
        :tdd_mode
      )
      expect(result.provenance[:sections].map { |entry| entry[:key] }).to include(:effective_merge_review_posture)
    end

    # @spec PROMPT-ASSEMBLY-025
    it "keeps the effective merge and review posture when a profile disables it" do
      profile = PromptAssembly::Profile.new(disabled_sections: [ :effective_merge_review_posture ])
      allow(PromptAssembly::ProfileResolution).to receive(:resolve).and_return(profile)

      result = described_class.call(custom_prompt: "Do the thing", project: project, agent_run: agent_run)

      expect(result.sections.map(&:key)).to include(:effective_merge_review_posture)
      expect(result.skipped.map { |entry| entry[:key] }).not_to include(:effective_merge_review_posture)
    end

    it "omits the effective merge and review posture for non-create-PR custom prompts" do
      review_run = agent_run.dup
      review_run.goal = "review"

      result = described_class.call(custom_prompt: "Review the change", project: project, agent_run: review_run)

      expect(result.sections.map(&:key)).not_to include(:effective_merge_review_posture)
    end
  end

  describe "TDD boundaries" do
    it "includes the test_writing boundaries when the run is governed" do
      agent_run = create(:agent_run, project: project, custom_prompt: "Write tests for X", tdd_phase: "test_writing")

      result = described_class.call(custom_prompt: "Write tests for X", project: project, agent_run: agent_run)

      expect(result.text).to include("TDD Boundaries — test-writing run")
      expect(result.text).to include("spec/")
      expect(result.text).to include("expected assertion failures")
      expect(result.text).to include("does not unlock implementation within this run")
      section = result.sections.find { |s| s.key == :tdd_boundaries }
      expect(section).to be_required
    end

    it "includes the test_fixing boundaries when the run is governed" do
      agent_run = create(:agent_run, project: project, custom_prompt: "Fix the failing test", tdd_phase: "test_fixing")

      result = described_class.call(custom_prompt: "Fix the failing test", project: project, agent_run: agent_run)

      expect(result.text).to include("TDD Boundaries — test-fixing run")
      expect(result.text).to include("paid-tests-ready-for-review")
    end

    it "includes the refactor boundaries when the run is governed" do
      agent_run = create(:agent_run, project: project, custom_prompt: "Refactor the helper", tdd_phase: "refactor")

      result = described_class.call(custom_prompt: "Refactor the helper", project: project, agent_run: agent_run)

      expect(result.text).to include("TDD Boundaries — refactor run")
      expect(result.text).to include("frozen")
    end

    it "omits TDD boundaries for non-TDD-governed runs" do
      agent_run = create(:agent_run, project: project, custom_prompt: "Do the thing", tdd_phase: nil)

      result = described_class.call(custom_prompt: "Do the thing", project: project, agent_run: agent_run)

      expect(result.sections.map(&:key)).not_to include(:tdd_boundaries)
    end
  end

  describe "issue-less create_pr runs" do
    it "produces a non-empty prompt with service environment for an issue-less manual run" do
      agent_run = create(:agent_run, project: project, issue: nil, custom_prompt: "Run this one-off task")

      result = described_class.call(custom_prompt: "Run this one-off task", project: project, agent_run: agent_run)

      expect(result.text).to be_present
      expect(result.text).to include("Run this one-off task")
      expect(result.sections.map(&:key)).to include(:service_environment)
    end
  end

  describe "provenance" do
    it "records digest, section keys, and required flags in the provenance" do
      result = described_class.call(custom_prompt: "Do the thing", project: project, agent_run: agent_run)

      provenance = result.provenance
      expect(provenance[:digest]).to match(/\A[0-9a-f]{64}\z/)
      keys = provenance[:sections].map { |s| s[:key] }
      expect(keys).to include(:task_custom, :safety_rules, :service_environment)
      required_keys = provenance[:sections].select { |s| s[:required] }.map { |s| s[:key] }
      expect(required_keys).to include(:task_custom, :safety_rules, :service_environment)
    end

    it "does not include section bodies in the provenance" do
      result = described_class.call(custom_prompt: "SECRET-CONTENT-MUST-NOT-LEAK-456", project: project, agent_run: agent_run)

      expect(result.provenance.to_s).not_to include("SECRET-CONTENT-MUST-NOT-LEAK-456")
    end
  end
end
