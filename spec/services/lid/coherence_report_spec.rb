# frozen_string_literal: true

require "rails_helper"

RSpec.describe Lid::CoherenceReport do
  describe ".parse" do
    let(:findings_output) do
      <<~REPORT
        LID Coherence Report

        Reverse orphans (2) — @spec cites a spec that doesn't exist:
        Uncovered [ ] specs (3) — gap markers with no @spec ref:
            [MISSING] auth-ui: docs/intent/auth-ui.md
          Needs work:
            auth-ui: status is MAPPED
        Drift Signals
          Untagged code files (4) — behavior entry points with no @spec marker:

          Untagged test files (5) — tests with no @spec marker:
      REPORT
    end
    let(:collision_output) do
      <<~REPORT
        LID Coherence Report

        ════════════════════════════════════════════════════════
          Spec ID Allocation Collisions
        ════════════════════════════════════════════════════════
          Target: main (a1b2c3d) | Base: e4f5a6b | Head: c7d8e9f
          Collisions (1) — IDs newly declared on both head and target since base:
            SUBSCRIPTION-RUNNER-AUTH-008
              head: docs/intent/subscription-runner-auth/subscription-runner-auth-specs.md:6 "Materialization identity…"
              target: docs/intent/subscription-runner-auth/subscription-runner-auth-specs.md:5 "authentication-source…"
              @spec in head: app/services/subscription_runners/materialize.rb:4, spec/services/subscription_runners/materialize_spec.rb:3
          Duplicate declarations (1) — IDs declared more than once in the integration tree:
            SUBSCRIPTION-RUNNER-AUTH-008: docs/intent/subscription-runner-auth/subscription-runner-auth-specs.md:5, docs/intent/subscription-runner-auth/subscription-runner-auth-specs.md:6 (integration tree 0f1e2d, textual auto-merge)
      REPORT
    end
    let(:clean_output) do
      <<~REPORT
        LID Coherence Report

        No reverse orphans.
        All arrow references valid.
        All arrows current.
        Untagged code files (0) — behavior entry points with no @spec marker:

        Untagged test files (0) — tests with no @spec marker:

          No collisions detected.
          No duplicate declarations in the integration tree.
          Collision check skipped: no target branch ref resolved.
      REPORT
    end

    it "marks reports with findings as failed and summarizes the counts" do
      result = described_class.parse(findings_output)

      expect(result.status).to eq("failed")
      expect(result.reverse_orphans).to eq(2)
      expect(result.uncovered_specs).to eq(3)
      expect(result.broken_arrow_refs).to eq(1)
      expect(result.stale_arrows).to eq(1)
      expect(result.untagged_code_files).to eq(4)
      expect(result.untagged_test_files).to eq(5)
      expect(result.spec_id_collisions).to eq(0)
      expect(result.duplicate_spec_declarations).to eq(0)
      expect(result.summary_line).to include("Coherence soft-block")
    end

    it "captures collision counts, duplicate declarations, and their detail evidence" do
      result = described_class.parse(collision_output)

      expect(result.status).to eq("failed")
      expect(result.spec_id_collisions).to eq(1)
      expect(result.duplicate_spec_declarations).to eq(1)
      expect(result.summary_line).to include("1 spec ID collisions, 1 duplicate spec declarations")
      expect(result.collision_details).to include("SUBSCRIPTION-RUNNER-AUTH-008")
      expect(result.collision_details).to include(/head: docs\/intent\/subscription-runner-auth\//)
      expect(result.collision_details).to include(/@spec in head: app\/services/)
      expect(result.duplicate_details).to include(/SUBSCRIPTION-RUNNER-AUTH-008: docs\/intent\//)
      expect(result.to_h["collision_details"]).to eq(result.collision_details)
      expect(result.to_h["duplicate_details"]).to eq(result.duplicate_details)
    end

    it "marks clean reports as passed" do
      result = described_class.parse(clean_output)

      expect(result.status).to eq("passed")
      expect(result.spec_id_collisions).to eq(0)
      expect(result.duplicate_spec_declarations).to eq(0)
      expect(result.summary_line).to eq("Coherence check passed with no structural findings.")
    end
  end
end
