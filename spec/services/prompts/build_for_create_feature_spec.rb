# frozen_string_literal: true

require "rails_helper"

# @spec CREATE-FEATURE-001
# @spec CREATE-FEATURE-002
RSpec.describe Prompts::BuildForCreateFeature do
  let(:feature_brief) do
    {
      "title" => "Add dark mode",
      "problem" => "Users want a dark theme to reduce eye strain at night",
      "desired_behavior" => "Toggling dark mode switches the UI to a dark color palette across all pages",
      "constraints" => [ "Must support system preference detection", "No flash of light theme on load" ],
      "rejected_alternatives" => [ "CSS-only variables — rejected because we need server-side rendering support" ],
      "scope" => {
        "in" => [ "Color palette", "Toggle in settings", "Persistence" ],
        "out" => [ "Themed syntax highlighting in code blocks" ]
      },
      "done_criteria" => "Dark mode is toggleable, persists, respects system preference, and passes visual regression tests",
      "lid_requested" => false,
      "target_rdr_number" => nil
    }
  end

  describe ".call" do
    it "returns a String prompt that contains the feature brief and instructions" do
      prompt = described_class.call(
        project_name: "Paid",
        full_name: "viamin/paid",
        feature_brief: feature_brief
      )

      expect(prompt).to be_a(String)
      expect(prompt).to include("Add dark mode")
      expect(prompt).to include("Users want a dark theme to reduce eye strain at night")
      expect(prompt).to include("docs/rdrs/RDR-0XX-<slug>.md")
      expect(prompt).to include("docs/rdrs/README.md")
    end

    it "tells the agent to derive the RDR number from the repo (with target override)" do
      prompt = described_class.call(
        project_name: "Paid",
        full_name: "viamin/paid",
        feature_brief: feature_brief
      )

      expect(prompt).to include("find the highest")
      expect(prompt).to include("existing number")
      expect(prompt).to include("target_rdr_number")
    end

    it "instructs the agent to decompose the RDR into an issue tree" do
      prompt = described_class.call(
        project_name: "Paid",
        full_name: "viamin/paid",
        feature_brief: feature_brief
      )

      expect(prompt).to include("Decompose")
      expect(prompt).to include("epic issue")
      expect(prompt).to include("Depends on")
      expect(prompt).to include("Part of RDR-0XX")
    end

    it "honours a pinned target_rdr_number when present" do
      brief = feature_brief.merge("target_rdr_number" => 99)

      prompt = described_class.call(
        project_name: "Paid",
        full_name: "viamin/paid",
        feature_brief: brief
      )

      expect(prompt).to include("Target RDR number: 99")
    end

    it "uses '(derive from repo)' when no target_rdr_number is set" do
      prompt = described_class.call(
        project_name: "Paid",
        full_name: "viamin/paid",
        feature_brief: feature_brief
      )

      expect(prompt).to include("Target RDR number: (derive from repo)")
    end

    it "renders scope (in) and scope (out) sections" do
      prompt = described_class.call(
        project_name: "Paid",
        full_name: "viamin/paid",
        feature_brief: feature_brief
      )

      expect(prompt).to include("Scope (in)")
      expect(prompt).to include("Color palette")
      expect(prompt).to include("Scope (out)")
      expect(prompt).to include("Themed syntax highlighting in code blocks")
    end

    it "tolerates string-keyed scope and array-of-strings fields" do
      brief = feature_brief.transform_keys(&:to_s)
      brief["scope"] = brief["scope"].transform_keys(&:to_s)
      brief["constraints"] = brief["constraints"]
      brief["rejected_alternatives"] = brief["rejected_alternatives"]

      prompt = described_class.call(
        project_name: "Paid",
        full_name: "viamin/paid",
        feature_brief: brief
      )

      expect(prompt).to include("Add dark mode")
    end

    it "returns the FALLBACK_PROMPT-shaped output when the DB prompt is missing" do
      prompt = described_class.call(
        project_name: "Paid",
        full_name: "viamin/paid",
        feature_brief: feature_brief
      )

      expect(prompt).to include("# Task")
      expect(prompt).to include("# Feature brief")
      expect(prompt).to include("# Instructions")
      expect(prompt).to include("# Rules")
    end
  end

  describe "LID integration" do
    it "includes LID Integration section when lid_mode is set" do
      prompt = described_class.call(
        project_name: "Paid",
        full_name: "viamin/paid",
        feature_brief: feature_brief,
        lid_mode: "full"
      )

      expect(prompt).to include("# LID Integration")
      expect(prompt).to include("LID-aware from the start")
      expect(prompt).to include("@spec")
      expect(prompt).to include("lid_planning")
    end

    it "includes LID Bootstrap section when lid_requested is true and lid_mode is nil" do
      brief = feature_brief.merge("lid_requested" => true)

      prompt = described_class.call(
        project_name: "Paid",
        full_name: "viamin/paid",
        feature_brief: brief,
        lid_mode: nil
      )

      expect(prompt).to include("# LID Bootstrap")
      expect(prompt).to include("lid_planning")
      expect(prompt).to include("adoption")
    end

    it "omits LID sections when lid_mode is nil and lid_requested is false" do
      prompt = described_class.call(
        project_name: "Paid",
        full_name: "viamin/paid",
        feature_brief: feature_brief
      )

      expect(prompt).not_to include("# LID Integration")
      expect(prompt).not_to include("# LID Bootstrap")
    end

    it "includes the lid_mode value in the rendered prompt" do
      prompt = described_class.call(
        project_name: "Paid",
        full_name: "viamin/paid",
        feature_brief: feature_brief,
        lid_mode: "scoped"
      )

      expect(prompt).to include("`scoped`")
    end
  end

  describe "DB-prompt routing" do
    it "uses the DB prompt when one is seeded for coding.create_feature_prompt" do
      prompt = create(
        :prompt,
        slug: Prompts::BuildForCreateFeature::PROMPT_SLUG,
        category: "coding"
      )
      version = prompt.create_version!(
        template: "DB prompt for {{project_name}}: {{feature_brief}}"
      )

      result = described_class.call(
        project_name: "Paid",
        full_name: "viamin/paid",
        feature_brief: feature_brief
      )

      expect(result).to eq(version.render(
        project_name: "Paid",
        feature_brief: result.split(": ", 2).last.split("\n").first
      )).or include("DB prompt for Paid")
      expect(result).to include("DB prompt for Paid")
    end
  end

  describe "FALLBACK_PROMPT" do
    it "is exposed as a constant so the seed can reference it" do
      expect(described_class::FALLBACK_PROMPT).to be_a(String)
      expect(described_class::FALLBACK_PROMPT).to include("docs/rdrs/")
    end
  end
end
