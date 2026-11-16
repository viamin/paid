# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRuns::ManualRunRetryPolicy do
  describe "#build_successor!" do
    # @spec MAINT-015 — retries preserve the maintenance context snapshot.
    it "carries the maintenance context verbatim onto the successor run" do
      original = create(:agent_run, goal: "maintenance", status: "failed", issue: nil,
        custom_prompt: "Audit workflow A", trigger_type: "manual",
        maintenance_objective: "unnecessary_code", maintenance_recipe_version: "1",
        maintenance_guidance: "Audit workflow A", maintenance_scope: "app/workflows/a.rb",
        maintenance_scope_kind: "named", maintenance_pinned_revision: "main",
        maintenance_limits: { "max_execution_seconds" => 7200 },
        base_commit_sha: "a" * 40)

      successor = described_class.new.build_successor!(original, 1)

      expect(successor).to have_attributes(
        goal: "maintenance",
        maintenance_objective: "unnecessary_code",
        maintenance_recipe_version: "1",
        maintenance_guidance: "Audit workflow A",
        maintenance_scope: "app/workflows/a.rb",
        maintenance_scope_kind: "named",
        maintenance_pinned_revision: "main",
        base_commit_sha: "a" * 40
      )
      expect(successor.maintenance_limits).to eq("max_execution_seconds" => 7200)
      expect(successor.custom_prompt).to eq(original.custom_prompt)
    end
  end
end
