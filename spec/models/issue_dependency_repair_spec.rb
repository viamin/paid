# frozen_string_literal: true

require "rails_helper"

RSpec.describe IssueDependency, "repair tracking" do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:issue_a) { create(:issue, project: project, github_number: 1) }
  let(:issue_b) { create(:issue, project: project, github_number: 2) }

  describe "scopes" do
    let!(:pending) do
      create(:issue_dependency, issue: issue_a, depends_on_issue: issue_b, repair_status: "pending_sync")
    end
    let!(:confirmed) do
      create(:issue_dependency, issue: issue_a, depends_on_issue: issue_b, repair_status: "confirmed")
    end
    let!(:failed) do
      create(:issue_dependency, issue: issue_a, depends_on_issue: issue_b, repair_status: "failed")
    end
    let!(:normal) do
      create(:issue_dependency, issue: issue_a, depends_on_issue: issue_b)
    end

    describe ".pending_repair" do
      it "returns only pending_sync repairs" do
        expect(IssueDependency.pending_repair).to contain_exactly(pending)
      end
    end

    describe ".confirmed_repair" do
      it "returns only confirmed repairs" do
        expect(IssueDependency.confirmed_repair).to contain_exactly(confirmed)
      end
    end

    describe ".failed_repair" do
      it "returns only failed repairs" do
        expect(IssueDependency.failed_repair).to contain_exactly(failed)
      end
    end
  end

  describe "repair attributes" do
    let(:dependency) { create(:issue_dependency, issue: issue_a, depends_on_issue: issue_b) }

    it "has repair_status column" do
      expect(dependency.repair_status).to be_nil
      dependency.update!(repair_status: "pending_sync")
      expect(dependency.reload.repair_status).to eq "pending_sync"
    end

    it "has repair_outcome column with default empty hash" do
      expect(dependency.repair_outcome).to eq({})
      dependency.update!(repair_outcome: { action: "remove", timestamp: Time.current })
      expect(dependency.reload.repair_outcome).to have_key("action")
    end

    it "has repair_attempts counter" do
      expect(dependency.repair_attempts).to eq 0
      dependency.update!(repair_attempts: 2)
      expect(dependency.reload.repair_attempts).to eq 2
    end

    it "has repair_initiated_at timestamp" do
      expect(dependency.repair_initiated_at).to be_nil
      now = Time.current
      dependency.update!(repair_initiated_at: now)
      expect(dependency.reload.repair_initiated_at).to be_close_to(now, within: 1.second)
    end
  end
end
