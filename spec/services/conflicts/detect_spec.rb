# frozen_string_literal: true

require "rails_helper"

RSpec.describe Conflicts::Detect do
  describe ".call" do
    it "returns no conflicts when fewer than 2 runs" do
      run = create(:agent_run, :completed)
      result = described_class.call(agent_run_ids: [ run.id ])

      expect(result[:has_conflicts]).to be false
      expect(result[:conflicting_pairs]).to be_empty
      expect(result[:detection_failed]).to be false
      expect(result[:failed_run_ids]).to be_empty
      expect(result[:requires_manual_review]).to be false
    end

    it "returns no conflicts when runs have no git context" do
      project = create(:project)
      run_a = create(:agent_run, :completed, project: project)
      run_b = create(:agent_run, :completed, project: project)

      result = described_class.call(agent_run_ids: [ run_a.id, run_b.id ])

      expect(result[:has_conflicts]).to be false
    end

    context "with git-tracked runs" do
      let(:project) { create(:project) }
      let(:base_sha) { "a" * 40 }

      def create_run(result_sha:, changed_files:)
        run = create(:agent_run, :completed, project: project,
          branch_name: "paid/feature-#{SecureRandom.hex(3)}",
          base_commit_sha: base_sha,
          result_commit_sha: result_sha,
          container_id: nil)
        create(:agent_run_phase, agent_run: run,
          phase_key: "push_branch", phase_group: "post",
          metadata: { "changed_files" => changed_files })
        run
      end

      it "detects overlapping files between two runs" do
        run_a = create_run(result_sha: "b" * 40, changed_files: [ "src/app.rb", "src/config.rb" ])
        run_b = create_run(result_sha: "c" * 40, changed_files: [ "src/app.rb", "test/app_test.rb" ])

        result = described_class.call(agent_run_ids: [ run_a.id, run_b.id ], project_id: project.id)

        expect(result[:has_conflicts]).to be true
        expect(result[:conflicting_pairs].size).to eq(1)
        expect(result[:conflicting_pairs].first[:files]).to eq([ "src/app.rb" ])
      end

      it "returns no conflicts when runs modify different files" do
        run_a = create_run(result_sha: "b" * 40, changed_files: [ "src/users.rb" ])
        run_b = create_run(result_sha: "c" * 40, changed_files: [ "src/orders.rb" ])

        result = described_class.call(agent_run_ids: [ run_a.id, run_b.id ])

        expect(result[:has_conflicts]).to be false
      end

      it "detects conflicts across three runs" do
        run_a = create_run(result_sha: "b" * 40, changed_files: [ "shared.rb", "a.rb" ])
        run_b = create_run(result_sha: "c" * 40, changed_files: [ "shared.rb", "b.rb" ])
        run_c = create_run(result_sha: "d" * 40, changed_files: [ "c.rb" ])

        result = described_class.call(agent_run_ids: [ run_a.id, run_b.id, run_c.id ])

        expect(result[:has_conflicts]).to be true
        expect(result[:conflicting_pairs].size).to eq(1)
        expect(result[:conflicting_pairs].first[:files]).to eq([ "shared.rb" ])
      end

      it "falls back to bare repo diff when container is unavailable" do
        run_a, run_b = create_bare_repo_runs(
          files_a: "src/app.rb\nsrc/config.rb\n",
          files_b: "src/app.rb\ntest/app_test.rb\n"
        )

        result = described_class.call(
          agent_run_ids: [ run_a.id, run_b.id ],
          project_id: run_a.project_id
        )

        expect(result[:has_conflicts]).to be true
        expect(result[:conflicting_pairs].first[:files]).to eq([ "src/app.rb" ])
      end

      it "falls through to metadata when bare repo diff fails" do
        run_a = create_run(result_sha: "b" * 40, changed_files: [ "src/app.rb" ])
        run_b = create_run(result_sha: "c" * 40, changed_files: [ "src/app.rb" ])

        allow(WorktreeService).to receive(:new).and_raise(StandardError, "no repo")

        result = described_class.call(
          agent_run_ids: [ run_a.id, run_b.id ],
          project_id: project.id
        )

        expect(result[:has_conflicts]).to be true
      end

      it "skips runs where base and result SHAs are identical" do
        no_change_run = create(:agent_run, :completed, project: project,
          branch_name: "paid/no-change", base_commit_sha: base_sha, result_commit_sha: base_sha)
        run_b = create_run(result_sha: "b" * 40, changed_files: [ "src/app.rb" ])

        result = described_class.call(agent_run_ids: [ no_change_run.id, run_b.id ])

        expect(result[:has_conflicts]).to be false
      end

      it "includes files_by_run in the result" do
        run_a = create_run(result_sha: "b" * 40, changed_files: [ "x.rb", "y.rb" ])

        result = described_class.call(agent_run_ids: [ run_a.id ])

        expect(result[:files_by_run]).to be_a(Hash)
      end

      it "reports detection_failed when all diff sources return empty for runs with different commits" do
        run_a = create(:agent_run, :completed, project: project,
          branch_name: "paid/feature-a",
          base_commit_sha: base_sha,
          result_commit_sha: "b" * 40,
          container_id: nil)
        run_b = create(:agent_run, :completed, project: project,
          branch_name: "paid/feature-b",
          base_commit_sha: base_sha,
          result_commit_sha: "c" * 40,
          container_id: nil)

        allow(WorktreeService).to receive(:new).and_raise(StandardError, "no repo")

        result = described_class.call(agent_run_ids: [ run_a.id, run_b.id ], project_id: project.id)

        expect(result[:has_conflicts]).to be true
        expect(result[:detection_failed]).to be true
        expect(result[:failed_run_ids]).to contain_exactly(run_a.id, run_b.id)
        expect(result[:requires_manual_review]).to be true
      end

      it "flags diff failures alongside real conflicts" do
        run_a = create_run(result_sha: "b" * 40, changed_files: [ "src/app.rb" ])
        run_b = create_run(result_sha: "c" * 40, changed_files: [ "src/app.rb" ])
        # Run with no metadata and no container — will fail diff
        run_c = create(:agent_run, :completed, project: project,
          branch_name: "paid/feature-c",
          base_commit_sha: base_sha,
          result_commit_sha: "d" * 40,
          container_id: nil)

        allow(WorktreeService).to receive(:new).and_raise(StandardError, "no repo")

        result = described_class.call(
          agent_run_ids: [ run_a.id, run_b.id, run_c.id ],
          project_id: project.id
        )

        expect(result[:has_conflicts]).to be true
        expect(result[:detection_failed]).to be true
        expect(result[:failed_run_ids]).to include(run_c.id)
        expect(result[:requires_manual_review]).to be true
      end

      it "collects changed_files from any phase, not just push_branch" do
        run = create(:agent_run, :completed, project: project,
          branch_name: "paid/feature-multi",
          base_commit_sha: base_sha,
          result_commit_sha: "b" * 40,
          container_id: nil)
        create(:agent_run_phase, agent_run: run,
          phase_key: "execute", phase_group: "agent",
          metadata: { "changed_files" => [ "lib/foo.rb" ] })
        create(:agent_run_phase, agent_run: run,
          phase_key: "push_branch", phase_group: "post",
          metadata: { "changed_files" => [ "lib/bar.rb" ] })

        allow(WorktreeService).to receive(:new).and_raise(StandardError, "no repo")

        result = described_class.call(agent_run_ids: [ run.id ], project_id: project.id)

        expect(result[:files_by_run]).to be_a(Hash)
      end

      def create_bare_repo_runs(files_a:, files_b:)
        bare_project = create(:project)
        worktree_svc = instance_double(WorktreeService)
        allow(WorktreeService).to receive(:new).with(bare_project).and_return(worktree_svc)

        run_a = create(:agent_run, :completed, project: bare_project,
          branch_name: "paid/bare-a", base_commit_sha: base_sha,
          result_commit_sha: "b" * 40, container_id: nil)
        allow(worktree_svc).to receive(:run_repo_command)
          .with("diff", "--name-only", base_sha, "b" * 40).and_return(files_a)

        run_b = create(:agent_run, :completed, project: bare_project,
          branch_name: "paid/bare-b", base_commit_sha: base_sha,
          result_commit_sha: "c" * 40, container_id: nil)
        allow(worktree_svc).to receive(:run_repo_command)
          .with("diff", "--name-only", base_sha, "c" * 40).and_return(files_b)

        [ run_a, run_b ]
      end
    end
  end
end
