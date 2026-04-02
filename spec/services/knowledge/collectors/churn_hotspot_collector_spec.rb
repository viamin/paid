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
  let(:scc_by_file_json) { file_fixture("knowledge/scc_by_file.json").read }
  let(:git_log_data) { "--abc123--2025-01-01--Alice\n10\t2\tapp/models/agent_run.rb\n" }
  let(:repo_path) { "/tmp/test-repo" }
  let(:worktree_entry) { Struct.new(:path).new(repo_path) }
  let(:worktrees_stub) do
    ordered = Struct.new(:first).new(worktree_entry)
    Struct.new(:ordered).new(ordered).tap do |stub|
      stub.define_singleton_method(:order) { |*| ordered }
    end
  end

  # Helper to stub all three shell commands used by the collector:
  # git log, ruby-maat, and scc. Validates the expected command shape for each
  # invocation and raises on unrecognized commands to prevent tests from
  # silently passing when the collector shells out unexpectedly.
  def stub_collector_commands(git_log: git_log_data, revisions: revisions_csv, scc: scc_by_file_json)
    allow(Open3).to receive(:popen3).and_wrap_original do |_original, *args, **_kwargs, &block|
      status = instance_double(Process::Status, success?: true, exitstatus: 0)
      wait_thr = instance_double(Process::Waiter, pid: 12345, value: status)
      stdin_io = Popen3Stub::FakeIO.new

      stdout_content = if args.first == "git" && args.include?("log")
        git_log
      elsif args.first == "ruby-maat"
        revisions
      elsif args.first == "scc"
        scc
      else
        raise "Unexpected command in test: #{args.inspect}"
      end

      block.call(stdin_io, Popen3Stub::FakeIO.new(stdout_content), Popen3Stub::FakeIO.new(""), wait_thr)
    end
  end

  def stub_failing_git_command(scc: scc_by_file_json)
    allow(Open3).to receive(:popen3).and_wrap_original do |_original, *args, **_kwargs, &block|
      stdin_io = Popen3Stub::FakeIO.new

      if args.first == "git" && args.include?("log")
        status = instance_double(Process::Status, success?: false, exitstatus: 1)
        wait_thr = instance_double(Process::Waiter, pid: 12345, value: status)
        block.call(stdin_io, Popen3Stub::FakeIO.new(""), Popen3Stub::FakeIO.new("error"), wait_thr)
      elsif args.first == "scc"
        status = instance_double(Process::Status, success?: true, exitstatus: 0)
        wait_thr = instance_double(Process::Waiter, pid: 12345, value: status)
        block.call(stdin_io, Popen3Stub::FakeIO.new(scc), Popen3Stub::FakeIO.new(""), wait_thr)
      else
        raise "Unexpected command in test: #{args.inspect}"
      end
    end
  end

  describe "#collector_type" do
    it "returns 'churn_hotspot'" do
      expect(collector.collector_type).to eq("churn_hotspot")
    end
  end

  describe "#tool_version" do
    it "returns ruby-maat version when available" do
      stub_popen3(%w[ruby-maat --version], stdout: "ruby-maat 1.2.0\n")

      expect(collector.tool_version).to eq("ruby-maat 1.2.0")
    end

    it "returns nil when ruby-maat is not installed" do
      allow(Open3).to receive(:popen3).and_raise(Errno::ENOENT)

      expect(collector.tool_version).to be_nil
    end
  end

  describe "#collect" do
    context "when tools produce valid output" do
      before { stub_collector_commands }

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
        expect(artifact[:content]).to include("complexity score 5")
        expect(artifact[:content]).to start_with("Churn hotspot: app/models/agent_run.rb")
      end

      it "populates metadata with revisions, complexity, and rank" do
        artifact = collector.collect.find { |a| a[:identifier] == "app/models/agent_run.rb" }

        expect(artifact[:metadata][:revisions]).to eq(47)
        expect(artifact[:metadata][:complexity]).to eq(5)
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

        expect(chunk[:content]).to include("complexity 2")
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

    context "when git log fails" do
      before { stub_failing_git_command }

      it "returns complexity-only artifacts with zero revisions" do
        artifacts = collector.collect

        expect(artifacts).not_to be_empty
        artifacts.each do |a|
          expect(a[:metadata][:revisions]).to eq(0)
        end
      end
    end

    context "when all tools produce empty output" do
      before { stub_collector_commands(git_log: "", revisions: "", scc: "") }

      it "returns empty array" do
        expect(collector.collect).to eq([])
      end
    end

    context "when revisions CSV is header-only" do
      before { stub_collector_commands(revisions: "entity,n-revs\n", scc: "[]") }

      it "returns empty array" do
        expect(collector.collect).to eq([])
      end
    end
  end
end
