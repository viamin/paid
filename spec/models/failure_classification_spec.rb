# frozen_string_literal: true

require "rails_helper"

RSpec.describe FailureClassification do
  describe "validations" do
    it { is_expected.to belong_to(:project) }
    it { is_expected.to belong_to(:agent_run) }

    it { is_expected.to validate_presence_of(:failure_category) }
    it { is_expected.to validate_inclusion_of(:failure_category).in_array(described_class::FAILURE_CATEGORIES) }

    it { is_expected.to validate_presence_of(:chosen_action) }
    it { is_expected.to validate_inclusion_of(:chosen_action).in_array(described_class::ACTIONS) }

    it { is_expected.to validate_presence_of(:action_status) }
    it { is_expected.to validate_inclusion_of(:action_status).in_array(described_class::ACTION_STATUSES) }

    it "defaults project from the agent run" do
      classification = build(:failure_classification, project: nil)

      classification.validate

      expect(classification.project).to eq(classification.agent_run.project)
    end

    it "rejects projects that do not match the agent run" do
      agent_run = create(:agent_run)
      classification = build(:failure_classification, project: create(:project), agent_run: agent_run)

      expect(classification).not_to be_valid
      expect(classification.errors[:project]).to include("must match the agent run's project")
    end
  end

  describe "#execute!" do
    it "transitions to executing with a timestamp" do
      classification = create(:failure_classification)

      freeze_time do
        classification.execute!

        expect(classification.action_status).to eq("executing")
        expect(classification.executed_at).to eq(Time.current)
      end
    end
  end

  describe "#complete!" do
    it "transitions to completed with result data" do
      classification = create(:failure_classification, :executing)

      freeze_time do
        classification.complete!(recovered: true, retries: 1)

        expect(classification.action_status).to eq("completed")
        expect(classification.completed_at).to eq(Time.current)
        expect(classification.action_result).to include("recovered" => true, "retries" => 1)
      end
    end
  end

  describe "#skip!" do
    it "transitions to skipped with optional reason" do
      classification = create(:failure_classification)

      classification.skip!("policy disabled")

      expect(classification.action_status).to eq("skipped")
      expect(classification.action_result).to include("skip_reason" => "policy disabled")
    end
  end

  describe "scopes" do
    it ".by_category filters by failure category" do
      timeout = create(:failure_classification, :timeout)
      create(:failure_classification, :auth_failure)

      expect(described_class.by_category("timeout")).to contain_exactly(timeout)
    end

    it ".for_workflow filters by parent_workflow_id" do
      with_wf = create(:failure_classification, :with_workflow, parent_workflow_id: "wf-123")
      create(:failure_classification)

      expect(described_class.for_workflow("wf-123")).to contain_exactly(with_wf)
    end

    it ".completed returns only completed classifications" do
      completed = create(:failure_classification, :completed)
      create(:failure_classification)

      expect(described_class.completed).to contain_exactly(completed)
    end
  end
end
