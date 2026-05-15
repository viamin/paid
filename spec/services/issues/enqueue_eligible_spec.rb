# frozen_string_literal: true

require "rails_helper"

TestProject = Struct.new(:id)
TestIssue = Struct.new(:id, :github_number)
TestProvider = Struct.new(:id, :provider_key)
TestRun = Struct.new(:id, :previously_new_record?) do
  def issue = nil
end

RSpec.describe Issues::EnqueueEligible, :no_db do
  let(:project) { instance_double(TestProject, id: 7) }
  let(:issue) { instance_double(TestIssue, id: 11, github_number: 42) }
  let(:eligible_scope) { instance_double(ActiveRecord::Relation) }
  let(:issue_scope) { instance_double(ActiveRecord::Relation, exists?: true) }
  let(:blocking_runs) { instance_double(ActiveRecord::Relation) }
  let(:provider) { instance_double(TestProvider, id: 5, provider_key: "claude") }
  let(:service) { described_class.new(issue, project: project) }

  before do
    allow(Automation::Strategies::AutoPick::DefaultCandidateSource).to receive(:eligible_scope)
      .with(project)
      .and_return(eligible_scope)
    allow(eligible_scope).to receive(:where).with(id: issue.id).and_return(issue_scope)
    allow(service).to receive_messages(blocking_runs: blocking_runs, resolve_provider: provider)
  end

  it "creates a queued automatic auto-pick run for an eligible issue" do
    run = instance_double(TestRun, id: 99, previously_new_record?: true)
    allow(blocking_runs).to receive(:find_or_create_by!) do |attrs|
      expect(attrs).to eq(project: project, issue: issue)
      run
    end
    allow(Rails.logger).to receive(:info)

    result = service.call

    expect(result).to eq(run)
    expect(blocking_runs).to have_received(:find_or_create_by!).with(project: project, issue: issue)
    expect(Rails.logger).to have_received(:info).with(
      hash_including(message: "enqueue_eligible.created", issue_id: issue.id, agent_run_id: run.id)
    )
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
    existing_run = instance_double(TestRun, id: 123, previously_new_record?: false)
    allow(blocking_runs).to receive(:find_or_create_by!).and_raise(
      ActiveRecord::RecordNotUnique.new("idx_agent_runs_unique_active_issue")
    )
    allow(blocking_runs).to receive(:find_by).with(project: project, issue: issue).and_return(existing_run)
    allow(Rails.logger).to receive(:info)

    result = service.call

    expect(result).to eq(existing_run)
    expect(Rails.logger).to have_received(:info).with(
      hash_including(message: "enqueue_eligible.existing", issue_id: issue.id, agent_run_id: existing_run.id)
    )
  end

  it "re-raises unrelated unique-index errors" do
    allow(blocking_runs).to receive(:find_or_create_by!).and_raise(
      ActiveRecord::RecordNotUnique.new("some_other_index")
    )

    expect { service.call }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "returns nil and warns when no provider can be resolved" do
    allow(service).to receive(:resolve_provider).and_return(nil)
    allow(Rails.logger).to receive(:warn)

    result = service.call

    expect(result).to be_nil
    expect(Rails.logger).to have_received(:warn).with(
      hash_including(message: "enqueue_eligible.no_provider", issue_id: issue.id, project_id: project.id)
    )
  end
end
