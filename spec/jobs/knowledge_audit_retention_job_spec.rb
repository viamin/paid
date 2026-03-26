# frozen_string_literal: true

require "rails_helper"

RSpec.describe KnowledgeAuditRetentionJob do
  let(:project) { create(:project) }

  it "deletes events older than 90 days" do
    old_event = travel_to(91.days.ago) do
      create(:knowledge_audit_event, project: project)
    end
    recent_event = create(:knowledge_audit_event, project: project)

    expect { described_class.new.perform }.to change(KnowledgeAuditEvent, :count).by(-1)

    expect(KnowledgeAuditEvent.exists?(old_event.id)).to be false
    expect(KnowledgeAuditEvent.exists?(recent_event.id)).to be true
  end

  it "logs the number of deleted events" do
    allow(Rails.logger).to receive(:info)

    described_class.new.perform

    expect(Rails.logger).to have_received(:info).with(
      hash_including(message: "knowledge.audit.retention", deleted_count: 0)
    )
  end
end
