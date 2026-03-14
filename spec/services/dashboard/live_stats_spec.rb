# frozen_string_literal: true

require "rails_helper"

RSpec.describe Dashboard::LiveStats do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }

  describe ".call" do
    subject(:stats) { described_class.call(account: account) }

    context "with no agent runs" do
      it "returns zero counts" do
        expect(stats[:active_runs]).to eq(0)
        expect(stats[:queued_runs]).to eq(0)
        expect(stats[:completed_today]).to eq(0)
        expect(stats[:failed_today]).to eq(0)
        expect(stats[:active_containers]).to eq(0)
      end

      it "returns project counts" do
        project # ensure created
        expect(stats[:total_projects]).to eq(1)
        expect(stats[:active_projects]).to eq(1)
      end
    end

    context "with active runs" do
      before do
        create(:agent_run, :running, project: project, container_id: "abc123")
        create(:agent_run, project: project) # pending
        create(:agent_run, :queued, project: project)
        create(:agent_run, :completed, project: project, completed_at: Time.current)
        create(:agent_run, :failed, project: project, completed_at: Time.current)
        create(:agent_run, :completed, project: project, completed_at: 2.days.ago)
      end

      it "counts active runs" do
        expect(stats[:active_runs]).to eq(2)
      end

      it "counts queued runs" do
        expect(stats[:queued_runs]).to eq(1)
      end

      it "counts completed today" do
        expect(stats[:completed_today]).to eq(1)
      end

      it "counts failed today" do
        expect(stats[:failed_today]).to eq(1)
      end

      it "counts active containers" do
        expect(stats[:active_containers]).to eq(1)
      end
    end

    context "with runs from another account" do
      let(:other_account) { create(:account) }
      let(:other_project) { create(:project, account: other_account) }

      before do
        create(:agent_run, :running, project: other_project)
      end

      it "excludes runs from other accounts" do
        expect(stats[:active_runs]).to eq(0)
      end
    end
  end
end
