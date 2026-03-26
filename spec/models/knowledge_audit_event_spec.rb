# frozen_string_literal: true

require "rails_helper"

RSpec.describe KnowledgeAuditEvent do
  subject(:event) { build(:knowledge_audit_event) }

  describe "validations" do
    it { is_expected.to be_valid }

    it "requires event_type" do
      event.event_type = nil
      expect(event).not_to be_valid
      expect(event.errors[:event_type]).to include("can't be blank")
    end

    it "validates event_type inclusion" do
      event.event_type = "invalid_event"
      expect(event).not_to be_valid
      expect(event.errors[:event_type]).to include("is not included in the list")
    end

    it "validates actor_type length" do
      event.actor_type = "a" * 51
      expect(event).not_to be_valid
      expect(event.errors[:actor_type]).to include("is too long (maximum is 50 characters)")
    end

    it "validates actor_id length" do
      event.actor_id = "a" * 101
      expect(event).not_to be_valid
      expect(event.errors[:actor_id]).to include("is too long (maximum is 100 characters)")
    end
  end

  describe "associations" do
    it "belongs to project" do
      expect(described_class.reflect_on_association(:project).macro).to eq(:belongs_to)
    end
  end

  describe "scopes" do
    let(:project) { create(:project) }
    let(:other_project) { create(:project) }

    before do
      create(:knowledge_audit_event, project: project, event_type: "artifact_created")
      create(:knowledge_audit_event, project: project, event_type: "artifact_staled")
      create(:knowledge_audit_event, project: other_project, event_type: "artifact_created")
    end

    describe ".for_project" do
      it "returns events for the given project" do
        expect(described_class.for_project(project).count).to eq(2)
      end
    end

    describe ".by_event_type" do
      it "returns events of the given type" do
        expect(described_class.by_event_type("artifact_created").count).to eq(2)
      end
    end

    describe ".since" do
      it "returns events since the given time" do
        travel_to 1.hour.from_now do
          create(:knowledge_audit_event, project: project, event_type: "decision_drafted")
        end

        expect(described_class.since(30.minutes.from_now).count).to eq(1)
      end
    end

    describe ".ordered" do
      it "orders by created_at descending" do
        times = described_class.ordered.map(&:created_at)
        expect(times).to eq(times.sort.reverse)
      end
    end
  end
end
