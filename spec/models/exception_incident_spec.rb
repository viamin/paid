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
end
