# frozen_string_literal: true

require "rails_helper"

RSpec.describe PreCommitRequirements::Evaluate do # @spec QUALITY-LOOPS-002 # @spec QUALITY-LOOPS-003
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:owner) { project.effective_owner }
  let(:initiating_user) { nil }
  let(:agent_run) { create(:agent_run, project: project, container_id: "container-123", initiating_user: initiating_user) }

  let(:success_result) { Containers::Provision::Result.success(stdout: "OK", stderr: "", exit_code: 0) }
  let(:failure_result) { Containers::Provision::Result.failure(error: "check failed", stdout: "", stderr: "FAIL", exit_code: 1) }

  before { allow(agent_run).to receive(:log!) }

  describe ".call" do
    context "with no requirements" do
      it "returns passed with empty results" do
        result = described_class.call(agent_run: agent_run)

        expect(result[:passed]).to be true
        expect(result[:results]).to be_empty
        expect(result[:blocking]).to be false
      end
    end

    context "when the run has a non-owner initiating user" do
      let(:initiating_user) { create(:user, account: account) }

      before do
        create(:pre_commit_requirement, account: account, user: initiating_user, name: "lint", command: "bin/lint")
        create(:pre_commit_requirement, account: account, user: owner, name: "owner-only", command: "bin/owner")
        allow(agent_run).to receive(:execute_in_container).with("bin/lint", stream: false).and_return(success_result)
      end

      it "binds user-level requirements to the initiating user" do
        result = described_class.call(agent_run: agent_run)

        expect(result[:results].map { |entry| entry[:name] }).to eq([ "lint" ])
        expect(agent_run).to have_received(:execute_in_container).with("bin/lint", stream: false)
      end
    end

    context "when the run has no initiating user" do
      before do
        create(:pre_commit_requirement, account: account, user: owner, name: "lint", command: "bin/lint")
        allow(agent_run).to receive(:execute_in_container).with("bin/lint", stream: false).and_return(success_result)
      end

      it "falls back to the project owner" do
        result = described_class.call(agent_run: agent_run)

        expect(result[:results].map { |entry| entry[:name] }).to eq([ "lint" ])
        expect(agent_run).to have_received(:execute_in_container).with("bin/lint", stream: false)
      end
    end

    context "when the run is system-initiated and the project has no effective owner" do
      before do
        allow(project).to receive(:effective_owner).and_return(nil)
      end

      it "does not resolve user-level requirements" do
        expect(described_class.call(agent_run: agent_run)).to eq(
          passed: true,
          results: [],
          blocking: false
        )
      end
    end

    context "with a passing check" do
      before do
        create(:pre_commit_requirement, account: account, name: "lint", command: "bin/lint")
        # success_result has exit_code: 0 but is a Result.success — make it truly pass
        allow(agent_run).to receive(:execute_in_container).with("bin/lint", stream: false).and_return(success_result)
      end

      it "returns passed" do
        result = described_class.call(agent_run: agent_run)

        expect(result[:passed]).to be true
        expect(result[:results].first[:passed]).to be true
      end

      it "logs the result as system type" do
        described_class.call(agent_run: agent_run)

        expect(agent_run).to have_received(:log!).with(
          "system",
          a_string_matching(/lint.*passed/),
          metadata: hash_including(event: "pre_commit_check", passed: true)
        )
      end
    end

    context "with a failing blocking check" do
      before do
        create(:pre_commit_requirement, account: account, name: "lint", command: "bin/lint", failure_behavior: "block")
        allow(agent_run).to receive(:execute_in_container).with("bin/lint", stream: false).and_return(failure_result)
      end

      it "returns not passed and blocking" do
        result = described_class.call(agent_run: agent_run)

        expect(result[:passed]).to be false
        expect(result[:blocking]).to be true
        expect(result[:results].first[:passed]).to be false
      end
    end

    context "with binary encoded command output" do
      let(:binary_failure_result) do
        Containers::Provision::Result.failure(
          error: "check failed",
          stdout: "bad \xFF stdout\x00".b,
          stderr: "bad \xFE stderr\x00".b,
          exit_code: 1
        )
      end

      before do
        create(:pre_commit_requirement, account: account, name: "lint", command: "bin/lint", failure_behavior: "block")
        allow(agent_run).to receive(:execute_in_container).with("bin/lint", stream: false).and_return(binary_failure_result)
      end

      it "normalizes output before joining stdout and stderr" do
        result = described_class.call(agent_run: agent_run)

        expect(result[:passed]).to be false
        expect(result[:results].first[:output]).to eq("bad \uFFFD stdout\nbad \uFFFD stderr")
      end
    end

    context "with a failing warn-only check" do
      before do
        create(:pre_commit_requirement, account: account, name: "lint", command: "bin/lint", failure_behavior: "warn")
        allow(agent_run).to receive(:execute_in_container).with("bin/lint", stream: false).and_return(failure_result)
      end

      it "returns passed overall but individual check failed" do
        result = described_class.call(agent_run: agent_run)

        expect(result[:passed]).to be true
        expect(result[:blocking]).to be false
        expect(result[:results].first[:passed]).to be false
      end
    end

    context "with a mutation_test requirement and alive mutations" do
      let(:agent_run) do
        create(:agent_run, :with_git_context, project: project, container_id: "container-123", initiating_user: initiating_user).tap do |run|
          run.update!(worktree_path: Dir.mktmpdir("mutant-results"))
        end
      end

      before do
        create(:pre_commit_requirement, :mutation_test, account: account, project: project, name: "mutant", failure_behavior: "warn")
        mutant_command = MutantResultsReader.with_results_dir(
          "bundle exec mutant run --since HEAD\\~1 --use rspec --jobs 1 --results-dir .mutant/results"
        )
        allow(agent_run).to receive(:execute_in_container).with(
          mutant_command,
          stream: false
        ).and_return(success_result)

        FileUtils.mkdir_p(File.join(agent_run.worktree_path, ".mutant/results"))
        File.write(
          File.join(agent_run.worktree_path, ".mutant/results/run.yml"),
          <<~YAML
            alive_mutations:
              - subject: Foo#bar
                subject_path: app/models/foo.rb
                source_line: 42
                mutation_diff: return true -> return false
          YAML
        )
      end

      after do
        FileUtils.remove_entry(agent_run.worktree_path)
      end

      it "surfaces structured mutation feedback in the result" do
        result = described_class.call(agent_run: agent_run)

        check = result[:results].first
        expect(check[:passed]).to be false
        expect(check[:blocking]).to be false
        expect(check[:quality_feedback]).to be_a(QualityFeedbackService::CheckResult)
        expect(check[:output]).to include("app/models/foo.rb:42")
        expect(check[:output]).to include("Surviving mutation in Foo#bar")
      end
    end

    context "with a container execution error" do
      before do
        create(:pre_commit_requirement, account: account, name: "lint", command: "bin/lint")
        allow(agent_run).to receive(:execute_in_container)
          .and_raise(Containers::Provision::ExecutionError.new(
            "command failed", exit_code: 1, stdout: "output", stderr: "lint error on line 5"
          ))
      end

      it "catches the error and includes stdout/stderr in output" do
        result = described_class.call(agent_run: agent_run)

        expect(result[:passed]).to be false
        expect(result[:results].first[:output]).to include("lint error on line 5")
      end
    end

    context "with a binary encoded container execution error" do
      before do
        create(:pre_commit_requirement, account: account, name: "lint", command: "bin/lint")
        allow(agent_run).to receive(:execute_in_container)
          .and_raise(Containers::Provision::ExecutionError.new(
            "command failed", exit_code: 1, stdout: "bad \xFF stdout\x00".b, stderr: "bad \xFE stderr\x00".b
          ))
      end

      it "normalizes the error output" do
        result = described_class.call(agent_run: agent_run)

        expect(result[:passed]).to be false
        expect(result[:results].first[:output]).to eq("bad \uFFFD stdout\nbad \uFFFD stderr")
      end
    end

    context "with a container execution error without stdout/stderr" do
      before do
        create(:pre_commit_requirement, account: account, name: "lint", command: "bin/lint")
        allow(agent_run).to receive(:execute_in_container)
          .and_raise(Containers::Provision::ExecutionError.new("command failed", exit_code: 1))
      end

      it "falls back to exit code" do
        result = described_class.call(agent_run: agent_run)

        expect(result[:passed]).to be false
        expect(result[:results].first[:output]).to include("exited with code 1")
      end
    end

    context "with a timeout error" do
      before do
        create(:pre_commit_requirement, account: account, name: "lint", command: "bin/lint")
        allow(agent_run).to receive(:execute_in_container)
          .and_raise(Containers::Provision::TimeoutError.new("timed out"))
      end

      it "catches the error and marks check as failed" do
        result = described_class.call(agent_run: agent_run)

        expect(result[:passed]).to be false
        expect(result[:results].first[:output]).to include("timed out")
      end
    end

    context "with a binary encoded container error message" do
      before do
        create(:pre_commit_requirement, account: account, name: "lint", command: "bin/lint")
        allow(agent_run).to receive(:execute_in_container)
          .and_raise(Containers::Provision::ProvisionError.new("timed out \xFF\x00".b))
      end

      it "normalizes the fallback error message" do
        result = described_class.call(agent_run: agent_run)

        expect(result[:passed]).to be false
        expect(result[:results].first[:output]).to eq("timed out \uFFFD")
      end
    end

    context "with no container" do
      let(:agent_run) { create(:agent_run, project: project, container_id: nil) }

      before do
        create(:pre_commit_requirement, account: account, name: "lint", command: "bin/lint")
      end

      it "marks check as failed with no container message" do
        result = described_class.call(agent_run: agent_run)

        expect(result[:passed]).to be false
        expect(result[:results].first[:output]).to eq("No container available")
      end
    end

    context "with auto-fix that succeeds" do
      before do
        create(:pre_commit_requirement, :with_auto_fix, account: account, name: "lint", command: "bin/lint")
        call_count = 0
        allow(agent_run).to receive(:execute_in_container).with("bin/lint", stream: false) do
          call_count += 1
          call_count == 1 ? failure_result : success_result
        end
        allow(agent_run).to receive(:execute_in_container).with("bin/lint -a", stream: false).and_return(success_result)
      end

      it "retries after fix and marks as auto-fixed" do
        result = described_class.call(agent_run: agent_run)

        expect(result[:passed]).to be true
        expect(result[:results].first[:auto_fixed]).to be true
      end
    end

    context "with auto-fix that exhausts retries" do
      before do
        create(:pre_commit_requirement, :with_auto_fix, account: account, name: "lint", command: "bin/lint")
        allow(agent_run).to receive(:execute_in_container).with("bin/lint", stream: false).and_return(failure_result)
        allow(agent_run).to receive(:execute_in_container).with("bin/lint -a", stream: false).and_return(success_result)
      end

      it "returns failed check after max attempts" do
        result = described_class.call(agent_run: agent_run)

        check = result[:results].first
        expect(check[:passed]).to be false
        expect(check[:output]).to include("exhausted")
        expect(check[:auto_fixed]).to be false
      end

      it "blocks the overall evaluation" do
        result = described_class.call(agent_run: agent_run)

        expect(result[:passed]).to be false
        expect(result[:blocking]).to be true
      end
    end

    context "with auto-fix and no container" do
      let(:agent_run) { create(:agent_run, project: project, container_id: nil) }

      before do
        create(:pre_commit_requirement, :with_auto_fix, account: account, name: "lint", command: "bin/lint")
      end

      it "returns failed with no container message" do
        result = described_class.call(agent_run: agent_run)

        expect(result[:results].first[:output]).to include("No container available")
      end
    end

    context "with auto-fix that raises an error" do
      before do
        create(:pre_commit_requirement, :with_auto_fix, account: account, name: "lint", command: "bin/lint")
        allow(agent_run).to receive(:execute_in_container).with("bin/lint", stream: false).and_return(failure_result)
        allow(agent_run).to receive(:execute_in_container).with("bin/lint -a", stream: false)
          .and_raise(Containers::Provision::ExecutionError.new(
            "fix crashed", exit_code: 1, stderr: "fix error detail"
          ))
      end

      it "catches the error and includes stderr in auto-fix failed output" do
        result = described_class.call(agent_run: agent_run)

        check = result[:results].first
        expect(check[:passed]).to be false
        expect(check[:output]).to include("Auto-fix failed")
        expect(check[:output]).to include("fix error detail")
      end
    end

    context "with auto-fix that raises a binary encoded container error" do
      before do
        create(:pre_commit_requirement, :with_auto_fix, account: account, name: "lint", command: "bin/lint")
        allow(agent_run).to receive(:execute_in_container).with("bin/lint", stream: false).and_return(failure_result)
        allow(agent_run).to receive(:execute_in_container).with("bin/lint -a", stream: false)
          .and_raise(Containers::Provision::ProvisionError.new("fix crashed \xFF\x00".b))
      end

      it "normalizes the auto-fix fallback message" do
        result = described_class.call(agent_run: agent_run)

        check = result[:results].first
        expect(check[:passed]).to be false
        expect(check[:output]).to eq("Auto-fix failed: fix crashed \uFFFD")
      end
    end
  end
end
