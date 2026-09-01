# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::BaseActivity do
  describe "InputNormalizer" do
    let(:activity_class) do
      Class.new(described_class) do
        def execute(input)
          input
        end
      end
    end
    let(:activity) do
      stub_const("TestBaseActivity", activity_class)
      TestBaseActivity.new
    end
    let(:connection_pool) { instance_double(ActiveRecord::ConnectionAdapters::ConnectionPool) }
    let(:executor) { object_double(Rails.application.executor) }

    before do
      allow(TenantContext).to receive(:with_system_access).and_yield
      allow(TenantContext).to receive(:with).and_yield
      allow(TenantContext).to receive(:clear!)
      allow(TenantContext).to receive(:bypass_enabled?).and_return(false)
      allow(TenantContext).to receive(:restore!)
      allow(Project).to receive(:find_by)
      allow(ActiveRecord::Base).to receive(:connection_pool).and_return(connection_pool)
      allow(connection_pool).to receive(:active_connection?).and_return(true)
      allow(connection_pool).to receive(:release_connection)
      allow(Rails.application).to receive(:executor).and_return(executor)
      allow(executor).to receive(:wrap).and_yield
    end

    it "normalizes hash inputs, wraps execution in the executor, and releases the DB connection" do
      result = activity.execute("project_id" => 123)

      expect(result).to eq(project_id: 123)
      expect(executor).to have_received(:wrap)
      expect(connection_pool).to have_received(:release_connection)
    end

    it "skips release when no active connection is checked out" do
      allow(connection_pool).to receive(:active_connection?).and_return(false)

      result = activity.execute("project_id" => 456)

      expect(result).to eq(project_id: 456)
      expect(connection_pool).not_to have_received(:release_connection)
    end

    it "releases the DB connection even when execute raises" do
      error_activity_class = Class.new(described_class) do
        def execute(_input)
          raise RuntimeError, "activity failed"
        end
      end
      stub_const("ErrorActivity", error_activity_class)
      error_activity = ErrorActivity.new

      expect { error_activity.execute("project_id" => 789) }.to raise_error(RuntimeError, "activity failed")
      expect(executor).to have_received(:wrap)
      expect(connection_pool).to have_received(:release_connection)
    end

    it "restores the outer tenant context after releasing the connection" do
      # rubocop:disable RSpec/VerifiedDoubles,RSpec/VerifiedDoubleReference
      account = double("Account", id: 123)
      # rubocop:enable RSpec/VerifiedDoubles,RSpec/VerifiedDoubleReference
      Current.account = account

      activity.execute("project_id" => 123)

      expect(connection_pool).to have_received(:release_connection).ordered
      expect(TenantContext).to have_received(:restore!).with(account: account, bypass: false).ordered
    ensure
      Current.reset
    end

    it "restores outer system access after releasing the connection" do
      allow(TenantContext).to receive(:bypass_enabled?).and_return(true)

      activity.execute("project_id" => 123)

      expect(connection_pool).to have_received(:release_connection).ordered
      expect(TenantContext).to have_received(:restore!).with(account: nil, bypass: true).ordered
    end
  end

  describe "#check_rate_budget!" do
    let(:activity_class) do
      Class.new(described_class) do
        def execute(input)
          input
        end
      end
    end
    let(:activity) do
      stub_const("TestRateBudgetActivity", activity_class)
      TestRateBudgetActivity.new
    end
    let(:client) { instance_double(GithubClient) }

    before do
      allow(client).to receive(:rate_limit_remaining!).and_return(100)
    end

    it "does nothing when rate limit is not low" do
      expect { activity.send(:check_rate_budget!, client) }.not_to raise_error
    end

    it "raises a retryable ApplicationError when rate limit is low" do
      allow(client).to receive(:rate_limit_remaining!).and_return(5)

      expect { activity.send(:check_rate_budget!, client) }.to raise_error(
        Temporalio::Error::ApplicationError, /rate limit budget low/i
      ) do |error|
        expect(error.type).to eq("RateLimit")
      end
    end

    it "skips the check when the rate-limit probe fails" do
      allow(client).to receive(:rate_limit_remaining!).and_raise(Octokit::Unauthorized.new)

      expect { activity.send(:check_rate_budget!, client) }.not_to raise_error
    end
  end

  # @spec SESSION-SUMMARY-001
  describe "#capture_session_summary_if_needed" do
    let(:activity_class) do
      Class.new(described_class) do
        def execute(input)
          input
        end
      end
    end
    let(:activity) do
      stub_const("TestSessionSummaryActivity", activity_class)
      TestSessionSummaryActivity.new
    end

    it "enqueues capture for a completed, non-synthetic run with a pull request" do
      agent_run = create(:agent_run, :completed)

      expect { activity.send(:capture_session_summary_if_needed, agent_run) }
        .to have_enqueued_job(CaptureAgentRunSessionSummaryJob).with(agent_run.id)
    end

    it "does not enqueue capture for a run without a pull request" do
      agent_run = create(:agent_run, :completed, pull_request_url: nil)

      expect { activity.send(:capture_session_summary_if_needed, agent_run) }
        .not_to have_enqueued_job(CaptureAgentRunSessionSummaryJob)
    end

    it "does not enqueue capture for a run that is not completed" do
      agent_run = create(:agent_run, :failed)

      expect { activity.send(:capture_session_summary_if_needed, agent_run) }
        .not_to have_enqueued_job(CaptureAgentRunSessionSummaryJob)
    end

    it "does not enqueue capture for a synthetic run" do
      agent_run = create(:agent_run, :completed, synthetic: true)

      expect { activity.send(:capture_session_summary_if_needed, agent_run) }
        .not_to have_enqueued_job(CaptureAgentRunSessionSummaryJob)
    end
  end

  describe "#with_periodic_heartbeat" do
    let(:activity_class) do
      Class.new(described_class) do
        def execute(input)
          input
        end
      end
    end
    let(:activity) do
      stub_const("TestHeartbeatActivity", activity_class)
      TestHeartbeatActivity.new
    end
    let(:mock_context) { instance_double(Temporalio::Activity::Context) }

    before do
      allow(Temporalio::Activity::Context).to receive(:current_or_nil).and_return(mock_context)
    end

    it "kills the worker thread as a last resort when cancellation leaves it running" do
      worker = instance_double(Thread)
      allow(Thread).to receive(:new).and_return(worker)
      allow(worker).to receive(:report_on_exception=).with(false)
      allow(worker).to receive(:join).with(0.01).and_return(false)
      allow(worker).to receive(:join).with(5).and_return(nil)
      allow(worker).to receive(:alive?).and_return(true)
      allow(worker).to receive(:raise).with(Interrupt)
      allow(worker).to receive(:kill)
      allow(mock_context).to receive(:heartbeat).and_raise(Temporalio::Error::CanceledError, "canceled")

      expect {
        activity.send(:with_periodic_heartbeat, "test", interval: 0.01) { :done }
      }.to raise_error(Temporalio::Error::CanceledError)

      expect(worker).to have_received(:raise).with(Interrupt)
      expect(worker).to have_received(:kill)
    end
  end
end
