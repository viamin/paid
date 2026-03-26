# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Collectors::ChurnHotspotCollector do
  subject(:collector) do
    described_class.new(
      project: project,
      project_version: project_version,
      collector_run: collector_run
    )
  end

  let(:project) { build(:project) }
  let(:project_version) { build(:project_version, project: project) }
  let(:collector_run) { build(:collector_run, project_version: project_version) }

  let(:revisions_csv) { file_fixture("knowledge/maat_revisions.csv").read }
  let(:hotspots_csv) { file_fixture("knowledge/maat_hotspots.csv").read }
  let(:repo_path) { "/tmp/test-repo" }
  let(:worktree) { instance_double(Worktree, host_path: repo_path) }
  let(:worktrees_relation) { instance_double(ActiveRecord::Relation, first: worktree) }

  before do
    allow(project).to receive(:worktrees).and_return(
      instance_double(ActiveRecord::Relation, order: worktrees_relation)
    )
  end

  describe "#collector_type" do
    it "returns 'churn_hotspot'" do
      expect(collector.collector_type).to eq("churn_hotspot")
    end
  end

  describe "#tool_version" do
    it "returns maat version when available" do
      allow(Open3).to receive(:capture3)
        .with("maat --version", timeout: 30)
        .and_return([ "maat 1.0.4\n", "", instance_double(Process::Status, success?: true) ])

      expect(collector.tool_version).to eq("maat 1.0.4")
    end

    it "returns nil when maat is not installed" do
      allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT)

      expect(collector.tool_version).to be_nil
    end
  end

  describe "#collect" do
    context "when maat produces valid output" do
      before do
        allow(Open3).to receive(:capture3)
          .with("maat -c git2 -l /tmp/test-repo -a revisions", timeout: 120)
          .and_return([ revisions_csv, "", instance_double(Process::Status, success?: true) ])
        allow(Open3).to receive(:capture3)
          .with("maat -c git2 -l /tmp/test-repo -a hotspots", timeout: 120)
          .and_return([ hotspots_csv, "", instance_double(Process::Status, success?: true) ])
      end

      it "returns artifacts sorted by score (revisions * complexity)" do
        artifacts = collector.collect

        expect(artifacts.size).to eq(5)
        expect(artifacts.first[:identifier]).to eq("app/controllers/projects_controller.rb")
      end

      it "produces artifacts with correct structure" do
        artifact = collector.collect.find { |a| a[:identifier] == "app/models/agent_run.rb" }

        expect(artifact[:artifact_type]).to eq("churn_hotspot")
        expect(artifact[:scope_path]).to eq("app/models/agent_run.rb")
        expect(artifact[:content]).to include("47 revisions")
        expect(artifact[:content]).to include("complexity score 23")
      end

      it "populates metadata with revisions, complexity, and rank" do
        artifact = collector.collect.find { |a| a[:identifier] == "app/models/agent_run.rb" }

        expect(artifact[:metadata][:revisions]).to eq(47)
        expect(artifact[:metadata][:complexity]).to eq(23)
        expect(artifact[:metadata][:rank]).to be_a(Integer)
      end

      it "includes summary chunks" do
        artifact = collector.collect.find { |a| a[:identifier] == "app/models/agent_run.rb" }
        chunk = artifact[:chunks].first

        expect(chunk[:chunk_type]).to eq("summary")
        expect(chunk[:content]).to include("47 revisions")
        expect(chunk[:scope_tags]).to eq([ "churn", "hotspot" ])
      end

      it "ranks files by score descending" do
        artifacts = collector.collect
        scores = artifacts.map { |a| a[:metadata][:revisions] * a[:metadata][:complexity] }

        expect(scores).to eq(scores.sort.reverse)
      end

      it "includes files that appear in only one analysis" do
        artifacts = collector.collect
        identifiers = artifacts.map { |a| a[:identifier] }

        expect(identifiers).to include("lib/utils/helper.rb")
        expect(identifiers).to include("config/routes.rb")
      end
    end

    context "when no repo path is available" do
      let(:worktrees_relation) { instance_double(ActiveRecord::Relation, first: nil) }

      before do
        allow(Rails.root).to receive(:join).and_return(Pathname.new("/nonexistent/path"))
      end

      it "returns empty array" do
        expect(collector.collect).to eq([])
      end
    end

    context "when maat fails" do
      before do
        allow(Open3).to receive(:capture3).and_return(
          [ "", "error", instance_double(Process::Status, success?: false, exitstatus: 1) ]
        )
      end

      it "returns empty array" do
        expect(collector.collect).to eq([])
      end
    end

    context "when maat produces empty output" do
      before do
        allow(Open3).to receive(:capture3).and_return(
          [ "", "", instance_double(Process::Status, success?: true) ]
        )
      end

      it "returns empty array" do
        expect(collector.collect).to eq([])
      end
    end

    context "when maat produces header-only output" do
      before do
        allow(Open3).to receive(:capture3).and_return(
          [ "entity,n-revs\n", "", instance_double(Process::Status, success?: true) ]
        )
      end

      it "returns empty array" do
        expect(collector.collect).to eq([])
      end
    end
  end
end
