# frozen_string_literal: true

require "rails_helper"

RSpec.describe PrerequisiteValidation do # @spec PREREQ-EVIDENCE-002 @spec PREREQ-EVIDENCE-005
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project: project, github_state: "open") }

  describe "validations" do
    it "rejects an unknown status" do
      validation = build(:prerequisite_validation, project: project, issue: issue, status: "exploded")
      expect(validation).not_to be_valid
      expect(validation.errors[:status]).to include("is not included in the list")
    end

    it "rejects an issue from another project" do
      other_issue = create(:issue)
      validation = build(:prerequisite_validation, project: project, issue: other_issue)
      expect(validation).not_to be_valid
      expect(validation.errors[:issue]).to include("must belong to the validation's project")
    end

    it "rejects a blank analyzer command" do
      validation = build(:prerequisite_validation, project: project, issue: issue, analyzer_command: "   ")
      expect(validation).not_to be_valid
    end
  end

  describe "one active validation per issue" do
    it "admits at most one pending or running row" do
      create(:prerequisite_validation, project: project, issue: issue, status: "running")

      expect {
        create(:prerequisite_validation, project: project, issue: issue, status: "pending")
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "admits a new generation after the prior one is terminal" do
      create(:prerequisite_validation, project: project, issue: issue, status: "partial")

      expect {
        create(:prerequisite_validation, project: project, issue: issue, status: "pending")
      }.not_to raise_error
    end
  end

  describe "#mark_running!" do
    it "transitions a pending validation to running" do
      validation = create(:prerequisite_validation, project: project, issue: issue, status: "pending")

      expect(validation.mark_running!).to be(true)
      expect(validation.reload.status).to eq("running")
      expect(validation.started_at).to be_present
    end

    it "refuses to resurrect a cancelled validation" do
      validation = create(:prerequisite_validation, project: project, issue: issue, status: "cancelled", completed_at: Time.current)

      expect(validation.mark_running!).to be(false)
      expect(validation.reload.status).to eq("cancelled")
    end
  end

  describe "#complete!" do
    it "records a terminal status with evidence" do
      validation = create(:prerequisite_validation, project: project, issue: issue, status: "running")

      validation.complete!(status: "partial", result: { "checks" => {} })
      validation.reload

      expect(validation.status).to eq("partial")
      expect(validation.completed_at).to be_present
      expect(validation.result["checks"]).to eq({})
    end

    it "rejects a non-terminal status" do
      validation = create(:prerequisite_validation, project: project, issue: issue, status: "running")

      expect { validation.complete!(status: "running") }.to raise_error(ArgumentError)
    end

    it "does not overwrite a concurrent cancellation" do
      validation = create(:prerequisite_validation, project: project, issue: issue, status: "running")
      validation.update_columns(status: "cancelled")

      validation.complete!(status: "succeeded", result: {})
      validation.reload

      expect(validation.status).to eq("cancelled")
    end
  end

  describe "#stale?" do
    it "flags terminal evidence whose scope digest changed" do
      validation = create(:prerequisite_validation, project: project, issue: issue,
        status: "succeeded", scope_digest: "old")

      expect(validation.stale?("new")).to be(true)
      expect(validation.stale?("old")).to be(false)
    end

    it "never flags a pending or running validation" do
      validation = create(:prerequisite_validation, project: project, issue: issue,
        status: "running", scope_digest: "old")

      expect(validation.stale?("new")).to be(false)
    end
  end

  describe "terminal/executed status classification" do
    it "distinguishes executed outcomes from capability outcomes" do
      expect(%w[succeeded partial failed cancelled].map { |status|
        build(:prerequisite_validation, project: project, issue: issue, status: status).executed?
      }).to all(be(true))

      expect(%w[unavailable blocked].map { |status|
        build(:prerequisite_validation, project: project, issue: issue, status: status).executed?
      }).to all(be(false))
    end
  end
end
