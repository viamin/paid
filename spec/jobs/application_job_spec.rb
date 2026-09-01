# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApplicationJob do # @spec EXCEPTION-NOTIFY-003
  describe "notification_subsystem" do
    it "defaults to 'general'" do
      expect(described_class.notification_subsystem).to eq("general")
    end

    it "is inherited by subclasses" do
      job_class = Class.new(described_class) do
        def perform
        end
      end
      stub_const("TestNotificationSubsystemJob", job_class)
      expect(job_class.notification_subsystem).to eq("general")
    end

    it "can be overridden by subclasses" do
      job_class = Class.new(described_class) do
        self.notification_subsystem = "knowledge"

        def perform
        end
      end
      stub_const("TestKnowledgeSubsystemJob", job_class)
      expect(job_class.notification_subsystem).to eq("knowledge")
    end
  end

  describe "notification_project_id" do
    it "defaults to nil" do
      job = described_class.new
      expect(job.notification_project_id).to be_nil
    end
  end

  describe "max_attempts" do
    it "defaults to 1" do
      expect(described_class.max_attempts).to eq(1)
    end
  end

  describe "perform_timeout" do
    it "defaults to nil (disabled)" do
      expect(described_class.perform_timeout).to be_nil
    end

    it "runs perform normally when no timeout is configured" do
      ran = false
      job_class = Class.new(described_class) do
        define_method(:perform) { ran = true }
      end
      stub_const("NoTimeoutJob", job_class)

      job_class.new.perform_now
      expect(ran).to be(true)
    end

    it "raises PerformTimeoutError when perform exceeds the configured ceiling" do
      job_class = Class.new(described_class) do
        self.perform_timeout = 1
        self.max_attempts = 1

        def perform
          sleep 5
        end
      end
      stub_const("SlowTimeoutJob", job_class)

      notifier = instance_double(Paid::ExceptionNotifier, call: nil)
      allow(Paid::ExceptionNotifier).to receive(:new).and_return(notifier)

      job = job_class.new
      job.executions = 0
      expect { job.perform_now }.to raise_error(ApplicationJob::PerformTimeoutError)
      expect(notifier).to have_received(:call).with(
        an_instance_of(ApplicationJob::PerformTimeoutError),
        data: hash_including(subsystem: "general")
      )
    end

    it "does not interrupt work that finishes within the ceiling" do
      job_class = Class.new(described_class) do
        self.perform_timeout = 5

        def perform
          "done"
        end
      end
      stub_const("FastTimeoutJob", job_class)

      expect { job_class.new.perform_now }.not_to raise_error
    end
  end

  describe "rescue_from terminal-failure hook" do
    let(:account) { create(:account) }

    let(:failing_job_class) do
      Class.new(described_class) do
        self.notification_subsystem = "knowledge"
        self.max_attempts = 3

        def perform
          raise "job failed"
        end
      end
    end

    let(:general_job_class) do
      Class.new(described_class) do
        def perform
          raise "unhandled failure"
        end
      end
    end

    before do
      stub_const("TestFailingJob", failing_job_class)
      stub_const("TestGeneralJob", general_job_class)
    end

    it "does not fire the notifier on non-terminal failures" do
      allow(Paid::ExceptionNotifier).to receive(:new).and_call_original

      job = failing_job_class.new
      job.executions = 0

      expect { job.perform_now }.to raise_error(RuntimeError, "job failed")
      expect(Paid::ExceptionNotifier).not_to have_received(:new)
    end

    it "fires the notifier on terminal failure with correct subsystem" do
      notifier = instance_double(Paid::ExceptionNotifier)
      allow(Paid::ExceptionNotifier).to receive(:new).and_return(notifier)
      allow(notifier).to receive(:call)

      job = failing_job_class.new
      job.executions = 2

      expect { job.perform_now }.to raise_error(RuntimeError, "job failed")

      expect(notifier).to have_received(:call).with(
        an_instance_of(RuntimeError),
        data: {
          account: nil,
          subsystem: "knowledge",
          project_id: nil
        }
      )
    end

    it "re-raises the exception so the adapter marks the job failed" do
      job = failing_job_class.new
      job.executions = 2

      expect { job.perform_now }.to raise_error(RuntimeError, "job failed")
    end

    it "uses 'general' subsystem for jobs without explicit declaration" do
      notifier = instance_double(Paid::ExceptionNotifier)
      allow(Paid::ExceptionNotifier).to receive(:new).and_return(notifier)
      allow(notifier).to receive(:call)

      job = general_job_class.new
      job.executions = 0

      expect { job.perform_now }.to raise_error(RuntimeError, "unhandled failure")

      expect(notifier).to have_received(:call).with(
        an_instance_of(RuntimeError),
        data: {
          account: nil,
          subsystem: "general",
          project_id: nil
        }
      )
    end

    it "does not fire for HandleExceptionJob to prevent infinite loops" do
      notifier = instance_double(Paid::ExceptionNotifier)
      allow(Paid::ExceptionNotifier).to receive(:new).and_return(notifier)

      expect {
        HandleExceptionJob.perform_now(
          account_id: -1,
          exception_class: "RuntimeError",
          exception_message: "test",
          exception_backtrace: []
        )
      }.not_to raise_error

      expect(Paid::ExceptionNotifier).not_to have_received(:new)
    end

    context "with project_id from subclass override" do
      let(:project) { create(:project, account: account) }
      let(:notifier) { instance_double(Paid::ExceptionNotifier) }

      before do
        project_id = project.id
        project_job_class = Class.new(described_class) do
          self.notification_subsystem = "knowledge"
          self.max_attempts = 1

          define_method(:notification_project_id) { project_id }
          define_method(:perform) { |*| raise "boom" }
        end
        stub_const("TestProjectJob", project_job_class)

        allow(Paid::ExceptionNotifier).to receive(:new).and_return(notifier)
        allow(notifier).to receive(:call)
      end

      it "passes project_id from subclass to the notifier" do
        job = TestProjectJob.new(:arg)
        job.executions = 0

        expect { job.perform_now }.to raise_error(RuntimeError)

        expect(notifier).to have_received(:call).with(
          an_instance_of(RuntimeError),
          data: { account: nil, subsystem: "knowledge", project_id: project.id }
        )
      end
    end
  end

  describe "retry semantics" do
    let(:account) { create(:account) }

    it "a 3-retry job that succeeds on second attempt produces zero incidents" do
      attempt_count = 0
      succeed_on_second = Class.new(described_class) do
        self.max_attempts = 3

        define_method(:perform) do
          attempt_count += 1
          raise "fail" if attempt_count < 2
        end
      end
      stub_const("SucceedOnSecondJob", succeed_on_second)

      allow(Paid::ExceptionNotifier).to receive(:new).and_call_original

      job1 = succeed_on_second.new
      job1.executions = 0
      expect { job1.perform_now }.to raise_error(RuntimeError)

      job2 = succeed_on_second.new
      job2.executions = 1
      expect { job2.perform_now }.not_to raise_error

      expect(Paid::ExceptionNotifier).not_to have_received(:new)
    end

    it "a 3-retry job that fails terminally produces exactly one notifier call" do
      always_fail = Class.new(described_class) do
        self.notification_subsystem = "knowledge"
        self.max_attempts = 3

        def perform
          raise "always fails"
        end
      end
      stub_const("AlwaysFailJob", always_fail)

      notifier = instance_double(Paid::ExceptionNotifier)
      allow(Paid::ExceptionNotifier).to receive(:new).and_return(notifier)
      allow(notifier).to receive(:call)

      [ 0, 1, 2 ].each do |exec_count|
        job = always_fail.new
        job.executions = exec_count
        expect { job.perform_now }.to raise_error(RuntimeError)
      end

      expect(notifier).to have_received(:call).once
    end
  end

  describe "Current.account attribution" do
    it "passes Current.account to the notifier when set" do
      account = create(:account)
      job_class = Class.new(described_class) do
        self.max_attempts = 1

        def perform
          raise "fail with account context"
        end
      end
      stub_const("FailWithAccountJob", job_class)

      notifier = instance_double(Paid::ExceptionNotifier)
      allow(Paid::ExceptionNotifier).to receive(:new).and_return(notifier)
      allow(notifier).to receive(:call).and_return(nil)

      Current.account = account
      job = job_class.new
      job.executions = 0
      expect { job.perform_now }.to raise_error(RuntimeError)
    ensure
      Current.account = nil
    end
  end

  describe "tenant account resolution" do
    it "extracts project_id from QualityAlerts::CheckGateJob keyword arguments" do
      account = instance_double(Account)
      project = instance_double(Project, account: account)
      job = QualityAlerts::CheckGateJob.new(project_id: 123)

      allow(Project).to receive(:find_by).and_call_original
      allow(Project).to receive(:find_by).with(id: 123).and_return(project)

      expect(job.send(:tenant_account)).to eq(account)
    end

    it "extracts agent_run_id from AgentRunCancellationJob arguments" do
      account = instance_double(Account)
      project = instance_double(Project, account: account)
      agent_run = instance_double(AgentRun, project: project)
      job = AgentRunCancellationJob.new(123)

      allow(AgentRun).to receive(:includes).and_call_original
      allow(AgentRun).to receive(:includes).with(:project).and_return(AgentRun)
      allow(AgentRun).to receive(:find_by).with(id: 123).and_return(agent_run)

      expect(job.send(:tenant_account)).to eq(account)
    end

    it "extracts agent_run_id from CaptureAgentRunSessionSummaryJob arguments" do
      account = instance_double(Account)
      project = instance_double(Project, account: account)
      agent_run = instance_double(AgentRun, project: project)
      job = CaptureAgentRunSessionSummaryJob.new(123)

      allow(AgentRun).to receive(:includes).and_call_original
      allow(AgentRun).to receive(:includes).with(:project).and_return(AgentRun)
      allow(AgentRun).to receive(:find_by).with(id: 123).and_return(agent_run)

      expect(job.send(:tenant_account)).to eq(account)
    end

    it "extracts account_id from serialized HandleExceptionJob arguments" do
      account = instance_double(Account)
      job = HandleExceptionJob.new("account_id" => 123, "exception_class" => "RuntimeError")

      allow(Account).to receive(:find_by).with(id: 123).and_return(account)

      expect(job.send(:tenant_account)).to eq(account)
    end
  end

  describe "tenant context restoration" do
    let(:job_class) do
      Class.new(described_class) do
        def perform
        end
      end
    end

    let(:job) do
      stub_const("TenantContextRestorationJob", job_class)
      TenantContextRestorationJob
    end

    it "preserves outer system access after perform_now" do
      TenantContext.with_system_access do
        job.perform_now

        expect(current_bypass_setting).to eq("true")
        expect { create(:account) }.not_to raise_error
      end
    end
  end

  def current_bypass_setting
    ActiveRecord::Base.connection.select_value("SELECT current_setting('paid.bypass_tenant_rls', true)")
  end
end
