# frozen_string_literal: true

require "rails_helper"

# @spec TRUSTED-MEASUREMENTS-003
RSpec.describe TrustedMeasurements::RunCheckJob do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, :closed, project:, github_number: 4812) }
  let(:job_arguments) do
    {
      check_key: "agent_planning_hold_reconciliation_closed_count",
      external_issue_number: issue.github_number,
      criterion_key: "closed_planning_hold_notifications_cleared",
      expected_deployed_revision: "rev-1"
    }
  end

  around do |example|
    previous = ENV["PAID_DEPLOYED_REVISION"]
    ENV["PAID_DEPLOYED_REVISION"] = "rev-1"
    example.run
  ensure
    ENV["PAID_DEPLOYED_REVISION"] = previous
  end

  it "runs the named check for the project and persists the attempt" do
    described_class.new.perform(
      project.id, check_key: "agent_planning_hold_reconciliation_closed_count",
      external_issue_number: issue.github_number, criterion_key: "closed_planning_hold_notifications_cleared",
      expected_deployed_revision: "rev-1"
    )

    attempt = TrustedMeasurementAttempt.last
    expect(attempt).to have_attributes(project_id: project.id, status: "succeeded", deployed_revision: "rev-1")
  end

  it "establishes tenant context for the project's own account while running" do
    observed_account_id = nil
    allow(TrustedMeasurements::RunCheck).to receive(:call).and_wrap_original do |method, **kwargs|
      observed_account_id = Current.account&.id
      method.call(**kwargs)
    end

    described_class.perform_now(
      project.id, check_key: "agent_planning_hold_reconciliation_closed_count",
      external_issue_number: issue.github_number, criterion_key: "closed_planning_hold_notifications_cleared",
      expected_deployed_revision: "rev-1"
    )

    expect(observed_account_id).to eq(project.account_id)
  end

  it "retries a transient statement failure while attempts remain" do
    notifier = instance_double(Paid::ExceptionNotifier, call: nil)
    allow(Paid::ExceptionNotifier).to receive(:new).and_return(notifier)
    allow(TrustedMeasurements::RunCheck).to receive(:call)
      .and_raise(ActiveRecord::StatementInvalid, "query timed out")
    job = described_class.new(project.id, **job_arguments)
    job.exception_executions = { "[ActiveRecord::ConnectionNotEstablished, ActiveRecord::StatementInvalid]" => 0 }

    expect { job.perform_now }.not_to raise_error
    expect(notifier).not_to have_received(:call)
  end

  it "raises a statement failure after exhausting retries" do
    notifier = instance_double(Paid::ExceptionNotifier, call: nil)
    allow(Paid::ExceptionNotifier).to receive(:new).and_return(notifier)
    allow(TrustedMeasurements::RunCheck).to receive(:call)
      .and_raise(ActiveRecord::StatementInvalid, "query timed out")
    job = described_class.new(project.id, **job_arguments)
    job.exception_executions = { "[ActiveRecord::ConnectionNotEstablished, ActiveRecord::StatementInvalid]" => 4 }

    expect { job.perform_now }.to raise_error(ActiveRecord::StatementInvalid)
    expect(notifier).to have_received(:call).with(
      an_instance_of(ActiveRecord::StatementInvalid),
      data: hash_including(subsystem: "trusted_measurements", project_id: project.id)
    )
  end
end
