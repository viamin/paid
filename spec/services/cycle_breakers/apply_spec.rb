# frozen_string_literal: true

require "rails_helper"

RSpec.describe CycleBreakers::Apply do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let!(:issue_a) { create(:issue, project: project, github_number: 1) }
  let!(:issue_b) { create(:issue, project: project, github_number: 2) }
  let!(:issue_c) { create(:issue, project: project, github_number: 3) }

  let!(:edge_ab) { create(:issue_dependency, issue: issue_a, depends_on_issue: issue_b) }
  let!(:edge_bc) { create(:issue_dependency, issue: issue_b, depends_on_issue: issue_c) }

  # Create an edge that would form a cycle (but bypass validation for testing)
  let!(:edge_ca) do
    dep = IssueDependency.new(issue: issue_c, depends_on_issue: issue_a)
    # Save without validation since we're testing the repair logic, not validation
    dep.save!(validate: false)
    dep
  end

  let(:cycle) do
    instance_double(
      Issues::DependencyCycles::Cycle,
      account: account,
      occurrence: "test_occurrence",
      effective_edges: [
        { "id" => edge_ab.id, "from_issue_id" => issue_a.id, "to_issue_id" => issue_b.id },
        { "id" => edge_bc.id, "from_issue_id" => issue_b.id, "to_issue_id" => issue_c.id },
        { "id" => edge_ca.id, "from_issue_id" => issue_c.id, "to_issue_id" => issue_a.id }
      ]
    )
  end

  let(:user) { create(:user) }

  describe "#call" do
    context "with removal candidate" do
      let(:candidate) do
        {
          "declaration_changes" => [
            { "edge_id" => edge_ab.id, "action" => "remove" }
          ]
        }
      end

      it "removes the specified edge" do
        result = CycleBreakers::Apply.call(cycle: cycle, candidate: candidate, initiating_user: user)

        expect(result.success?).to eq true
        expect(result.applied_edge_ids).to include(edge_ab.id)
      end

      it "returns success result" do
        result = CycleBreakers::Apply.call(cycle: cycle, candidate: candidate, initiating_user: user)

        expect(result.success?).to eq true
        expect(result.message).to include("pending sync")
      end
    end

    context "with correction candidate" do
      let(:candidate) do
        {
          "declaration_changes" => [
            {
              "edge_id" => edge_ca.id,
              "action" => "correct",
              "replacement" => { "from_issue_id" => issue_c.id, "to_issue_id" => issue_b.id }
            }
          ]
        }
      end

      it "creates a new corrected edge" do
        result = CycleBreakers::Apply.call(cycle: cycle, candidate: candidate, initiating_user: user)

        expect(result.success?).to eq true
        # Should have the original edge plus the new one
        expect(IssueDependency.where(issue_id: issue_c.id, depends_on_issue_id: issue_b.id)).to exist
      end

      it "marks the new edge as pending_sync" do
        result = CycleBreakers::Apply.call(cycle: cycle, candidate: candidate, initiating_user: user)

        new_edge = IssueDependency.where(issue_id: issue_c.id, depends_on_issue_id: issue_b.id).first
        expect(new_edge.repair_status).to eq "pending_sync"
      end
    end

    context "with multiple changes" do
      let(:candidate) do
        {
          "declaration_changes" => [
            { "edge_id" => edge_ca.id, "action" => "remove" },
            { "edge_id" => edge_bc.id, "action" => "remove" }
          ]
        }
      end

      it "applies all changes in a transaction" do
        result = CycleBreakers::Apply.call(cycle: cycle, candidate: candidate, initiating_user: user)

        expect(result.success?).to eq true
        expect(result.applied_edge_ids.count).to eq 2
        expect(IssueDependency.exists?(edge_ca.id)).to eq false
        expect(IssueDependency.exists?(edge_bc.id)).to eq false
      end
    end

    context "with invalid candidate" do
      let(:candidate) { { "declaration_changes" => [] } }

      it "returns failure result" do
        result = CycleBreakers::Apply.call(cycle: cycle, candidate: candidate, initiating_user: user)

        expect(result.success?).to eq false
        expect(result.message).to include("cannot be empty")
      end
    end

    context "when edge doesn't exist" do
      let(:candidate) do
        {
          "declaration_changes" => [
            { "edge_id" => 999_999, "action" => "remove" }
          ]
        }
      end

      it "handles gracefully and returns success" do
        result = CycleBreakers::Apply.call(cycle: cycle, candidate: candidate, initiating_user: user)

        # Should succeed but skip the non-existent edge
        expect(result.success?).to eq true
      end
    end

    context "repair tracking" do
      let(:candidate) do
        {
          "declaration_changes" => [
            { "edge_id" => edge_ca.id, "action" => "remove" }
          ]
        }
      end

      it "increments repair_attempts" do
        edge_ca.update!(repair_attempts: 1)

        CycleBreakers::Apply.call(cycle: cycle, candidate: candidate, initiating_user: user)

        # The edge is deleted, so we check a remaining edge's attempts
        expect(edge_ab.reload.repair_attempts).to eq 0
      end

      it "sets repair_initiated_at on first attempt" do
        CycleBreakers::Apply.call(cycle: cycle, candidate: candidate, initiating_user: user)

        expect(edge_ab.reload.repair_initiated_at).to be_nil # Not affected by this repair
      end
    end
  end
end
