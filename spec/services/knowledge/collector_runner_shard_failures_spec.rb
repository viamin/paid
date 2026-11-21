# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

RSpec.describe Knowledge::CollectorRunner do
  let(:project) { create(:project) }
  let(:version) { create(:project_version, project:, commit_sha: "f" * 40) }

  around do |example|
    registry = described_class.registry.dup
    described_class.register("tree_sitter", Knowledge::Collectors::TreeSitterCollector)
    described_class.register("symbol_index", Knowledge::Collectors::SymbolIndexCollector)
    example.run
  ensure
    described_class.registry.replace(registry)
  end

  def collect_with_output(type, output: nil, error: nil)
    Dir.mktmpdir("paid-shard-failure") do |dir|
      File.write(File.join(dir, "a.rb"), "class First; end")
      File.write(File.join(dir, "b.rb"), "class Second; end")
      container = instance_double(Knowledge::ContainerizedRunner,
        host_repo_dir: dir, options: { workspace_mount: "/workspace" })
      allow(container).to receive(:execute) do |argv, **|
        next "ast-grep 0.41.0" if argv.include?("--version")
        raise error if error

        output
      end
      described_class.call(project:, commit_sha: version.commit_sha,
        options: { container_runner: container, collector_types: [ type ], partial_collection: true, resume_interrupted: true })
    end
  end

  %w[tree_sitter symbol_index].each do |type|
    context "with a #{type} checkpoint" do
      let!(:run) do
        create(:collector_run, project_version: version, collector_type: type, status: "failed", progress_cursor: "a.rb")
      end

      {
        "timeout" => -> { Knowledge::ContainerizedRunner::TimeoutError.new("Command timed out after 60 seconds") },
        "OOM exit" => -> { Knowledge::ContainerizedRunner::ContainerError.new("Command failed (exit 137): killed") },
        "parser error exit" => -> { Knowledge::ContainerizedRunner::ContainerError.new("Command failed (exit 2): parser failed") },
        "invalid JSON" => -> { nil },
        "empty JSON output" => -> { nil }
      }.each do |failure, build_error|
        # @spec KNOWLEDGE-014
        it "retains the checkpoint and blocks finalization after #{failure}" do
          result = collect_with_output(type, output: failure == "empty JSON output" ? "" : "truncated-output", error: build_error.call)

          expect(result.fetch(:results).sole[:status]).to eq("failed")
          expect(run.reload).to have_attributes(status: "failed", progress_cursor: "a.rb")
          expect(described_class.finalize_collection(project:, commit_sha: version.commit_sha, collector_types: [ type ])).to be(false)
        end
      end

      # @spec KNOWLEDGE-014
      it "resumes the same run after a parser failure" do
        error = Knowledge::ContainerizedRunner::TimeoutError.new("Command timed out after 60 seconds")
        collect_with_output(type, error:)

        result = collect_with_output(type, output: "[]")

        expect(result.fetch(:results).sole[:status]).to eq("completed")
        expect(run.reload).to have_attributes(status: "completed", progress_cursor: nil)
        expect(version.collector_runs.where(collector_type: type).count).to eq(1)
      end

      # @spec KNOWLEDGE-014
      it "completes a valid empty final shard when ast-grep reports no matches" do
        result = collect_with_output(type,
          error: Knowledge::ContainerizedRunner::ContainerError.new("Command failed (exit 1): "))

        expect(result.fetch(:results).sole[:status]).to eq("completed")
        expect(run.reload).to have_attributes(status: "completed", progress_cursor: nil)
      end
    end
  end
end
