# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::EnqueueEligible, :no_db do
  include ActiveJob::TestHelper

  around do |example|
    original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
    clear_performed_jobs
    example.run
  ensure
    clear_enqueued_jobs
    clear_performed_jobs
    ActiveJob::Base.queue_adapter = original_adapter
  end

  def project_class
    @project_class ||= Struct.new(:id) do
      def auto_enhance_enabled? = false
    end
  end

  def issue_class
    @issue_class ||= Struct.new(:id, :github_number)
  end

  def runner_class
    @runner_class ||= Struct.new(:id, :runner_key)
  end

  def run_class
    @run_class ||= Struct.new(:id, :previously_new_record?) do
      attr_accessor :runner, :agent_type, :status, :trigger_type, :auto_pick, :goal
    end
  end

  let(:project) { instance_double(project_class, id: 7, auto_enhance_enabled?: false) }
  let(:issue) { instance_double(issue_class, id: 11, github_number: 42) }
  let(:eligible_scope) { instance_double(ActiveRecord::Relation) }
  let(:issue_scope) { instance_double(ActiveRecord::Relation, exists?: true) }
  let(:create_pr_blocking_runs) { instance_double(ActiveRecord::Relation) }
  let(:analyze_issue_blocking_runs) { instance_double(ActiveRecord::Relation) }
  let(:runner) { instance_double(runner_class, id: 5, runner_key: "claude") }
  let(:service) { described_class.new(issue, project: project) }

  before do
    allow(Issues::AutoPickProjectGate).to receive(:call).with(project).and_return(true)
    allow(Automation::Strategies::AutoPick::DefaultCandidateSource).to receive(:eligible_scope)
      .with(project)
      .and_return(eligible_scope)
    allow(eligible_scope).to receive(:where).with(id: issue.id).and_return(issue_scope)
    allow(service).to receive(:blocking_runs).with("create_pr").and_return(create_pr_blocking_runs)
    allow(service).to receive(:blocking_runs).with("analyze_issue").and_return(analyze_issue_blocking_runs)
    allow(service).to receive(:resolve_runner).and_return(runner)
  end

  def build_run(id:, previously_new_record:)
    run_class.new(id, previously_new_record)
  end

  it "creates a queued automatic auto-pick run for an eligible issue" do
    run = build_run(id: 99, previously_new_record: true)

    allow(create_pr_blocking_runs).to receive(:find_or_create_by!) do |attrs, &block|
      expect(attrs).to eq(project: project, issue: issue, goal: "create_pr")
      block.call(run)
      run
    end
    allow(Rails.logger).to receive(:info)

    result = service.call

    expect(result).to eq(run)
    expect(create_pr_blocking_runs).to have_received(:find_or_create_by!).with(
      project: project, issue: issue, goal: "create_pr"
    )
    expect(run.runner).to eq(runner)
    expect(run.agent_type).to eq("claude_code")
    expect(run.status).to eq("queued")
    expect(run.trigger_type).to eq("automatic")
    expect(run.auto_pick).to be(true)
    expect(Rails.logger).to have_received(:info).with(
      hash_including(message: "enqueue_eligible.created", issue_id: issue.id, agent_run_id: run.id)
    )
  end

  it "resolves the provider for analyze_issue when auto_enhance is enabled" do
    allow(project).to receive(:auto_enhance_enabled?).and_return(true)
    allow(service).to receive(:resolve_runner).with("analyze_issue").and_return(runner)
    allow(analyze_issue_blocking_runs).to receive(:find_or_create_by!).and_return(
      instance_double(run_class, id: 99, previously_new_record?: true)
    )
    allow(Rails.logger).to receive(:info)

    service.call

    expect(service).to have_received(:resolve_runner).with("analyze_issue")
  end

  it "returns nil when DefaultCandidateSource excludes the issue for paid_state reasons" do
    allow(issue_scope).to receive_messages(exists?: false)
    allow(Rails.logger).to receive(:info)

    result = service.call

    expect(result).to be_nil
    expect(Rails.logger).to have_received(:info).with(
      hash_including(message: "enqueue_eligible.ineligible", issue_id: issue.id)
    )
  end

  it "returns nil when DefaultCandidateSource excludes the issue for labels, dependencies, or active runs" do
    allow(issue_scope).to receive_messages(exists?: false)

    aggregate_failures do
      3.times { expect(service.call).to be_nil }
    end
  end

  it "returns the existing run when a unique-index race occurs" do
    existing_run = instance_double(run_class, id: 123, previously_new_record?: false)
    allow(create_pr_blocking_runs).to receive(:find_or_create_by!).and_raise(
      ActiveRecord::RecordNotUnique.new("idx_agent_runs_unique_active_issue")
    )
    allow(create_pr_blocking_runs).to receive(:find_by)
      .with(project: project, issue: issue, goal: "create_pr")
      .and_return(existing_run)
    allow(Rails.logger).to receive(:info)

    result = service.call

    expect(result).to eq(existing_run)
    expect(Rails.logger).to have_received(:info).with(
      hash_including(message: "enqueue_eligible.existing", issue_id: issue.id, agent_run_id: existing_run.id)
    )
  end

  it "re-raises unrelated unique-index errors" do
    allow(create_pr_blocking_runs).to receive(:find_or_create_by!).and_raise(
      ActiveRecord::RecordNotUnique.new("some_other_index")
    )

    expect { service.call }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "returns nil and warns when no runner can be resolved" do
    allow(service).to receive(:resolve_runner).with("create_pr").and_return(nil)
    allow(Rails.logger).to receive(:warn)

    freeze_time do
      expect {
        result = service.call
        expect(result).to be_nil
      }.to have_enqueued_job(Issues::ReenqueueEligibleJob).with(issue.id, no_runner_retry_count: 1).at(30.seconds.from_now)
    end

    expect(Rails.logger).to have_received(:warn).with(
      hash_including(
        message: "enqueue_eligible.no_runner",
        issue_id: issue.id,
        project_id: project.id,
        no_runner_retry_count: 0,
        no_runner_retry_scheduled: true,
        next_no_runner_retry_count: 1,
        wait_seconds: 30,
        retries_exhausted: false
      )
    )
  end

  it "does not schedule another retry after the no-runner retry cap" do
    capped_service = described_class.new(
      issue,
      project: project,
      no_runner_retry_count: Issues::ReenqueueEligibleJob::MAX_NO_RUNNER_RETRIES
    )
    allow(capped_service).to receive(:resolve_runner).with("create_pr").and_return(nil)
    allow(Rails.logger).to receive(:warn)

    expect {
      expect(capped_service.call).to be_nil
    }.not_to have_enqueued_job(Issues::ReenqueueEligibleJob)

    expect(Rails.logger).to have_received(:warn).with(
      hash_including(
        message: "enqueue_eligible.no_runner",
        issue_id: issue.id,
        no_runner_retry_count: Issues::ReenqueueEligibleJob::MAX_NO_RUNNER_RETRIES,
        no_runner_retry_scheduled: false,
        retries_exhausted: true
      )
    )
  end

  it "returns nil when the project-level auto-pick gate defers seeding" do
    allow(Issues::AutoPickProjectGate).to receive(:call).with(project).and_return(false)
    allow(Rails.logger).to receive(:info)

    result = service.call

    expect(result).to be_nil
    expect(Rails.logger).to have_received(:info).with(
      hash_including(message: "enqueue_eligible.project_deferred", issue_id: issue.id, project_id: project.id)
    )
    expect(eligible_scope).not_to have_received(:where)
  end

  it "scopes queued-run lookup by analyze_issue goal when auto_enhance is enabled" do
    run = build_run(id: 99, previously_new_record: true)

    allow(project).to receive(:auto_enhance_enabled?).and_return(true)
    allow(analyze_issue_blocking_runs).to receive(:find_or_create_by!) do |attrs, &block|
      expect(attrs).to eq(project: project, issue: issue, goal: "analyze_issue")
      block.call(run)
      run
    end
    allow(Rails.logger).to receive(:info)

    service.call

    expect(analyze_issue_blocking_runs).to have_received(:find_or_create_by!).with(
      project: project, issue: issue, goal: "analyze_issue"
    )
  end

  it "looks up the existing blocking run after a unique-index race" do
    existing_run = instance_double(run_class, id: 123, previously_new_record?: false)

    allow(project).to receive(:auto_enhance_enabled?).and_return(true)
    allow(analyze_issue_blocking_runs).to receive(:find_or_create_by!).and_raise(
      ActiveRecord::RecordNotUnique.new("idx_agent_runs_unique_active_issue")
    )
    allow(analyze_issue_blocking_runs).to receive(:find_by)
      .with(project: project, issue: issue, goal: "analyze_issue")
      .and_return(existing_run)

    result = service.call

    expect(result).to eq(existing_run)
  end

  it "does not return a blocking run created for a different goal after a unique-index race" do
    allow(project).to receive(:auto_enhance_enabled?).and_return(true)
    allow(analyze_issue_blocking_runs).to receive(:find_or_create_by!).and_raise(
      ActiveRecord::RecordNotUnique.new("idx_agent_runs_unique_active_issue")
    )
    allow(analyze_issue_blocking_runs).to receive(:find_by)
      .with(project: project, issue: issue, goal: "analyze_issue")
      .and_return(nil)

    result = service.call

    expect(result).to be_nil
  end
end
