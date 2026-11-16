# frozen_string_literal: true

require "rails_helper"

RSpec.describe OperationalSupervisor::PersistIncident do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:snapshot) { create(:supervisor_snapshot, account:, included_project_ids: [ project.id ]) }
  let(:attributes) do
    {
      category: "queue_starvation", severity: "urgent", affected_project_ids: [ project.id ],
      target_ids: { "project_ids" => [ project.id ] }, evidence: { "metric_names" => [ "queue_starvation" ] },
      model_identifier: "model-v1", prompt_identifier: "prompt-v1", policy_identifier: "policy-v1"
    }
  end

  it "is idempotent, deduplicated, and appends an audit occurrence" do # @spec OPERATIONAL-SUPERVISOR-007
    first = described_class.call(account:, snapshot:, **attributes)
    second = described_class.call(account:, snapshot:, **attributes)

    expect(first.incident).to eq(second.incident)
    expect(second.incident.occurrence_count).to eq(2)
    expect(second.incident.supervisor_incident_audits.pluck(:action)).to eq(%w[opened observed])
  end

  it "fails closed when snapshot membership or tenant ownership is invalid" do # @spec OPERATIONAL-SUPERVISOR-004, OPERATIONAL-SUPERVISOR-006
    other_project = create(:project)

    result = described_class.call(account:, snapshot:, **attributes.merge(affected_project_ids: [ other_project.id ]))

    expect(result).to be_failure
    expect(SupervisorIncident.count).to eq(0)
  end
end
