# frozen_string_literal: true

require "rails_helper"

RSpec.describe CycleBreakers::ConfirmSync do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let!(:issue_a) { create(:issue, project: project, github_number: 1, github_state: "open") }
  let!(:issue_b) { create(:issue, project: project, github_number: 2, github_state: "open") }

  describe "#call" do
    context "when repair has been synchronized" do
      let!(:edge) do
        create(:issue_dependency,
          issue: issue_a,
          depends_on_issue: issue_b,
          repair_status: "pending_sync",
          repair_initiated_at: 1.hour.ago)
      end

      it "confirms the repair when no cycles remain" do
        # The cycle should be gone since we're checking after it's been applied
        # (in this test, we have no cycles because there are only 2 issues with 1 edge)
        result = CycleBreakers::ConfirmSync.call(account: account)

        expect(result.confirmed_count).to eq 1
        expect(edge.reload.repair_status).to eq "confirmed"
      end

      it "sets confirmed_at timestamp" do
        CycleBreakers::ConfirmSync.call(account: account)

        expect(edge.reload.repair_outcome).to include("confirmed_at")
      end
    end

    context "when repair is still pending" do
      let!(:issue_c) { create(:issue, project: project, github_number: 3, github_state: "open") }
      let!(:edge_ab) { create(:issue_dependency, issue: issue_a, depends_on_issue: issue_b) }
      let!(:edge_bc) { create(:issue_dependency, issue: issue_b, depends_on_issue: issue_c) }
      let!(:edge_ca) do
        dep = IssueDependency.new(
          issue: issue_c,
          depends_on_issue: issue_a,
          repair_status: "pending_sync",
          repair_initiated_at: 1.hour.ago)
        dep.save!(validate: false)
        dep
      end

      before do
        # Ensure the cycle is still present
        allow(Issues::DependencyCycles).to receive(:call).and_return([
          instance_double(
            Issues::DependencyCycles::Cycle,
            effective_edges: [
              { "id" => edge_ab.id },
              { "id" => edge_bc.id },
              { "id" => edge_ca.id }
            ]
          )
        ])
      end

      it "leaves the repair in pending_sync state" do
        result = CycleBreakers::ConfirmSync.call(account: account)

        expect(result.confirmed_count).to eq 0
        expect(edge_ca.reload.repair_status).to eq "pending_sync"
      end
    end

    context "when repair exceeds max attempts" do
      let!(:edge) do
        create(:issue_dependency,
          issue: issue_a,
          depends_on_issue: issue_b,
          repair_status: "pending_sync",
          repair_attempts: CycleBreakers::MAX_REPAIR_ATTEMPTS + 1,
          repair_initiated_at: 1.hour.ago)
      end

      before do
        # Simulate that the cycle is still present
        allow(Issues::DependencyCycles).to receive(:call).and_return([
          instance_double(
            Issues::DependencyCycles::Cycle,
            effective_edges: [{ "id" => edge.id }]
          )
        ])
      end

      it "marks the repair as failed" do
        result = CycleBreakers::ConfirmSync.call(account: account)

        expect(result.failed_count).to eq 1
        expect(edge.reload.repair_status).to eq "failed"
      end

      it "records failure reason in outcome" do
        CycleBreakers::ConfirmSync.call(account: account)

        expect(edge.reload.repair_outcome).to include("failure_reason")
      end
    end

    context "with multiple pending repairs" do
      let!(:edge1) do
        create(:issue_dependency,
          issue: issue_a,
          depends_on_issue: issue_b,
          repair_status: "pending_sync",
          repair_initiated_at: 2.hours.ago)
      end
      let!(:edge2) do
        create(:issue_dependency,
          issue: issue_b,
          depends_on_issue: issue_a,
          repair_status: "pending_sync",
          repair_initiated_at: 1.hour.ago)
      end

      it "processes all pending repairs" do
        result = CycleBreakers::ConfirmSync.call(account: account)

        expect(result.confirmed_count).to eq 2
        expect(edge1.reload.repair_status).to eq "confirmed"
        expect(edge2.reload.repair_status).to eq "confirmed"
      end
    end

    context "with already confirmed repairs" do
      let!(:edge) do
        create(:issue_dependency,
          issue: issue_a,
          depends_on_issue: issue_b,
          repair_status: "confirmed",
          repair_initiated_at: 1.hour.ago)
      end

      it "does not process confirmed repairs" do
        result = CycleBreakers::ConfirmSync.call(account: account)

        expect(result.confirmed_count).to eq 0
      end
    end

    context "with failed repairs" do
      let!(:edge) do
        create(:issue_dependency,
          issue: issue_a,
          depends_on_issue: issue_b,
          repair_status: "failed",
          repair_initiated_at: 1.hour.ago)
      end

      it "does not reprocess failed repairs" do
        result = CycleBreakers::ConfirmSync.call(account: account)

        expect(result.confirmed_count).to eq 0
      end
    end

    context "when cycle detection fails" do
      let!(:edge) do
        create(:issue_dependency,
          issue: issue_a,
          depends_on_issue: issue_b,
          repair_status: "pending_sync",
          repair_initiated_at: 1.hour.ago)
      end

      before do
        allow(Issues::DependencyCycles).to receive(:call).and_raise(StandardError.new("DB error"))
      end

      it "handles the error gracefully" do
        result = CycleBreakers::ConfirmSync.call(account: account)

        # Should continue processing
        expect(result).to be_a(CycleBreakers::ConfirmSync::Result)
      end
    end
  end
end
