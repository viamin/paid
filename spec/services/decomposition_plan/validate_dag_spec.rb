# frozen_string_literal: true

require "rails_helper"

RSpec.describe DecompositionPlan::ValidateDag, :no_db do
  describe ".call" do
    subject(:result) { described_class.call(tasks: tasks) }

    context "with an empty task list" do
      let(:tasks) { [] }

      it "is valid" do
        expect(result.valid?).to be true
      end

      it "returns empty sorted indices" do
        expect(result.sorted_indices).to eq([])
      end
    end

    context "with a single task" do
      let(:tasks) do
        [ { title: "Add User model", deps: [], scope: "model" } ]
      end

      it "is valid" do
        expect(result.valid?).to be true
      end

      it "returns the single index" do
        expect(result.sorted_indices).to eq([ 0 ])
      end
    end

    context "with a valid linear chain" do
      let(:tasks) do
        [
          { title: "Add migration", deps: [], scope: "model" },
          { title: "Add service", deps: [ 0 ], scope: "service" },
          { title: "Add controller", deps: [ 1 ], scope: "controller" }
        ]
      end

      it "is valid" do
        expect(result.valid?).to be true
      end

      it "returns topologically sorted indices" do
        expect(result.sorted_indices).to eq([ 0, 1, 2 ])
      end

      it "has no errors" do
        expect(result.errors).to be_empty
      end
    end

    context "with a valid diamond dependency" do
      let(:tasks) do
        [
          { title: "Add model", deps: [], scope: "model" },
          { title: "Add auth service", deps: [ 0 ], scope: "service" },
          { title: "Add notif service", deps: [ 0 ], scope: "service" },
          { title: "Add controller", deps: [ 1, 2 ], scope: "controller" }
        ]
      end

      it "is valid" do
        expect(result.valid?).to be true
      end

      it "places root first and sink last" do
        sorted = result.sorted_indices
        expect(sorted.first).to eq(0)
        expect(sorted.last).to eq(3)
      end
    end

    context "with a cycle" do
      let(:tasks) do
        [
          { title: "Task A", deps: [ 1 ], scope: "service" },
          { title: "Task B", deps: [ 0 ], scope: "service" }
        ]
      end

      it "is not valid" do
        expect(result.valid?).to be false
      end

      it "reports cycle error" do
        expect(result.errors).to include("dependency graph contains a cycle")
      end
    end

    context "with a self-dependency" do
      let(:tasks) do
        [
          { title: "Task A", deps: [ 0 ], scope: "service" }
        ]
      end

      it "is not valid" do
        expect(result.valid?).to be false
      end

      it "reports self-dependency error" do
        expect(result.errors.first).to include("depends on itself")
      end
    end

    context "with an invalid reference" do
      let(:tasks) do
        [
          { title: "Task A", deps: [ 5 ], scope: "service" }
        ]
      end

      it "is not valid" do
        expect(result.valid?).to be false
      end

      it "reports invalid index error" do
        expect(result.errors.first).to include("invalid index 5")
      end
    end

    context "with unreachable nodes" do
      let(:tasks) do
        [
          { title: "Leaf", deps: [], scope: "model" },
          { title: "Orphan", deps: [ 2 ], scope: "service" },
          { title: "Mid", deps: [ 1 ], scope: "service" }
        ]
      end

      it "is not valid" do
        expect(result.valid?).to be false
      end

      it "reports cycle (mutual dependency creates cycle)" do
        expect(result.errors).to include("dependency graph contains a cycle")
      end
    end

    context "with multiple independent leaf nodes" do
      let(:tasks) do
        [
          { title: "Model A", deps: [], scope: "model" },
          { title: "Model B", deps: [], scope: "model" },
          { title: "Service", deps: [ 0, 1 ], scope: "service" }
        ]
      end

      it "is valid" do
        expect(result.valid?).to be true
      end

      it "places both leaves before the dependent" do
        sorted = result.sorted_indices
        service_pos = sorted.index(2)
        expect(sorted.index(0)).to be < service_pos
        expect(sorted.index(1)).to be < service_pos
      end
    end
  end
end
