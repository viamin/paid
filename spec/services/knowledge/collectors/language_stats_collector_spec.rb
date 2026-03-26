# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Collectors::LanguageStatsCollector, :no_db do
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

  let(:scc_json) { file_fixture("knowledge/scc_output.json").read }
  let(:repo_path) { "/tmp/test-repo" }
  let(:worktree_entry) { Struct.new(:path).new(repo_path) }
  let(:worktrees_stub) do
    ordered = Struct.new(:first).new(worktree_entry)
    Struct.new(:ordered).new(ordered).tap do |stub|
      stub.define_singleton_method(:order) { |*| ordered }
    end
  end

  describe "#collector_type" do
    it "returns 'language_stat'" do
      expect(collector.collector_type).to eq("language_stat")
    end
  end

  describe "#tool_version" do
    it "returns scc version when available" do
      stub_popen3(%w[scc --version], stdout: "scc version 3.6.0\n")

      expect(collector.tool_version).to eq("scc version 3.6.0")
    end

    it "returns nil when scc is not installed" do
      allow(Open3).to receive(:popen3).and_raise(Errno::ENOENT)

      expect(collector.tool_version).to be_nil
    end
  end

  describe "#collect" do
    context "when scc produces valid output" do
      before do
        stub_popen3(%w[scc --format json /tmp/test-repo], stdout: scc_json)
      end

      it "returns one artifact per language" do
        artifacts = collector.collect

        expect(artifacts.size).to eq(3)
      end

      it "produces artifacts with correct structure" do
        artifact = collector.collect.first

        expect(artifact[:artifact_type]).to eq("language_stat")
        expect(artifact[:identifier]).to eq("Ruby")
        expect(artifact[:content]).to include("12,456 lines of code")
        expect(artifact[:content]).to include("1,890 comments")
        expect(artifact[:content]).to include("888 blanks")
        expect(artifact[:content]).to include("15,234 total lines")
        expect(artifact[:content]).to include("187 files")
      end

      it "populates metadata with file and line counts" do
        artifact = collector.collect.first

        expect(artifact[:metadata]).to eq(
          files: 187,
          lines: 15234,
          code: 12456,
          comments: 1890,
          blanks: 888
        )
      end

      it "includes summary chunks" do
        artifact = collector.collect.first
        chunk = artifact[:chunks].first

        expect(chunk[:chunk_type]).to eq("summary")
        expect(chunk[:content]).to include("Ruby")
        expect(chunk[:content]).to include("12,456 lines of code")
        expect(chunk[:content]).to include("1,890 comments")
        expect(chunk[:scope_tags]).to eq([ "language", "stats" ])
      end

      it "sets scope_path to nil" do
        artifact = collector.collect.first

        expect(artifact[:scope_path]).to be_nil
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

    context "when scc fails" do
      before do
        stub_popen3(/scc/, stdout: "", stderr: "error", success: false, exit_code: 1)
      end

      it "returns empty array" do
        expect(collector.collect).to eq([])
      end
    end

    context "when scc produces empty output" do
      before do
        stub_popen3(/scc/, stdout: "")
      end

      it "returns empty array" do
        expect(collector.collect).to eq([])
      end
    end

    context "when scc produces empty JSON array" do
      before do
        stub_popen3(/scc/, stdout: "[]")
      end

      it "returns empty array" do
        expect(collector.collect).to eq([])
      end
    end

    context "when scc produces invalid JSON" do
      before do
        stub_popen3(/scc/, stdout: "not json")
      end

      it "returns empty array" do
        expect(collector.collect).to eq([])
      end
    end
  end
end
