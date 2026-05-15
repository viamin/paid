# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::BulkEnqueueEligible, :no_db do
  let(:project_class) { Struct.new(:id, :auto_pick_enabled?) }
  let(:issue_class) { Struct.new(:id) }
  let(:run_class) { Struct.new(:issue, :previously_new_record?) }

  let(:project) { instance_double(project_class, id: 7, auto_pick_enabled?: auto_pick_enabled) }
  let(:scope) { instance_double(ActiveRecord::Relation) }
  let(:ordered_scope) { instance_double(ActiveRecord::Relation) }
  let(:service) { described_class.new(project: project) }
  let(:auto_pick_enabled) { true }

  before do
    allow(Automation::Strategies::AutoPick::DefaultCandidateSource).to receive(:eligible_scope)
      .with(project)
      .and_return(scope)
    allow(Automation::Strategies::AutoPick::DefaultCandidateSource).to receive(:ordered_scope)
      .with(project)
      .and_return(ordered_scope)
  end

  it "queues all eligible issues for a project" do
    first_issue = instance_double(issue_class)
    second_issue = instance_double(issue_class)
    first_run = instance_double(run_class, issue: first_issue, previously_new_record?: true)
    second_run = instance_double(run_class, issue: second_issue, previously_new_record?: true)
    allow(scope).to receive(:find_each).and_yield(first_issue).and_yield(second_issue)
    allow(Issues::EnqueueEligible).to receive(:call).with(first_issue, project: project).and_return(first_run)
    allow(Issues::EnqueueEligible).to receive(:call).with(second_issue, project: project).and_return(second_run)
    allow(Rails.logger).to receive(:info)

    result = service.call

    expect(result).to eq([ first_run, second_run ])
  end

  it "returns early when auto_pick is disabled" do
    allow(project).to receive(:auto_pick_enabled?).and_return(false)

    expect(Issues::EnqueueEligible).not_to receive(:call)

    expect(service.call).to eq([])
  end

  it "queues only eligible issues from a mixed set" do
    eligible_issue = instance_double(issue_class)
    ineligible_issue = instance_double(issue_class)
    eligible_run = instance_double(run_class, issue: eligible_issue, previously_new_record?: true)
    allow(scope).to receive(:find_each).and_yield(eligible_issue).and_yield(ineligible_issue)
    allow(Issues::EnqueueEligible).to receive(:call).with(eligible_issue, project: project).and_return(eligible_run)
    allow(Issues::EnqueueEligible).to receive(:call).with(ineligible_issue, project: project).and_return(nil)
    allow(Rails.logger).to receive(:info)

    result = service.call

    expect(result).to eq([ eligible_run ])
  end

  it "logs created, existing, and skipped counts" do
    first_issue = instance_double(issue_class)
    second_issue = instance_double(issue_class)
    third_issue = instance_double(issue_class)
    created_run = instance_double(run_class, issue: first_issue, previously_new_record?: true)
    existing_run = instance_double(run_class, issue: second_issue, previously_new_record?: false)
    allow(scope).to receive(:find_each).and_yield(first_issue).and_yield(second_issue).and_yield(third_issue)
    allow(Issues::EnqueueEligible).to receive(:call).with(first_issue, project: project).and_return(created_run)
    allow(Issues::EnqueueEligible).to receive(:call).with(second_issue, project: project).and_return(existing_run)
    allow(Issues::EnqueueEligible).to receive(:call).with(third_issue, project: project).and_return(nil)
    allow(Rails.logger).to receive(:info)

    service.call

    expect(Rails.logger).to have_received(:info).with(
      hash_including(
        message: "bulk_enqueue_eligible.completed",
        project_id: project.id,
        created_count: 1,
        existing_count: 1,
        skipped_count: 1
      )
    )
  end

  it "iterates eligible issues with find_each" do
    allow(scope).to receive(:find_each)
    allow(Rails.logger).to receive(:info)

    service.call

    expect(scope).to have_received(:find_each)
  end

  it "stops after reaching the created-run limit" do
    limited_service = described_class.new(project: project, limit: 1)
    first_issue = instance_double(issue_class)
    second_issue = instance_double(issue_class)
    third_issue = instance_double(issue_class)
    existing_run = instance_double(run_class, issue: first_issue, previously_new_record?: false)
    created_run = instance_double(run_class, issue: second_issue, previously_new_record?: true)
    limited_scope = instance_double(ActiveRecord::Relation)

    allow(scope).to receive(:find_each)
    allow(ordered_scope).to receive(:limit).with(10).and_return(limited_scope)
    allow(limited_scope).to receive(:each).and_yield(first_issue).and_yield(second_issue).and_yield(third_issue)
    allow(Issues::EnqueueEligible).to receive(:call).with(first_issue, project: project).and_return(existing_run)
    allow(Issues::EnqueueEligible).to receive(:call).with(second_issue, project: project).and_return(created_run)
    allow(Rails.logger).to receive(:info)

    result = limited_service.call

    expect(result).to eq([ existing_run, created_run ])
    expect(Automation::Strategies::AutoPick::DefaultCandidateSource).to have_received(:ordered_scope).with(project)
    expect(ordered_scope).to have_received(:limit).with(10)
    expect(scope).not_to have_received(:find_each)
    expect(Issues::EnqueueEligible).not_to have_received(:call).with(third_issue, project: project)
  end
end
