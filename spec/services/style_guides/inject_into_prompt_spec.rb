# frozen_string_literal: true

require "rails_helper"

RSpec.describe StyleGuides::InjectIntoPrompt do
  before do
    TenantContext.with_system_access { StyleGuide.delete_all }
  end

  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:base_prompt) { "# Task\n\nFix the bug in auth.rb" }
  let(:agent_run) { create(:agent_run, project: project, issue: nil, custom_prompt: base_prompt) }

  def create_running_style_guide_ab_test(guide:, variant_version:)
    ab_test = create(:style_guide_ab_test,
      account: account,
      style_guide: guide,
      control_version: guide.current_version,
      status: "running",
      started_at: Time.current)
    create(:style_guide_ab_test_variant,
      style_guide_ab_test: ab_test,
      style_guide_version: guide.current_version,
      is_control: true)
    variant = create(:style_guide_ab_test_variant,
      style_guide_ab_test: ab_test,
      style_guide_version: variant_version,
      is_control: false)

    [ ab_test, variant ]
  end

  describe ".call" do
    context "when no style guides exist" do
      it "returns the prompt unchanged" do
        result = described_class.call(prompt: base_prompt, project: project)

        expect(result).to eq(base_prompt)
      end
    end

    context "when style guides exist" do
      it "appends style guide content to the prompt" do
        create(:style_guide, :global, name: "Ruby Conventions", raw_content: "Use snake_case")

        result = described_class.call(prompt: base_prompt, project: project)

        expect(result).to include("# Style Guide")
        expect(result).to include("Ruby Conventions")
        expect(result).to include("Use snake_case")
      end

      it "includes all applicable style guides" do
        create(:style_guide, :global, name: "Global Guide", raw_content: "Global rules")
        create(:style_guide, account: account, name: "Account Guide", raw_content: "Account rules")
        create(:style_guide, project: project, name: "Project Guide", raw_content: "Project rules")

        result = described_class.call(prompt: base_prompt, project: project)

        expect(result).to include("Global Guide")
        expect(result).to include("Account Guide")
        expect(result).to include("Project Guide")
      end

      it "uses compressed content when available" do
        create(:style_guide, :global, :compressed, name: "Ruby Guide",
          raw_content: "Very long raw content...",
          compressed_content: "Compressed rules")

        result = described_class.call(prompt: base_prompt, project: project)

        expect(result).to include("Compressed rules")
        expect(result).not_to include("Very long raw content")
      end

      it "labels scope in the output" do
        create(:style_guide, :global, name: "Global Guide", raw_content: "Global rules")
        create(:style_guide, account: account, name: "Account Guide", raw_content: "Account rules")
        create(:style_guide, project: project, name: "Project Guide", raw_content: "Project rules")

        result = described_class.call(prompt: base_prompt, project: project)

        expect(result).to include("(global)")
        expect(result).to include("(account)")
        expect(result).to include("(project)")
      end

      it "skips inactive style guides" do
        create(:style_guide, :global, :inactive, name: "Inactive Guide", raw_content: "Should not appear")
        create(:style_guide, :global, name: "Active Guide", raw_content: "Should appear")

        result = described_class.call(prompt: base_prompt, project: project)

        expect(result).to include("Active Guide")
        expect(result).not_to include("Inactive Guide")
      end

      it "skips guides with blank content_for_prompt" do
        guide = create(:style_guide, :global, name: "Empty Guide", raw_content: "Has content")
        guide.update_columns(raw_content: "", compressed_content: "")
        guide.current_version.update_columns(raw_content: "", compressed_content: "")

        result = described_class.call(prompt: base_prompt, project: project)

        expect(result).to eq(base_prompt)
      end

      it "enforces a total byte budget and omits guides that exceed it" do
        large_content = "x" * 20_000
        create(:style_guide, project: project, name: "Project Guide",
          raw_content: "stub", compressed_content: large_content)
        create(:style_guide, :global, name: "Global Guide",
          raw_content: "stub", compressed_content: large_content)

        result = described_class.call(prompt: base_prompt, project: project)

        expect(result).to include("Project Guide")
        expect(result).not_to include("Global Guide")
      end

      it "does not include style guides from other accounts" do
        other_account = create(:account)
        create(:style_guide, account: other_account, name: "Other Guide", raw_content: "Other rules")

        result = described_class.call(prompt: base_prompt, project: project)

        expect(result).not_to include("Other Guide")
      end

      it "records run exposures when an agent run is provided" do
        guide = create(:style_guide, account: account, project: nil, name: "Account Guide", raw_content: "Account rules")

        described_class.call(prompt: base_prompt, project: project, agent_run: agent_run, source: "Spec")

        exposure = agent_run.reload.style_guide_run_exposures.sole
        expect(exposure.style_guide).to eq(guide)
        expect(exposure.style_guide_version).to eq(guide.current_version)
        expect(exposure.injected_via).to eq("Spec")
      end

      it "uses an assigned style-guide A/B test variant and records the assignment" do
        guide = create(:style_guide, account: account, project: nil, name: "Account Guide", raw_content: "Control rules")
        variant_version = create(:style_guide_version,
          style_guide: guide,
          version: guide.current_version.version + 1,
          raw_content: "Variant rules")
        ab_test, variant = create_running_style_guide_ab_test(guide:, variant_version:)
        create(:style_guide_ab_test_assignment,
          style_guide_ab_test: ab_test,
          style_guide_ab_test_variant: variant,
          agent_run: agent_run)

        result = described_class.call(prompt: base_prompt, project: project, agent_run: agent_run, source: "Spec")

        expect(result).to include("Variant rules")
        assignment = agent_run.reload.style_guide_ab_test_assignments.sole
        expect(assignment.style_guide_ab_test).to eq(ab_test)
        expect(agent_run.style_guide_run_exposures.sole.style_guide_ab_test_assignment).to eq(assignment)
      end
    end
  end
end
