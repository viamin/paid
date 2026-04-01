# frozen_string_literal: true

require "rails_helper"

RSpec.describe PreCommitRequirements::Evaluate do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:agent_run) { create(:agent_run, project: project, container_id: "container-123") }

  let(:success_result) { Containers::Provision::Result.success(stdout: "OK", stderr: "", exit_code: 0) }
  let(:failure_result) { Containers::Provision::Result.failure(error: "check failed", stdout: "", stderr: "FAIL", exit_code: 1) }

  before do
    # Stub effective_owner to return nil (no user-level requirements)
    allow(project).to receive(:effective_owner).and_return(nil)
    allow(agent_run).to receive(:project).and_return(project)
    allow(agent_run).to receive(:log!)
  end

  describe ".call" do
    context "with no requirements" do
      it "returns passed with empty results" do
        result = described_class.call(agent_run: agent_run)

        expect(result[:passed]).to be true
        expect(result[:results]).to be_empty
        expect(result[:blocking]).to be false
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

    context "with a container execution error" do
      before do
        create(:pre_commit_requirement, account: account, name: "lint", command: "bin/lint")
        allow(agent_run).to receive(:execute_in_container)
          .and_raise(Containers::Provision::ExecutionError.new("command failed", exit_code: 1))
      end

      it "catches the error and marks check as failed" do
        result = described_class.call(agent_run: agent_run)

        expect(result[:passed]).to be false
        expect(result[:results].first[:output]).to include("command failed")
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
          .and_raise(Containers::Provision::ExecutionError.new("fix crashed", exit_code: 1))
      end

      it "catches the error and marks auto-fix as failed" do
        result = described_class.call(agent_run: agent_run)

        check = result[:results].first
        expect(check[:passed]).to be false
        expect(check[:output]).to include("Auto-fix failed")
      end
    end
  end
end
