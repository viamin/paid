# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRun do
  describe "associations" do
    it { is_expected.to belong_to(:project) }
    it { is_expected.to belong_to(:issue).optional }
    it { is_expected.to have_many(:agent_run_logs).dependent(:destroy) }
  end

  describe "validations" do
    subject { build(:agent_run) }

    it { is_expected.to validate_presence_of(:agent_type) }
    it { is_expected.to validate_inclusion_of(:agent_type).in_array(described_class::AGENT_TYPES) }
    it { is_expected.to validate_presence_of(:status) }
    it { is_expected.to validate_inclusion_of(:status).in_array(described_class::STATUSES) }
    it { is_expected.to validate_length_of(:worktree_path).is_at_most(500) }
    it { is_expected.to validate_length_of(:branch_name).is_at_most(255) }
    it { is_expected.to validate_length_of(:base_commit_sha).is_at_most(40) }
    it { is_expected.to validate_length_of(:result_commit_sha).is_at_most(40) }
    it { is_expected.to validate_length_of(:pull_request_url).is_at_most(500) }
    it { is_expected.to validate_length_of(:temporal_workflow_id).is_at_most(255) }
    it { is_expected.to validate_length_of(:temporal_run_id).is_at_most(255) }
    it { is_expected.to validate_numericality_of(:iterations).is_greater_than_or_equal_to(0).allow_nil }
    it { is_expected.to validate_numericality_of(:tokens_input).is_greater_than_or_equal_to(0).allow_nil }
    it { is_expected.to validate_numericality_of(:tokens_output).is_greater_than_or_equal_to(0).allow_nil }
    it { is_expected.to validate_numericality_of(:cost_cents).is_greater_than_or_equal_to(0).allow_nil }
    it { is_expected.to validate_numericality_of(:duration_seconds).is_greater_than_or_equal_to(0).allow_nil }

    describe "issue project validation" do
      it "allows issue from the same project" do
        project = create(:project)
        issue = create(:issue, project: project)
        agent_run = build(:agent_run, project: project, issue: issue)

        expect(agent_run).to be_valid
      end

      it "rejects issue from a different project" do
        project = create(:project)
        other_project = create(:project)
        issue = create(:issue, project: other_project)
        agent_run = build(:agent_run, project: project, issue: issue)

        expect(agent_run).not_to be_valid
        expect(agent_run.errors[:issue]).to include("must belong to the same project")
      end

      it "allows nil issue" do
        agent_run = build(:agent_run, issue: nil)

        expect(agent_run).to be_valid
      end
    end
  end

  describe "scopes" do
    describe ".by_status" do
      it "returns agent runs with the specified status" do
        running_run = create(:agent_run, :running)
        create(:agent_run, :completed)

        expect(described_class.by_status("running")).to include(running_run)
        expect(described_class.by_status("running").count).to eq(1)
      end
    end

    describe ".pending" do
      it "returns only pending runs" do
        pending_run = create(:agent_run)
        create(:agent_run, :running)

        expect(described_class.pending).to include(pending_run)
        expect(described_class.pending.count).to eq(1)
      end
    end

    describe ".running" do
      it "returns only running runs" do
        running_run = create(:agent_run, :running)
        create(:agent_run)

        expect(described_class.running).to include(running_run)
        expect(described_class.running.count).to eq(1)
      end
    end

    describe ".completed" do
      it "returns only completed runs" do
        completed_run = create(:agent_run, :completed)
        create(:agent_run)

        expect(described_class.completed).to include(completed_run)
        expect(described_class.completed.count).to eq(1)
      end
    end

    describe ".failed" do
      it "returns only failed runs" do
        failed_run = create(:agent_run, :failed)
        create(:agent_run)

        expect(described_class.failed).to include(failed_run)
        expect(described_class.failed.count).to eq(1)
      end
    end

    describe ".cancelled" do
      it "returns only cancelled runs" do
        cancelled_run = create(:agent_run, :cancelled)
        create(:agent_run)

        expect(described_class.cancelled).to include(cancelled_run)
        expect(described_class.cancelled.count).to eq(1)
      end
    end

    describe ".timeout" do
      it "returns only timeout runs" do
        timeout_run = create(:agent_run, :timeout)
        create(:agent_run)

        expect(described_class.timeout).to include(timeout_run)
        expect(described_class.timeout.count).to eq(1)
      end
    end

    describe ".active" do
      it "includes pending and running runs" do
        pending_run = create(:agent_run)
        running_run = create(:agent_run, :running)
        create(:agent_run, :completed)

        active = described_class.active
        expect(active).to include(pending_run, running_run)
        expect(active.count).to eq(2)
      end
    end

    describe ".finished" do
      it "includes completed, failed, cancelled, and timeout runs" do
        completed_run = create(:agent_run, :completed)
        failed_run = create(:agent_run, :failed)
        cancelled_run = create(:agent_run, :cancelled)
        timeout_run = create(:agent_run, :timeout)
        create(:agent_run)

        finished = described_class.finished
        expect(finished).to include(completed_run, failed_run, cancelled_run, timeout_run)
        expect(finished.count).to eq(4)
      end
    end

    describe ".recent" do
      it "orders by created_at descending" do
        older_run = create(:agent_run, created_at: 1.hour.ago)
        newer_run = create(:agent_run, created_at: 1.minute.ago)

        expect(described_class.recent.first).to eq(newer_run)
        expect(described_class.recent.last).to eq(older_run)
      end
    end
  end

  describe "instance methods" do
    describe "#duration" do
      it "returns nil when started_at is nil" do
        agent_run = build(:agent_run, started_at: nil)

        expect(agent_run.duration).to be_nil
      end

      it "returns seconds between started_at and completed_at" do
        agent_run = build(:agent_run, started_at: 10.minutes.ago, completed_at: 5.minutes.ago)

        expect(agent_run.duration).to be_within(1).of(300)
      end

      it "returns seconds from started_at to now when not completed" do
        agent_run = build(:agent_run, started_at: 5.minutes.ago, completed_at: nil)

        expect(agent_run.duration).to be_within(1).of(300)
      end
    end

    describe "#running?" do
      it "returns true when status is running" do
        agent_run = build(:agent_run, :running)

        expect(agent_run.running?).to be true
      end

      it "returns false when status is not running" do
        agent_run = build(:agent_run)

        expect(agent_run.running?).to be false
      end
    end

    describe "#finished?" do
      it "returns true for completed status" do
        expect(build(:agent_run, :completed).finished?).to be true
      end

      it "returns true for failed status" do
        expect(build(:agent_run, :failed).finished?).to be true
      end

      it "returns true for cancelled status" do
        expect(build(:agent_run, :cancelled).finished?).to be true
      end

      it "returns true for timeout status" do
        expect(build(:agent_run, :timeout).finished?).to be true
      end

      it "returns false for pending status" do
        expect(build(:agent_run).finished?).to be false
      end

      it "returns false for running status" do
        expect(build(:agent_run, :running).finished?).to be false
      end
    end

    describe "#successful?" do
      it "returns true when status is completed" do
        agent_run = build(:agent_run, :completed)

        expect(agent_run.successful?).to be true
      end

      it "returns false when status is not completed" do
        agent_run = build(:agent_run, :failed)

        expect(agent_run.successful?).to be false
      end
    end

    describe "#total_tokens" do
      it "returns sum of input and output tokens" do
        agent_run = build(:agent_run, tokens_input: 1000, tokens_output: 500)

        expect(agent_run.total_tokens).to eq(1500)
      end
    end

    describe "#start!" do
      it "sets status to running and sets started_at" do
        agent_run = create(:agent_run)

        freeze_time do
          agent_run.start!

          expect(agent_run.status).to eq("running")
          expect(agent_run.started_at).to eq(Time.current)
        end
      end
    end

    describe "#complete!" do
      it "sets status to completed with results and duration", :aggregate_failures do
        started_time = 10.minutes.ago
        agent_run = create(:agent_run, status: "running", started_at: started_time)

        freeze_time do
          agent_run.complete!(
            result_commit: "abc123",
            pr_url: "https://github.com/example/repo/pull/42",
            pr_number: 42
          )

          expect(agent_run.status).to eq("completed")
          expect(agent_run.completed_at).to eq(Time.current)
          expect(agent_run.result_commit_sha).to eq("abc123")
          expect(agent_run.pull_request_url).to eq("https://github.com/example/repo/pull/42")
          expect(agent_run.pull_request_number).to eq(42)
          expect(agent_run.duration_seconds).to eq((Time.current - started_time).to_i)
        end
      end
    end

    describe "#fail!" do
      it "sets status to failed with error message and duration" do
        started_time = 10.minutes.ago
        agent_run = create(:agent_run, status: "running", started_at: started_time)

        freeze_time do
          agent_run.fail!(error: "Something went wrong")

          expect(agent_run.status).to eq("failed")
          expect(agent_run.completed_at).to eq(Time.current)
          expect(agent_run.error_message).to eq("Something went wrong")
          expect(agent_run.duration_seconds).to eq((Time.current - started_time).to_i)
        end
      end
    end

    describe "#cancel!" do
      it "sets status to cancelled with duration" do
        started_time = 5.minutes.ago
        agent_run = create(:agent_run, status: "running", started_at: started_time)

        freeze_time do
          agent_run.cancel!

          expect(agent_run.status).to eq("cancelled")
          expect(agent_run.completed_at).to eq(Time.current)
          expect(agent_run.duration_seconds).to eq((Time.current - started_time).to_i)
        end
      end
    end

    describe "#timeout!" do
      it "sets status to timeout with duration" do
        started_time = 1.hour.ago
        agent_run = create(:agent_run, status: "running", started_at: started_time)

        freeze_time do
          agent_run.timeout!

          expect(agent_run.status).to eq("timeout")
          expect(agent_run.completed_at).to eq(Time.current)
          expect(agent_run.duration_seconds).to eq((Time.current - started_time).to_i)
        end
      end
    end

    describe "#log!" do
      it "creates an agent_run_log with the given type and content" do
        agent_run = create(:agent_run)

        expect {
          agent_run.log!("stdout", "Hello world")
        }.to change(AgentRunLog, :count).by(1)

        log = agent_run.agent_run_logs.last
        expect(log.log_type).to eq("stdout")
        expect(log.content).to eq("Hello world")
        expect(log.metadata).to be_nil
      end

      it "stores optional metadata as JSON" do
        agent_run = create(:agent_run)

        agent_run.log!("system", "container.started", metadata: { container_id: "abc123", image: "paid-agent:latest" })

        log = agent_run.agent_run_logs.last
        expect(log.metadata).to eq({ "container_id" => "abc123", "image" => "paid-agent:latest" })
      end

      it "returns the created log entry" do
        agent_run = create(:agent_run)

        log = agent_run.log!("stderr", "Error message")

        expect(log).to be_a(AgentRunLog)
        expect(log).to be_persisted
      end

      it "raises error for invalid log type" do
        agent_run = create(:agent_run)

        expect {
          agent_run.log!("invalid_type", "content")
        }.to raise_error(ActiveRecord::RecordInvalid)
      end
    end

    describe "#execute_agent" do
      let(:response) do
        AgentHarness::Response.new(
          output: "Done",
          exit_code: 0,
          duration: 10.0,
          provider: :claude
        )
      end

      before do
        allow(AgentHarness).to receive(:send_message).and_return(response)
      end

      it "delegates to AgentRuns::Execute without timeout by default" do
        agent_run = create(:agent_run)

        expect(AgentRuns::Execute).to receive(:call).with(
          agent_run: agent_run,
          prompt: "Fix the bug"
        ).and_call_original

        agent_run.execute_agent("Fix the bug")
      end

      it "passes custom timeout when provided" do
        agent_run = create(:agent_run)

        expect(AgentRuns::Execute).to receive(:call).with(
          agent_run: agent_run,
          prompt: "Fix it",
          timeout: 1200
        ).and_call_original

        agent_run.execute_agent("Fix it", timeout: 1200)
      end
    end

    describe "#prompt_for_issue" do
      it "returns nil when no issue is attached" do
        agent_run = build(:agent_run, issue: nil)

        expect(agent_run.prompt_for_issue).to be_nil
      end

      it "builds a prompt when issue is attached" do
        project = create(:project)
        issue = create(:issue, project: project, title: "Fix auth", github_number: 5)
        agent_run = build(:agent_run, project: project, issue: issue)

        prompt = agent_run.prompt_for_issue

        expect(prompt).to include("Fix auth")
        expect(prompt).to include("#5")
      end
    end

    describe "container integration methods" do
      let(:worktree_path) { Dir.mktmpdir("worktree") }
      let(:mock_container) do
        instance_double(
          Docker::Container,
          id: "abc123container",
          start: true,
          stop: true,
          delete: true,
          refresh!: true,
          info: { "State" => { "Running" => true, "ExitCode" => 0 } },
          exec: nil
        )
      end

      before do
        allow(Docker::Container).to receive(:create).and_return(mock_container)
        allow(NetworkPolicy).to receive_messages(ensure_network!: instance_double(Docker::Network), apply_firewall_rules: nil)
      end

      after do
        FileUtils.rm_rf(worktree_path) if worktree_path && Dir.exist?(worktree_path)
      end

      describe "#provision_container" do
        it "provisions a container using the worktree_path" do
          agent_run = create(:agent_run, worktree_path: worktree_path)

          result = agent_run.provision_container

          expect(result).to be_success
          expect(result[:container_id]).to eq("abc123container")
        end

        it "raises ArgumentError when worktree_path is blank" do
          agent_run = create(:agent_run, worktree_path: nil)

          expect { agent_run.provision_container }.to raise_error(ArgumentError, /worktree_path is required/)
        end

        it "accepts optional container options" do
          agent_run = create(:agent_run, worktree_path: worktree_path)

          expect(Containers::Provision).to receive(:new).with(
            agent_run: agent_run,
            worktree_path: worktree_path,
            memory_bytes: 1024 * 1024 * 1024
          ).and_call_original

          agent_run.provision_container(memory_bytes: 1024 * 1024 * 1024)
        end
      end

      describe "#execute_in_container" do
        it "executes command in the provisioned container" do
          agent_run = create(:agent_run, worktree_path: worktree_path)
          agent_run.provision_container

          allow(mock_container).to receive(:exec) do |_cmd, **_opts, &block|
            block.call(:stdout, "output\n") if block
          end

          result = agent_run.execute_in_container("echo hello")

          expect(result).to be_success
          expect(result[:stdout]).to eq("output\n")
        end

        it "raises ProvisionError when container not provisioned" do
          agent_run = create(:agent_run, worktree_path: worktree_path)

          expect { agent_run.execute_in_container("echo hello") }
            .to raise_error(Containers::Provision::ProvisionError, /not provisioned/)
        end
      end

      describe "#cleanup_container" do
        it "cleans up the provisioned container" do
          agent_run = create(:agent_run, worktree_path: worktree_path)
          agent_run.provision_container

          expect(mock_container).to receive(:delete)

          agent_run.cleanup_container
        end

        it "does nothing when no container is provisioned" do
          agent_run = create(:agent_run, worktree_path: worktree_path)

          expect { agent_run.cleanup_container }.not_to raise_error
        end
      end

      describe "#with_container" do
        it "provisions, yields, and cleans up" do
          agent_run = create(:agent_run, worktree_path: worktree_path)
          yielded = false

          agent_run.with_container do |ar|
            expect(ar).to eq(agent_run)
            yielded = true
          end

          expect(yielded).to be true
        end

        it "cleans up even when block raises" do
          agent_run = create(:agent_run, worktree_path: worktree_path)
          expect(mock_container).to receive(:delete)

          expect {
            agent_run.with_container { raise "test error" }
          }.to raise_error("test error")
        end

        it "raises ArgumentError when worktree_path is blank" do
          agent_run = create(:agent_run, worktree_path: nil)

          expect { agent_run.with_container { } }.to raise_error(ArgumentError, /worktree_path is required/)
        end
      end
    end
  end

  describe "constants" do
    it "defines valid STATUSES" do
      expect(described_class::STATUSES).to eq(%w[pending running completed failed cancelled timeout])
    end

    it "defines valid AGENT_TYPES" do
      expect(described_class::AGENT_TYPES).to eq(%w[claude_code cursor codex copilot aider gemini opencode kilocode api])
    end
  end

  describe "defaults" do
    it "defaults status to pending" do
      agent_run = create(:agent_run)
      expect(agent_run.status).to eq("pending")
    end

    it "defaults iterations to 0" do
      agent_run = create(:agent_run)
      expect(agent_run.iterations).to eq(0)
    end

    it "defaults tokens_input to 0" do
      agent_run = create(:agent_run)
      expect(agent_run.tokens_input).to eq(0)
    end

    it "defaults tokens_output to 0" do
      agent_run = create(:agent_run)
      expect(agent_run.tokens_output).to eq(0)
    end

    it "defaults cost_cents to 0" do
      agent_run = create(:agent_run)
      expect(agent_run.cost_cents).to eq(0)
    end
  end

  describe "project association" do
    it "is destroyed when project is destroyed" do
      project = create(:project)
      agent_run = create(:agent_run, project: project)

      expect { project.destroy }.to change(described_class, :count).by(-1)
      expect { agent_run.reload }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  describe "issue association" do
    it "allows agent_run to exist without issue" do
      agent_run = create(:agent_run, issue: nil)
      expect(agent_run.issue).to be_nil
      expect(agent_run).to be_valid
    end

    it "sets issue to nil when issue is destroyed" do
      issue = create(:issue)
      agent_run = create(:agent_run, project: issue.project, issue: issue)

      issue.destroy
      agent_run.reload

      expect(agent_run.issue_id).to be_nil
    end
  end

  describe "agent_run_logs association" do
    it "destroys logs when agent_run is destroyed" do
      agent_run = create(:agent_run)
      create(:agent_run_log, agent_run: agent_run)
      create(:agent_run_log, agent_run: agent_run)

      expect { agent_run.destroy }.to change(AgentRunLog, :count).by(-2)
    end
  end
end
