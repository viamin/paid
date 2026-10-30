# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::BulkEnqueueEligible do
  let(:project_class) { Struct.new(:id, :auto_pick_enabled?) }
  let(:issue_class) { Struct.new(:id) }
  let(:run_class) { Struct.new(:issue, :previously_new_record?) }

  let(:project) { instance_double(project_class, id: 7, auto_pick_enabled?: auto_pick_enabled) }
  let(:scope) { instance_double(ActiveRecord::Relation) }
  let(:ordered_scope) { instance_double(ActiveRecord::Relation) }
  let(:service) { described_class.new(project: project) }
  let(:auto_pick_enabled) { true }

  before do
    allow(service).to receive(:release_confidence_delivery_holds)
    allow(service).to receive(:reconcile_agent_planning_holds)
    allow(Issues::AutoPickProjectGate).to receive(:call).with(project).and_return(true)
    allow(Automation::Strategies::AutoPick::DefaultCandidateSource).to receive(:eligible_scope)
      .with(project)
      .and_return(scope)
    allow(Automation::Strategies::AutoPick::DefaultCandidateSource).to receive(:ordered_scope)
      .with(project)
      .and_return(ordered_scope)
  end

  def stub_enqueue(issue, result)
    allow(Issues::EnqueueEligible).to receive(:call)
      .with(issue, project: project, skip_project_gate: true)
      .and_return(result)
  end

  it "queues all eligible issues for a project" do
    first_issue = instance_double(issue_class)
    second_issue = instance_double(issue_class)
    first_run = instance_double(run_class, issue: first_issue, previously_new_record?: true)
    second_run = instance_double(run_class, issue: second_issue, previously_new_record?: true)
    allow(scope).to receive(:find_each).and_yield(first_issue).and_yield(second_issue)
    stub_enqueue(first_issue, first_run)
    stub_enqueue(second_issue, second_run)
    allow(Rails.logger).to receive(:info)

    result = service.call

    expect(result).to eq([ first_run, second_run ])
    expect(service).to have_received(:release_confidence_delivery_holds)
  end

  it "returns early when auto_pick is disabled" do
    allow(Issues::AutoPickProjectGate).to receive(:call).with(project).and_return(false)

    expect(Issues::EnqueueEligible).not_to receive(:call)

    expect(service.call).to eq([])
  end

  it "queues only eligible issues from a mixed set" do
    eligible_issue = instance_double(issue_class)
    ineligible_issue = instance_double(issue_class)
    eligible_run = instance_double(run_class, issue: eligible_issue, previously_new_record?: true)
    allow(scope).to receive(:find_each).and_yield(eligible_issue).and_yield(ineligible_issue)
    stub_enqueue(eligible_issue, eligible_run)
    stub_enqueue(ineligible_issue, nil)
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
    stub_enqueue(first_issue, created_run)
    stub_enqueue(second_issue, existing_run)
    stub_enqueue(third_issue, nil)
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

    allow(scope).to receive(:find_each)
    allow(ordered_scope).to receive(:each).and_yield(first_issue).and_yield(second_issue).and_yield(third_issue)
    stub_enqueue(first_issue, existing_run)
    stub_enqueue(second_issue, created_run)
    allow(Rails.logger).to receive(:info)

    result = limited_service.call

    expect(result).to eq([ existing_run, created_run ])
    expect(Automation::Strategies::AutoPick::DefaultCandidateSource).to have_received(:ordered_scope).with(project)
    expect(ordered_scope).to have_received(:each)
    expect(scope).not_to have_received(:find_each)
    expect(Issues::EnqueueEligible).not_to have_received(:call)
      .with(third_issue, project: project, skip_project_gate: true)
  end

  it "keeps scanning ordered issues until it creates the requested number of runs" do
    limited_service = described_class.new(project: project, limit: 1)
    first_issue = instance_double(issue_class)
    second_issue = instance_double(issue_class)
    third_issue = instance_double(issue_class)
    existing_run = instance_double(run_class, issue: first_issue, previously_new_record?: false)
    created_run = instance_double(run_class, issue: third_issue, previously_new_record?: true)

    allow(ordered_scope).to receive(:each).and_yield(first_issue).and_yield(second_issue).and_yield(third_issue)
    stub_enqueue(first_issue, existing_run)
    stub_enqueue(second_issue, nil)
    stub_enqueue(third_issue, created_run)
    allow(Rails.logger).to receive(:info)

    result = limited_service.call

    expect(result).to eq([ existing_run, created_run ])
    expect(Issues::EnqueueEligible).to have_received(:call)
      .with(third_issue, project: project, skip_project_gate: true)
  end

  describe "#release_confidence_delivery_holds" do
    let(:project) { create(:project) }

    before do
      allow(service).to receive(:release_confidence_delivery_holds).and_call_original
    end

    it "reconciles each held confidence-delivery issue once, however many unreleased links serve it" do
      held_issue = create(:issue, project: project, labels: [])
      feature = create(:feature_intent, :confidence_driven, project: project)
      create(:feature_intent_issue, feature_intent: feature, issue: held_issue, release_state: "held")
      second_feature = create(:feature_intent, :confidence_driven, project: project)
      create(:feature_intent_issue, feature_intent: second_feature, issue: held_issue, release_state: "pending")
      allow(FeatureIntents::ReleaseIssue).to receive(:call)

      service.send(:release_confidence_delivery_holds)

      expect(FeatureIntents::ReleaseIssue).to have_received(:call).once.with(issue: held_issue)
    end

    # @spec CONFIDENCE-DELIVERY-006
    it "also reconciles fully released issues whose planning label was re-added externally" do
      reheld_issue = create(:issue, project: project, labels: [ "planning" ])
      feature = create(:feature_intent, :confidence_driven, project: project)
      create(:feature_intent_issue, feature_intent: feature, issue: reheld_issue, release_state: "released")
      allow(FeatureIntents::ReleaseIssue).to receive(:call)

      service.send(:release_confidence_delivery_holds)

      expect(FeatureIntents::ReleaseIssue).to have_received(:call).once.with(issue: reheld_issue)
    end

    it "reconciles an issue only once when it is both unreleased and carries a stale planning label" do
      held_issue = create(:issue, project: project, labels: [ "planning" ])
      feature = create(:feature_intent, :confidence_driven, project: project)
      create(:feature_intent_issue, feature_intent: feature, issue: held_issue, release_state: "held")
      allow(FeatureIntents::ReleaseIssue).to receive(:call)

      service.send(:release_confidence_delivery_holds)

      expect(FeatureIntents::ReleaseIssue).to have_received(:call).once.with(issue: held_issue)
    end

    it "selects only this project's unreleased links and released planning-label projections" do
      held_issue = create(:issue, project: project, labels: [])
      held_feature = create(:feature_intent, :confidence_driven, project: project)
      create(:feature_intent_issue, feature_intent: held_feature, issue: held_issue, release_state: "held")
      reheld_issue = create(:issue, project: project, labels: [ "planning" ])
      released_feature = create(:feature_intent, :confidence_driven, project: project)
      create(:feature_intent_issue, feature_intent: released_feature, issue: reheld_issue, release_state: "released")
      unlabelled_issue = create(:issue, project: project, labels: [])
      create(:feature_intent_issue, feature_intent: released_feature, issue: unlabelled_issue, release_state: "released")
      other_project = create(:project)
      other_issue = create(:issue, project: other_project, labels: [ "planning" ])
      other_feature = create(:feature_intent, :confidence_driven, project: other_project)
      create(:feature_intent_issue, feature_intent: other_feature, issue: other_issue, release_state: "held")
      allow(FeatureIntents::ReleaseIssue).to receive(:call)

      service.send(:release_confidence_delivery_holds)

      expect(FeatureIntents::ReleaseIssue).to have_received(:call).twice
      expect(FeatureIntents::ReleaseIssue).to have_received(:call).with(issue: held_issue)
      expect(FeatureIntents::ReleaseIssue).to have_received(:call).with(issue: reheld_issue)
    end
  end

  describe "#reconcile_agent_planning_holds" do
    let(:project) { create(:project) }
    let(:service) { described_class.new(project: project) }

    before do
      allow(service).to receive(:reconcile_agent_planning_holds).and_call_original
    end

    # @spec CONFIDENCE-DELIVERY-018
    it "retries a failed Paid-owned planning-hold reconciliation without crossing projects" do
      issue = create(:issue, project: project, labels: [ "planning" ])
      failed_hold = create_agent_planning_hold(project:, issue:, status: "reconciliation_failed")
      other_project = create(:project)
      other_issue = create(:issue, project: other_project, labels: [ "planning" ])
      other_hold = create_agent_planning_hold(project: other_project, issue: other_issue, status: "held")
      allow(AgentPlanningHolds::Reconcile).to receive(:call)

      service.send(:reconcile_agent_planning_holds)

      expect(AgentPlanningHolds::Reconcile).to have_received(:call).with(hold: failed_hold)
      expect(AgentPlanningHolds::Reconcile).not_to have_received(:call).with(hold: other_hold)
    end

    def create_agent_planning_hold(project:, issue:, status:)
      AgentPlanningHold.create!(
        account: project.account,
        project: project,
        issue: issue,
        remote_issue_number: issue.github_number,
        label: "planning",
        status: status,
        task_kind: "implementation",
        reason: "The prerequisite issue must close.",
        release_condition: { "kind" => "issue_closed", "issue_number" => issue.github_number },
        evidence: { "scope_revision" => "rdr-063@draft" }
      )
    end
  end
end
