# frozen_string_literal: true

require "rails_helper"

RSpec.describe StyleGuides::InjectIntoPrompt do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:base_prompt) { "# Task\n\nFix the bug in auth.rb" }

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
        create(:style_guide, :global, name: "Empty Guide", raw_content: "Has content")
        guide = StyleGuide.last
        allow(guide).to receive(:content_for_prompt).and_return(nil)
        allow(StyleGuide).to receive(:resolve_for).and_return([ guide ])

        result = described_class.call(prompt: base_prompt, project: project)

        expect(result).to eq(base_prompt)
      end

      it "does not include style guides from other accounts" do
        other_account = create(:account)
        create(:style_guide, account: other_account, name: "Other Guide", raw_content: "Other rules")

        result = described_class.call(prompt: base_prompt, project: project)

        expect(result).not_to include("Other Guide")
      end
    end
  end
end
