# frozen_string_literal: true

require "rails_helper"

RSpec.describe Features::RdrContract do
  let(:agent_run) { build_stubbed(:agent_run, goal: "create_feature") }

  def contract(changed_files: nil, contents: {})
    files = changed_files || contents.keys
    described_class.call(agent_run: agent_run, changed_files: files, contents: contents)
  end

  describe "valid contract" do
    let(:rdr_path) { "docs/rdrs/RDR-053-new-feature-creation.md" }
    let(:rdr_body) do
      <<~MARKDOWN
        # RDR-053: New Feature Creation

        ## Metadata

        - Date: 2026-08-09

        ## Problem Statement

        Users want feature creation.

        ## Context

        Some context here.

        ## Research Findings

        We read the codebase.

        ## Proposed Solution

        Add `create_feature` goal.

        ## Alternatives Considered

        Fold into lid_planning.

        ## Trade-offs and Consequences

        Two-run chain.

        ## Rollout Guard

        Feature flag: `create_feature`, default off.
        Enablement surface: `/tenant_configuration` or `bin/rails feature_flags:enable[create_feature]`.
        Implementation issue: add `create_feature` to `FeatureFlags::DEFINITIONS`
        and guard runtime behavior with `FeatureFlags.enabled?(:create_feature, project:)`.
        Rollback: disable the flag.
        Cleanup: remove after closeout makes feature creation default.

        ## Implementation Plan

        Five phases.

        ## Validation

        Test scenarios.
      MARKDOWN
    end
    let(:index_body) do
      "| [RDR-053](RDR-053-new-feature-creation.md) | New Feature Creation | Draft | P1 |"
    end

    it "is valid when the RDR has every required section and the index references it" do
      result = contract(
        changed_files: [ rdr_path, "docs/rdrs/README.md" ],
        contents: { rdr_path => rdr_body, "docs/rdrs/README.md" => index_body }
      )

      expect(result.valid?).to be true
      expect(result.missing).to eq([])
      expect(result.new_rdr_path).to eq(rdr_path)
      expect(result.index_updated).to be true
    end
  end

  describe "missing RDR file" do
    it "reports a missing RDR under docs/rdrs/" do
      result = contract(changed_files: [ "docs/rdrs/README.md" ], contents: {})

      expect(result.valid?).to be false
      expect(result.missing).to include(a_string_matching(/new RDR under docs\/rdrs\//))
    end

    it "does not flag sections when the RDR file is missing" do
      result = contract(changed_files: [ "docs/rdrs/README.md" ], contents: {})

      expect(result.missing).not_to include(a_string_matching(/RDR section:/))
    end
  end

  describe "missing required sections" do
    let(:rdr_path) { "docs/rdrs/RDR-099-short.md" }
    let(:incomplete_rdr_body) do
      <<~MARKDOWN
        # RDR-099: Short

        ## Metadata

        - Date: 2026-08-09

        ## Problem Statement

        Just a problem statement.
      MARKDOWN
    end

    it "lists every missing section in the RDR body" do
      result = contract(
        changed_files: [ rdr_path, "docs/rdrs/README.md" ],
        contents: { rdr_path => incomplete_rdr_body, "docs/rdrs/README.md" => "| ... |" }
      )

      expect(result.valid?).to be false
      expect(result.missing).to include(a_string_matching(/Context/))
      expect(result.missing).to include(a_string_matching(/Research Findings/))
      expect(result.missing).to include(a_string_matching(/Proposed Solution/))
      expect(result.missing).to include(a_string_matching(/Alternatives Considered/))
      expect(result.missing).to include(a_string_matching(/Trade-offs and Consequences/))
      expect(result.missing).to include(a_string_matching(/Rollout Guard/))
      expect(result.missing).to include(a_string_matching(/Implementation Plan/))
      expect(result.missing).to include(a_string_matching(/Validation/))
    end

    it "does not require Metadata (it is the section we already have)" do
      result = contract(
        changed_files: [ rdr_path, "docs/rdrs/README.md" ],
        contents: { rdr_path => incomplete_rdr_body, "docs/rdrs/README.md" => "| ... |" }
      )

      expect(result.missing).not_to include(a_string_matching(/RDR section: ## Metadata/))
    end

    it "reports all missing artifacts at once" do
      result = contract(
        changed_files: [ rdr_path ],
        contents: { rdr_path => incomplete_rdr_body }
      )

      expect(result.valid?).to be false
      # 1 missing section list (Context, Research Findings, Proposed Solution,
      # Alternatives Considered, Trade-offs and Consequences, Rollout Guard,
      # Implementation Plan, Validation) + 1 missing index update = 9 entries
      expect(result.missing.length).to eq(9)
    end

    it "requires enablement and runtime wiring details when rollout guard names a feature flag" do
      rdr_path = "docs/rdrs/RDR-099-flagged.md"
      body = Features::RdrContract::REQUIRED_SECTIONS.each_with_object(+"") do |section, str|
        text = section == "Rollout Guard" ? "Feature flag: new_thing, default off." : "body"
        str << "## #{section}\n\n#{text}\n\n"
      end

      result = contract(
        changed_files: [ rdr_path, "docs/rdrs/README.md" ],
        contents: { rdr_path => body, "docs/rdrs/README.md" => "RDR-099-flagged.md" }
      )

      expect(result.valid?).to be false
      expect(result.missing).to include("RDR rollout guard: feature flag definition: FeatureFlags::DEFINITIONS")
      expect(result.missing).to include("RDR rollout guard: feature flag runtime check: FeatureFlags.enabled?")
      expect(result.missing).to include("RDR rollout guard: feature flag enablement surface")
    end

    it "does not require FeatureFlags wiring for a config-gated rollout guard" do
      rdr_path = "docs/rdrs/RDR-099-config.md"
      body = Features::RdrContract::REQUIRED_SECTIONS.each_with_object(+"") do |section, str|
        text = section == "Rollout Guard" ? "Config gate: tenant setting, default off. Enablement surface: tenant configuration." : "body"
        str << "## #{section}\n\n#{text}\n\n"
      end

      result = contract(
        changed_files: [ rdr_path, "docs/rdrs/README.md" ],
        contents: { rdr_path => body, "docs/rdrs/README.md" => "RDR-099-config.md" }
      )

      expect(result.valid?).to be true
    end
  end

  describe "index update" do
    let(:rdr_path) { "docs/rdrs/RDR-053-new-feature-creation.md" }
    let(:rdr_body) do
      Features::RdrContract::REQUIRED_SECTIONS.each_with_index.each_with_object(+"") do |(section, _), str|
        str << "## #{section}\n\nbody\n\n"
      end
    end

    it "is invalid when the README index is not in the changed files" do
      result = contract(
        changed_files: [ rdr_path ],
        contents: { rdr_path => rdr_body }
      )

      expect(result.valid?).to be false
      expect(result.missing).to include(a_string_matching(/RDR index update/))
    end

    it "is invalid when the README index does not reference the new RDR" do
      result = contract(
        changed_files: [ rdr_path, "docs/rdrs/README.md" ],
        contents: {
          rdr_path => rdr_body,
          "docs/rdrs/README.md" => "# Index — unchanged\n"
        }
      )

      expect(result.valid?).to be false
      expect(result.missing).to include(a_string_matching(/RDR index update/))
      expect(result.index_updated).to be false
    end

    it "is valid when the README index references the new RDR by filename" do
      result = contract(
        changed_files: [ rdr_path, "docs/rdrs/README.md" ],
        contents: {
          rdr_path => rdr_body,
          "docs/rdrs/README.md" => "| [RDR-053](RDR-053-new-feature-creation.md) | New | Draft | P1 |"
        }
      )

      expect(result.valid?).to be true
      expect(result.index_updated).to be true
    end
  end

  describe "RDR pattern matching" do
    it "ignores paths outside docs/rdrs/" do
      result = contract(
        changed_files: [ "lib/some_other_rdr.md", "docs/rdrs/README.md" ],
        contents: { "docs/rdrs/README.md" => "" }
      )

      expect(result.new_rdr_path).to be_nil
      expect(result.missing).to include(a_string_matching(/new RDR/))
    end

    it "ignores non-RDR files inside docs/rdrs/" do
      result = contract(
        changed_files: [ "docs/rdrs/closeout-checklist.md", "docs/rdrs/README.md" ],
        contents: { "docs/rdrs/README.md" => "" }
      )

      expect(result.new_rdr_path).to be_nil
    end
  end

  describe "Result data object" do
    let(:rdr_path) { "docs/rdrs/RDR-053-new-feature-creation.md" }

    it "exposes new_rdr_path, valid?, missing, and index_updated" do
      result = contract(
        changed_files: [ rdr_path, "docs/rdrs/README.md" ],
        contents: { rdr_path => "", "docs/rdrs/README.md" => "" }
      )

      expect(result).to respond_to(:new_rdr_path, :valid?, :missing, :index_updated)
      expect(result.new_rdr_path).to eq(rdr_path)
    end
  end
end
