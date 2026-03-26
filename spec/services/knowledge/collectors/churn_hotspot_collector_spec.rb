# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Collectors::ChurnHotspotCollector, :no_db do
  subject(:collector) do
    described_class.new(
      project: project,
      project_version: project_version,
      collector_run: collector_run
    )
  end

  let(:project) { Struct.new(:id, :worktrees).new(1, worktrees_stub) }
  let(:project_version) { Struct.new(:id).new(1) }
  let(:collector_run) { Struct.new(:id).new(1) }

  let(:revisions_csv) { file_fixture("knowledge/maat_revisions.csv").read }
  let(:hotspots_csv) { file_fixture("knowledge/maat_hotspots.csv").read }
  let(:repo_path) { "/tmp/test-repo" }
  let(:worktree_entry) { Struct.new(:path).new(repo_path) }
  let(:worktrees_stub) do
    ordered = Struct.new(:first).new(worktree_entry)
    Struct.new(:ordered).new(ordered).tap do |stub|
      stub.define_singleton_method(:order) { |*| ordered }
    end
  end

  describe "#collector_type" do
    it "returns 'churn_hotspot'" do
      expect(collector.collector_type).to eq("churn_hotspot")
    end
  end

  describe "#tool_version" do
    it "returns maat version when available" do
      stub_popen3(%w[maat --version], stdout: "maat 1.0.4\n")

      expect(collector.tool_version).to eq("maat 1.0.4")
    end

    it "returns nil when maat is not installed" do
      allow(Open3).to receive(:popen3).and_raise(Errno::ENOENT)

      expect(collector.tool_version).to be_nil
    end
  end

  describe "#collect" do
    context "when maat produces valid output" do
      before do
        stub_popen3(%w[maat -c git2 -l /tmp/test-repo -a revisions], stdout: revisions_csv)
        stub_popen3(%w[maat -c git2 -l /tmp/test-repo -a hotspots], stdout: hotspots_csv)
      end

      it "returns artifacts sorted by score (revisions * complexity)" do
        artifacts = collector.collect

        expect(artifacts.size).to eq(5)
        expect(artifacts.first[:identifier]).to eq("app/models/agent_run.rb")
      end

      it "produces artifacts with correct structure" do
        artifact = collector.collect.find { |a| a[:identifier] == "app/models/agent_run.rb" }

        expect(artifact[:artifact_type]).to eq("churn_hotspot")
        expect(artifact[:scope_path]).to eq("app/models/agent_run.rb")
        expect(artifact[:content]).to include("47 revisions")
        expect(artifact[:content]).to include("complexity score 23")
        expect(artifact[:content]).to start_with("Churn hotspot: app/models/agent_run.rb")
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

      it "omits complexity from revision-only file summaries" do
        artifact = collector.collect.find { |a| a[:identifier] == "lib/utils/helper.rb" }
        chunk = artifact[:chunks].first

        expect(chunk[:content]).to include("5 revisions")
        expect(chunk[:content]).not_to include("complexity")
      end

      it "does not mention revisions for hotspot-only files" do
        artifact = collector.collect.find { |a| a[:identifier] == "config/routes.rb" }
        chunk = artifact[:chunks].first

        expect(chunk[:content]).to include("complexity 3")
        expect(chunk[:content]).not_to include("revisions")
      end
    end

    context "when no repo path is available" do
      let(:worktree_entry) { nil }

      before do
        allow(Rails.root).to receive(:join).and_return(Pathname.new("/nonexistent/path"))
      end

      it "returns empty array" do
        expect(collector.collect).to eq([])
      end
    end

    context "when maat fails" do
      before do
        stub_popen3(/maat/, stdout: "", stderr: "error", success: false, exit_code: 1)
      end

      it "returns empty array" do
        expect(collector.collect).to eq([])
      end
    end

    context "when maat produces empty output" do
      before do
        stub_popen3(/maat/, stdout: "")
      end

      it "returns empty array" do
        expect(collector.collect).to eq([])
      end
    end

    context "when maat produces header-only output" do
      before do
        stub_popen3(/maat/, stdout: "entity,n-revs\n") # header-only CSV
      end

      it "returns empty array" do
        expect(collector.collect).to eq([])
      end
    end
  end
end
