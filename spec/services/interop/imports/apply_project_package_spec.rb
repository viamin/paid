# frozen_string_literal: true

require "rails_helper"

RSpec.describe Interop::Imports::ApplyProjectPackage do
  describe ".call" do
    subject(:result) do
      described_class.call(
        project: project,
        source_system: source_system,
        prompts: prompts,
        style_guides: style_guides,
        workflow_policies: workflow_policies
      )
    end

    let(:prompts) do
      [
        {
          slug: "migration.prompt",
          name: "Migration Prompt",
          category: "coding",
          template: "Implement {{task}}"
        }
      ]
    end
    let(:style_guides) do
      [
        {
          name: "Cursor Style Guide",
          raw_content: "Prefer small patches",
          language: "ruby"
        }
      ]
    end
    let(:workflow_policies) do
      [
        {
          policy_key: "cursor.execution",
          policy_type: "execution",
          name: "Cursor Execution Policy",
          rules: { "handoff" => "review_only" },
          parameters: { "max_parallel" => 2 }
        }
      ]
    end
    let(:project) { create(:project) }
    let(:source_system) { "cursor" }

    it "imports prompts, style guides, and workflow policies into project-scoped records" do
      result
      expect(result.prompts_count).to eq(1)
      expect(result.style_guides_count).to eq(1)
      expect(result.workflow_policies_count).to eq(1)
      expect(project.prompts.find_by!(slug: "migration.prompt").current_version.template).to eq("Implement {{task}}")
      expect(project.style_guides.find_by!(name: "Cursor Style Guide").language).to eq("ruby")
      expect(project.coordination_policies.find_by!(policy_key: "cursor.execution").current_version.rules).to eq({ "handoff" => "review_only" })
    end

    it "persists import summary and mapping entries" do
      result
      expect(project.reload.interop_settings.dig("imports", "last_import", "source_system")).to eq(source_system)
      expect(project.interop_settings.dig("imports", "prompts")).to include(
        include("source_identifier" => "migration.prompt", "target_slug" => "migration.prompt")
      )
      expect(project.interop_settings.dig("imports", "style_guides")).to include(
        include("source_identifier" => "Cursor Style Guide", "target_name" => "Cursor Style Guide")
      )
      expect(project.interop_settings.dig("imports", "workflow_policies")).to include(
        include("source_identifier" => "cursor.execution", "target_policy_key" => "cursor.execution")
      )
    end
  end
end
