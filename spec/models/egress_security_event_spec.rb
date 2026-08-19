# frozen_string_literal: true

require "rails_helper"

RSpec.describe EgressSecurityEvent do
  describe "associations" do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to belong_to(:project).optional }
    it { is_expected.to belong_to(:agent_run).optional }
    it { is_expected.to belong_to(:egress_allowlist_entry).optional }
  end

  describe "validations" do
    let(:account) { create(:account) }

    it "requires event_kind, severity, source_layer, and occurred_at" do
      event = build(:egress_security_event, account: account, event_kind: nil, severity: nil, source_layer: nil, occurred_at: nil)
      expect(event).not_to be_valid
      expect(event.errors[:event_kind]).to be_present
      expect(event.errors[:severity]).to be_present
      expect(event.errors[:source_layer]).to be_present
      expect(event.errors[:occurred_at]).to be_present
    end

    it "rejects unknown event_kinds" do
      event = build(:egress_security_event, account: account, event_kind: "rogue")
      expect(event).not_to be_valid
      expect(event.errors[:event_kind]).to be_present
    end

    it "rejects unknown severities" do
      event = build(:egress_security_event, account: account, severity: "extreme")
      expect(event).not_to be_valid
      expect(event.errors[:severity]).to be_present
    end

    it "rejects unknown source layers" do
      event = build(:egress_security_event, account: account, source_layer: "router")
      expect(event).not_to be_valid
      expect(event.errors[:source_layer]).to be_present
    end

    it "rejects destination ports outside the valid range" do
      event = build(:egress_security_event, account: account, destination_port: 0)
      expect(event).not_to be_valid
      expect(event.errors[:destination_port]).to be_present
    end

    it "rejects events that cross the tenant boundary" do
      other_project = create(:project)
      event = build(:egress_security_event, account: account, project: other_project)
      expect(event).not_to be_valid
      expect(event.errors[:project].join).to include('must belong')
    end

    it "rejects agent runs from a different project than the recorded project" do
      project = create(:project, account: account)
      other_project = create(:project, account: account)
      run = create(:agent_run, project: other_project)
      event = build(:egress_security_event, account: account, project: project, agent_run: run)
      expect(event).not_to be_valid
      expect(event.errors[:agent_run].join).to include('must belong')
    end
  end

  describe "scopes" do
    let(:account) { create(:account) }
    let(:project) { create(:project, account: account) }
    let(:agent_run) { create(:agent_run, project: project) }

    it "filters denied events" do
      denied = create(:egress_security_event, account: account, agent_run: agent_run)
      redacted = create(:egress_security_event, :redacted_extraction, account: account, agent_run: agent_run)
      expect(described_class.denied).to include(denied)
      expect(described_class.denied).not_to include(redacted)
    end

    it "filters redacted events" do
      denied = create(:egress_security_event, account: account, agent_run: agent_run)
      redacted = create(:egress_security_event, :redacted_extraction, account: account, agent_run: agent_run)
      expect(described_class.redacted).to include(redacted)
      expect(described_class.redacted).not_to include(denied)
    end

    it "returns events scoped to a run" do
      a = create(:egress_security_event, account: account, agent_run: agent_run)
      _b = create(:egress_security_event, account: account, agent_run: agent_run)
      c = create(:egress_security_event, account: account)
      expect(described_class.for_run(agent_run)).to contain_exactly(a, _b)
      expect(described_class.for_run(agent_run)).not_to include(c)
    end
  end

  describe "#to_audit_line" do
    let(:account) { create(:account) }

    it "returns a compact audit hash without nil values" do
      event = create(:egress_security_event, account: account, redacted_evidence: nil)
      line = event.to_audit_line
      expect(line[:event_kind]).to eq("denied_egress")
      expect(line).not_to have_key(:redacted_evidence)
    end

    it "includes redacted evidence when present" do
      event = create(:egress_security_event, account: account, redacted_evidence: "fp:abc…")
      expect(event.to_audit_line[:redacted_evidence]).to eq("fp:abc…")
    end
  end
end
