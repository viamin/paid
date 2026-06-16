# frozen_string_literal: true

require "rails_helper"

RSpec.describe ExceptionIncident do
  describe "associations" do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to belong_to(:project).optional }
  end

  describe "validations" do
    subject { build(:exception_incident) }

    it { is_expected.to validate_presence_of(:fingerprint) }
    it { is_expected.to validate_uniqueness_of(:fingerprint).scoped_to(:account_id) }
    it { is_expected.to validate_presence_of(:exception_class) }
    it { is_expected.to validate_presence_of(:message) }
    it { is_expected.to validate_presence_of(:subsystem) }
    it { is_expected.to validate_inclusion_of(:subsystem).in_array(described_class::SUBSYSTEMS) }
    it { is_expected.to validate_presence_of(:severity) }
    it { is_expected.to validate_inclusion_of(:severity).in_array(described_class::SEVERITIES) }
    it { is_expected.to validate_presence_of(:action_taken) }
    it { is_expected.to validate_inclusion_of(:action_taken).in_array(described_class::ACTIONS) }
    it { is_expected.to validate_presence_of(:status) }
    it { is_expected.to validate_inclusion_of(:status).in_array(described_class::STATUSES) }
    it { is_expected.to validate_presence_of(:last_occurred_at) }
  end

  describe "scopes" do
    let(:account) { create(:account) }

    describe ".open_incidents" do
      it "returns only open incidents" do
        open = create(:exception_incident, account: account, status: "open")
        create(:exception_incident, :resolved, account: account)

        expect(described_class.open_incidents).to eq([ open ])
      end
    end

    describe ".for_subsystem" do
      it "filters by subsystem" do
        knowledge = create(:exception_incident, account: account, subsystem: "knowledge")
        create(:exception_incident, account: account, subsystem: "agent_runs")

        expect(described_class.for_subsystem("knowledge")).to eq([ knowledge ])
      end
    end

    describe ".filing_blocked" do
      it "returns only notified incidents off the issue-filing allowlist with project context" do
        blocked = create(:exception_incident, :with_project, account: account,
          subsystem: "github_sync", action_taken: "notified")
        create(:exception_incident, :with_project, account: account,
          subsystem: "knowledge", action_taken: "notified") # on allowlist
        create(:exception_incident, :with_project, account: account,
          subsystem: "github_sync", action_taken: "issue_filed") # off allowlist, already filed
        create(:exception_incident, :with_project, account: account,
          subsystem: "general", action_taken: "logged") # off allowlist, transient

        expect(described_class.filing_blocked).to eq([ blocked ])
      end

      it "excludes off-allowlist incidents without project context" do
        # `file_or_update_issue` returns early when there is no project, before
        # the allowlist is consulted, so such incidents were never blocked by it.
        create(:exception_incident, account: account,
          subsystem: "github_sync", action_taken: "notified")

        expect(described_class.filing_blocked).to be_empty
      end

      it "reflects live allowlist changes without caching" do
        incident = create(:exception_incident, :with_project, account: account,
          subsystem: "general", action_taken: "notified")

        expect(described_class.filing_blocked).to include(incident)

        stub_const("ExceptionHandler::Classifier::ISSUE_FILING_ALLOWLIST", %w[general])

        expect(described_class.filing_blocked).not_to include(incident)
      end
    end
  end

  describe "#record_occurrence!" do
    it "increments count and updates timestamp" do
      incident = create(:exception_incident)

      freeze_time do
        incident.record_occurrence!(new_context: { detail: "retry" })

        expect(incident.occurrence_count).to eq(2)
        expect(incident.last_occurred_at).to eq(Time.current)
        expect(incident.context).to include("latest_occurrence" => { "detail" => "retry" })
      end
    end

    it "reopens resolved incidents on recurrence" do
      incident = create(:exception_incident, :resolved, resolved_at: 1.day.ago)

      incident.record_occurrence!

      expect(incident).not_to be_resolved
      expect(incident.resolved_at).to be_nil
    end
  end

  describe "#resolved?" do
    it "returns true for resolved incidents" do
      expect(build(:exception_incident, :resolved)).to be_resolved
    end

    it "returns false for open incidents" do
      expect(build(:exception_incident)).not_to be_resolved
    end
  end

  describe "#on_allowlist?" do
    it "returns true for allowlisted subsystems" do
      expect(build(:exception_incident, subsystem: "knowledge")).to be_on_allowlist
    end

    it "returns false for off-allowlist subsystems" do
      expect(build(:exception_incident, subsystem: "general")).not_to be_on_allowlist
    end

    it "tracks live allowlist changes without caching" do
      incident = build(:exception_incident, subsystem: "general")

      expect(incident).not_to be_on_allowlist

      stub_const("ExceptionHandler::Classifier::ISSUE_FILING_ALLOWLIST", %w[general])

      expect(incident).to be_on_allowlist
    end
  end
end
