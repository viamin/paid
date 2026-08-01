# frozen_string_literal: true

require "rails_helper"

RSpec.describe Lid::CoherenceReport do
  describe ".parse" do
    it "marks reports with findings as failed and summarizes the counts" do
      output = <<~REPORT
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

      result = described_class.parse(output)

      expect(result.status).to eq("failed")
      expect(result.reverse_orphans).to eq(2)
      expect(result.uncovered_specs).to eq(3)
      expect(result.broken_arrow_refs).to eq(1)
      expect(result.stale_arrows).to eq(1)
      expect(result.untagged_code_files).to eq(4)
      expect(result.untagged_test_files).to eq(5)
      expect(result.summary_line).to include("Coherence soft-block")
    end

    it "marks clean reports as passed" do
      output = <<~REPORT
        LID Coherence Report

        No reverse orphans.
        All arrow references valid.
        All arrows current.
        Untagged code files (0) — behavior entry points with no @spec marker:

        Untagged test files (0) — tests with no @spec marker:
      REPORT

      result = described_class.parse(output)

      expect(result.status).to eq("passed")
      expect(result.summary_line).to eq("Coherence check passed with no structural findings.")
    end
  end
end
