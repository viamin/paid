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

  it "deduplicates target sets regardless of order or repeated IDs" do # @spec OPERATIONAL-SUPERVISOR-007
    second_project = create(:project, account:)
    snapshot.update!(included_project_ids: [ project.id, second_project.id ])
    targets = { "project_ids" => [ project.id, second_project.id ] }

    first = described_class.call(account:, snapshot:, **attributes.merge(affected_project_ids: targets.fetch("project_ids"), target_ids: targets))
    second = described_class.call(account:, snapshot:, **attributes.merge(affected_project_ids: [ second_project.id, project.id, project.id ], target_ids: { "project_ids" => [ second_project.id, project.id, project.id ] }))

    expect(first.incident).to eq(second.incident)
    expect(second.incident.occurrence_count).to eq(2)
    expect(second.incident.target_ids).to eq({ "project_ids" => targets.fetch("project_ids").sort })
  end

  it "recovers from a concurrent creation race and still appends the observed audit" do # @spec OPERATIONAL-SUPERVISOR-007
    winner = create(:supervisor_incident, account:, fingerprint: deduplication_fingerprint,
      category: "queue_starvation", target_ids: { "project_ids" => [ project.id ] })
    simulate_deduplication_race!

    result = described_class.call(account:, snapshot:, **attributes)

    expect(result).not_to be_failure
    expect(result.incident).to eq(winner)
    expect(winner.reload.occurrence_count).to eq(2)
    expect(winner.supervisor_incident_audits.pluck(:action)).to eq(%w[observed])
  end

  it "fails closed when snapshot membership or tenant ownership is invalid" do # @spec OPERATIONAL-SUPERVISOR-004, OPERATIONAL-SUPERVISOR-006
    other_project = create(:project)

    result = described_class.call(account:, snapshot:, **attributes.merge(affected_project_ids: [ other_project.id ]))

    expect(result).to be_failure
    expect(SupervisorIncident.count).to eq(0)
  end

  it "fails closed when stored target IDs are not snapshot members" do # @spec OPERATIONAL-SUPERVISOR-004, OPERATIONAL-SUPERVISOR-006
    other_project = create(:project, account:)

    result = described_class.call(account:, snapshot:, **attributes.merge(affected_project_ids: [], target_ids: { "project_ids" => [ other_project.id ] }))

    expect(result).to be_failure
    expect(SupervisorIncident.count).to eq(0)
  end

  private

  def deduplication_fingerprint
    Digest::SHA256.hexdigest({ account_id: account.id, category: attributes.fetch(:category), target_ids: attributes.fetch(:target_ids) }.to_json)
  end

  # Reproduces the concurrent-creation race window: the first locked lookup
  # happens before the winning transaction commits (so it misses), and the
  # insert then loses the unique-index race. The locked recovery path runs
  # against the real persisted records.
  def simulate_deduplication_race!
    locked_lookups = 0
    allow(account.supervisor_incidents).to receive(:lock).and_wrap_original do |original|
      locked_lookups += 1
      locked_lookups == 1 ? SupervisorIncident.none : original.call
    end
    allow(account.supervisor_incidents).to receive(:create!) do
      raise ActiveRecord::RecordNotUnique, "index_supervisor_incidents_on_account_and_fingerprint"
    end
  end
end
