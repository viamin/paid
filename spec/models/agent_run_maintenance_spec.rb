# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRun do
  describe "maintenance goal" do
    # @spec MAINT-010
    it "registers the maintenance goal without requiring an issue or pull request" do
      expect(described_class::GOALS).to include("maintenance")
      expect(described_class::TRIGGERABLE_GOALS).not_to include("maintenance")

      run = build(:agent_run, goal: "maintenance", issue: nil, custom_prompt: "Audit workflow A",
        maintenance_guidance: "Audit workflow A")

      expect(run).to be_valid
    end

    # @spec MAINT-011 MAINT-OPT-005
    it "requires an optimization type, recipe objective, or nonblank guidance for maintenance runs" do
      scope_only = build(:agent_run, goal: "maintenance", issue: nil,
        maintenance_scope: "app/workflows/a.rb")

      expect(scope_only).to be_invalid
      expect(scope_only.errors[:base]).to include(
        "maintenance runs require an optimization type, recipe objective, or nonblank guidance"
      )

      with_objective = build(:agent_run, goal: "maintenance", issue: nil,
        maintenance_objective: "unnecessary_code", custom_prompt: "Investigate unnecessary code")

      expect(with_objective).to be_valid

      with_type = build(:agent_run, goal: "maintenance", issue: nil,
        maintenance_type: "performance", custom_prompt: "Investigate performance")

      expect(with_type).to be_valid
    end

    # @spec MAINT-OPT-006
    it "validates the immutable optimization type snapshot length" do
      run = build(:agent_run, goal: "maintenance", issue: nil,
        maintenance_type: "x" * 101, custom_prompt: "Investigate custom objective")

      expect(run).to be_invalid
      expect(run.errors[:maintenance_type]).to include("is too long (maximum is 100 characters)")
    end

    # @spec MAINT-015 MAINT-OPT-008
    it "keeps maintenance context immutable once the run starts" do
      run = create(:agent_run, goal: "maintenance", issue: nil, custom_prompt: "Audit A",
        maintenance_objective: "unnecessary_code", maintenance_guidance: "Audit A",
        maintenance_scope: "app/workflows/a.rb", maintenance_scope_kind: "named")

      expect { run.maintenance_guidance = "Rewritten guidance" }
        .to raise_error(ActiveRecord::ReadonlyAttributeError, /maintenance_guidance/)
      expect(run.reload.maintenance_guidance).to eq("Audit A")
    end

    # @spec MAINT-015
    it "exposes its maintenance context for retries" do
      run = create(:agent_run, goal: "maintenance", issue: nil, custom_prompt: "Audit A",
        maintenance_type: "future_type", maintenance_objective: "unnecessary_code", maintenance_recipe_version: "1",
        maintenance_guidance: "Audit A", maintenance_scope: "app/workflows/a.rb",
        maintenance_scope_kind: "named", maintenance_pinned_revision: "main",
        maintenance_limits: { "max_execution_seconds" => 7200 },
        base_commit_sha: "a" * 40)

      expect(run.maintenance_context_attributes).to include(
        maintenance_type: "future_type",
        maintenance_objective: "unnecessary_code",
        maintenance_recipe_version: "1",
        maintenance_guidance: "Audit A",
        maintenance_scope: "app/workflows/a.rb",
        maintenance_scope_kind: "named",
        maintenance_pinned_revision: "main",
        maintenance_limits: { "max_execution_seconds" => 7200 },
        base_commit_sha: "a" * 40
      )
    end
  end
end
