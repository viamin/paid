# frozen_string_literal: true

require "rails_helper"

# @spec PROMPT-ASSEMBLY-001
# @spec PROMPT-ASSEMBLY-002
# @spec PROMPT-ASSEMBLY-003
# @spec PROMPT-ASSEMBLY-004
# @spec PROMPT-ASSEMBLY-005
RSpec.describe PromptAssembly::Build do
  def section(key:, content:, **overrides)
    PromptAssembly::Section.new(
      key: key,
      content: content,
      trust_level: "trusted_instruction",
      source: "TestProvider",
      required: false,
      safety: false,
      inclusion_reason: "test",
      **overrides
    )
  end

  let(:context) { PromptAssembly::Context.new(goal: "create_pr") }

  describe ".call" do
    it "assembles prompt text in profile order and returns provenance" do
      sections = [
        section(key: "task.issue", title: "Task", content: "Fix the bug.", required: true),
        section(key: "style.guides", title: "Style", content: "Use two spaces.")
      ]
      profile = PromptAssembly::Profile.new(name: "default", order: %w[style.guides task.issue])

      result = described_class.call(context: context, sections: sections, profile: profile)

      expect(result.prompt).to eq("# Style\n\nUse two spaces.\n\n# Task\n\nFix the bug.")
      expect(result.sections.map(&:key)).to eq(%w[style.guides task.issue])
      expect(result.provenance[:ordered_keys]).to eq(%w[style.guides task.issue])
      expect(result.provenance[:goal]).to eq("create_pr")
      expect(result.provenance[:digest]).to match(/\A\h{64}\z/)
    end

    it "fails closed when a section is missing its trust level" do
      sections = [ section(key: "task.issue", content: "text", trust_level: nil) ]

      expect {
        described_class.call(context: context, sections: sections)
      }.to raise_error(PromptAssembly::MissingTrustMetadata)
    end

    it "fails closed when a section is missing its source" do
      sections = [ section(key: "task.issue", content: "text", source: nil) ]

      expect {
        described_class.call(context: context, sections: sections)
      }.to raise_error(PromptAssembly::MissingTrustMetadata)
    end

    it "fails closed when a section is missing its inclusion reason" do
      sections = [ section(key: "task.issue", content: "text", inclusion_reason: nil) ]

      expect {
        described_class.call(context: context, sections: sections)
      }.to raise_error(PromptAssembly::MissingInclusionReason)
    end

    it "fails closed on an unknown trust level" do
      sections = [ section(key: "task.issue", content: "text", trust_level: "mystery") ]

      expect {
        described_class.call(context: context, sections: sections)
      }.to raise_error(PromptAssembly::UnknownTrustLevel)
    end

    it "fails closed when a render mode is incompatible with the trust level" do
      sections = [
        section(
          key: "knowledge.context",
          content: "repo content",
          trust_level: "quarantined_context",
          render_mode: :instruction
        )
      ]

      expect {
        described_class.call(context: context, sections: sections)
      }.to raise_error(PromptAssembly::IncompatibleRenderMode)
    end

    it "fails closed when an ordinary profile disables a safety section" do
      sections = [ section(key: "lid.workflow", content: "LID rules", safety: true) ]
      profile = PromptAssembly::Profile.new(name: "ordinary", disabled_keys: [ "lid.workflow" ])

      expect {
        described_class.call(context: context, sections: sections, profile: profile)
      }.to raise_error(PromptAssembly::SafetySectionDisabled)
    end

    it "allows an authorized profile to disable a safety section" do
      sections = [ section(key: "lid.workflow", content: "LID rules", safety: true) ]
      profile = PromptAssembly::Profile.new(
        name: "admin",
        disabled_keys: [ "lid.workflow" ],
        allow_safety_overrides: true
      )

      result = described_class.call(context: context, sections: sections, profile: profile)

      expect(result.prompt).to eq("")
      expect(result.skipped_sections.map(&:key)).to eq([ "lid.workflow" ])
    end

    it "records empty and disabled sections as skipped" do
      sections = [
        section(key: "task.issue", content: "text", required: true),
        section(key: "style.guides", content: ""),
        section(key: "marketplace.prompt", content: "extra")
      ]
      profile = PromptAssembly::Profile.new(name: "default", disabled_keys: [ "marketplace.prompt" ])

      result = described_class.call(context: context, sections: sections, profile: profile)

      expect(result.prompt).to eq("text")
      expect(result.skipped_sections.map(&:key)).to eq(%w[style.guides marketplace.prompt])
      expect(result.skipped_sections.map(&:reason)).to eq(%w[empty disabled_by_profile])
    end
  end

  describe PromptAssembly::Context do
    it "builds a context from an agent run" do
      project = instance_double(Project)
      agent_run = instance_double(AgentRun, goal: "create_pr", project: project)

      context = described_class.for_agent_run(agent_run)

      expect(context.goal).to eq("create_pr")
      expect(context.project).to eq(project)
      expect(context.agent_run).to eq(agent_run)
    end
  end
end
