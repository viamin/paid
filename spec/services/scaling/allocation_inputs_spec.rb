# frozen_string_literal: true

require "rails_helper"

RSpec.describe Scaling::AllocationInputs do
  describe ".new" do
    it "creates inputs with valid parameters" do
      inputs = described_class.new(
        task_count: 5,
        budget_cents: 1000,
        max_agent_count: 4,
        max_duration_seconds: 300,
        dependency_edge_count: 3,
        parallelizable_group_count: 2
      )

      expect(inputs.task_count).to eq(5)
      expect(inputs.budget_cents).to eq(1000)
      expect(inputs.max_agent_count).to eq(4)
      expect(inputs.max_duration_seconds).to eq(300)
      expect(inputs.dependency_edge_count).to eq(3)
      expect(inputs.parallelizable_group_count).to eq(2)
    end

    it "applies defaults for optional parameters" do
      inputs = described_class.new(task_count: 3)

      expect(inputs.budget_cents).to eq(0)
      expect(inputs.max_agent_count).to eq(8)
      expect(inputs.max_duration_seconds).to eq(0)
      expect(inputs.dependency_edge_count).to eq(0)
      expect(inputs.parallelizable_group_count).to eq(0)
    end

    it "raises on zero task_count" do
      expect { described_class.new(task_count: 0) }.to raise_error(ArgumentError, /task_count must be positive/)
    end

    it "raises on negative budget_cents" do
      expect { described_class.new(task_count: 3, budget_cents: -1) }.to raise_error(ArgumentError, /budget_cents must be non-negative/)
    end

    it "raises on zero max_agent_count" do
      expect { described_class.new(task_count: 3, max_agent_count: 0) }.to raise_error(ArgumentError, /max_agent_count must be positive/)
    end

    it "raises on negative dependency_edge_count" do
      expect { described_class.new(task_count: 3, dependency_edge_count: -1) }.to raise_error(ArgumentError, /dependency_edge_count must be non-negative/)
    end

    it "is frozen" do
      inputs = described_class.new(task_count: 3)
      expect(inputs).to be_frozen
    end
  end

  describe "#budget_constrained?" do
    it "returns true when budget is positive" do
      inputs = described_class.new(task_count: 3, budget_cents: 500)
      expect(inputs).to be_budget_constrained
    end

    it "returns false when budget is zero" do
      inputs = described_class.new(task_count: 3)
      expect(inputs).not_to be_budget_constrained
    end
  end

  describe "#time_constrained?" do
    it "returns true when duration is positive" do
      inputs = described_class.new(task_count: 3, max_duration_seconds: 600)
      expect(inputs).to be_time_constrained
    end

    it "returns false when duration is zero" do
      inputs = described_class.new(task_count: 3)
      expect(inputs).not_to be_time_constrained
    end
  end

  describe "#parallelism_potential" do
    it "returns ratio of parallelizable groups to tasks" do
      inputs = described_class.new(task_count: 4, parallelizable_group_count: 2)
      expect(inputs.parallelism_potential).to eq(0.5)
    end

    it "returns 0 when no parallelizable groups" do
      inputs = described_class.new(task_count: 4)
      expect(inputs.parallelism_potential).to eq(0.0)
    end

    it "returns 1.0 when all tasks are parallelizable" do
      inputs = described_class.new(task_count: 4, parallelizable_group_count: 4)
      expect(inputs.parallelism_potential).to eq(1.0)
    end
  end

  describe "#complexity_score" do
    it "returns a float between 0 and 1" do
      inputs = described_class.new(
        task_count: 4,
        dependency_edge_count: 2,
        parallelizable_group_count: 2
      )
      expect(inputs.complexity_score).to be_between(0.0, 1.0)
    end

    it "returns 0 for a single task with no edges or parallelism" do
      inputs = described_class.new(task_count: 1)
      expect(inputs.complexity_score).to eq(0.3)
    end
  end
end
