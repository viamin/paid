# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::DashboardStats do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }

  describe ".call" do
    subject(:stats) { described_class.call(account: account) }

    context "with no knowledge data" do
      before { project } # ensure project exists

      it "returns zero counts" do
        expect(stats[:projects_indexed]).to eq(0)
        expect(stats[:projects_total]).to eq(1)
        expect(stats[:total_artifacts]).to eq(0)
        expect(stats[:stale_artifacts]).to eq(0)
        expect(stats[:stale_percent]).to eq(0)
        expect(stats[:artifacts_by_type]).to be_empty
        expect(stats[:last_collection_at]).to be_nil
      end
    end

    context "with knowledge artifacts" do
      let(:version) { create(:project_version, project: project) }
      let(:run) { create(:collector_run, :completed, project_version: version) }

      before do
        create_list(:knowledge_artifact, 3, collector_run: run, project: project, artifact_type: "route")
        create_list(:knowledge_artifact, 2, collector_run: run, project: project, artifact_type: "dependency")
        create(:knowledge_artifact, :stale, collector_run: run, project: project, artifact_type: "route")
      end

      it "returns correct artifact counts" do
        expect(stats[:projects_indexed]).to eq(1)
        expect(stats[:total_artifacts]).to eq(5)
        expect(stats[:stale_artifacts]).to eq(1)
      end

      it "calculates stale percentage" do
        expect(stats[:stale_percent]).to eq(17)
      end

      it "returns artifacts by type sorted by count" do
        by_type = stats[:artifacts_by_type].to_h
        expect(by_type["route"]).to eq(3)
        expect(by_type["dependency"]).to eq(2)
      end

      it "returns last collection time" do
        expect(stats[:last_collection_at]).to be_within(1.second).of(run.completed_at)
      end
    end

    context "with multiple projects" do
      let(:project2) { create(:project, account: account) }
      let(:other_account) { create(:account) }
      let(:other_project) { create(:project, account: other_account) }

      before do
        version1 = create(:project_version, project: project)
        run1 = create(:collector_run, :completed, project_version: version1)
        create(:knowledge_artifact, collector_run: run1, project: project)

        # project2 has no artifacts — should not be counted as indexed
        create(:project_version, project: project2)

        # other_account artifacts should not be counted
        other_version = create(:project_version, project: other_project)
        other_run = create(:collector_run, :completed, project_version: other_version)
        create(:knowledge_artifact, collector_run: other_run, project: other_project)
      end

      it "counts only projects in the account" do
        expect(stats[:projects_total]).to eq(2)
        expect(stats[:projects_indexed]).to eq(1)
        expect(stats[:total_artifacts]).to eq(1)
      end
    end
  end
end
