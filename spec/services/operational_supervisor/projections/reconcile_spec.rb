# frozen_string_literal: true

require "rails_helper"

RSpec.describe OperationalSupervisor::Projections::Reconcile do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:incident) do
    create(:supervisor_incident, account:, status: "open", affected_project_ids: [ project.id ],
      target_ids: { "project_ids" => [ project.id ] })
  end

  around do |example|
    FeatureFlags.enable!(:operational_supervisor, project:)
    example.run
  ensure
    FeatureFlags.disable!(:operational_supervisor, project:)
  end

  it "rebuilds desired projections from durable open incidents without mutating notifications" do # @spec OPERATIONAL-SUPERVISOR-007, OPERATIONAL-SUPERVISOR-009
    stale_projection = { "incident_id" => 99_999, "fingerprint" => "stale" }

    result = described_class.call(incidents: [ incident ], existing: [ stale_projection ])

    expect(result.upsert).to contain_exactly(include("incident_id" => incident.id, "fingerprint" => incident.fingerprint))
    expect(result.remove).to eq([ stale_projection ])
    expect(Notification.count).to eq(0)
  end

  it "removes a projection when its project is disabled" do # @spec OPERATIONAL-SUPERVISOR-008
    existing_projection = { "incident_id" => incident.id, "fingerprint" => incident.fingerprint }
    FeatureFlags.disable!(:operational_supervisor, project:)

    result = described_class.call(incidents: [ incident ], existing: [ existing_projection ])

    expect(result.upsert).to be_empty
    expect(result.remove).to eq([ existing_projection ])
  end

  it "authorizes a split-target incident on the union of affected and target projects" do # @spec OPERATIONAL-SUPERVISOR-008
    affected_only_project = create(:project, account:)
    FeatureFlags.enable!(:operational_supervisor, project: affected_only_project)
    split_incident = create(:supervisor_incident, account:, status: "open",
      affected_project_ids: [ affected_only_project.id ], target_ids: { "project_ids" => [ project.id ] })

    result = described_class.call(incidents: [ split_incident ], existing: [])

    expect(result.upsert).to contain_exactly(include("incident_id" => split_incident.id))
    expect(result.remove).to be_empty
  ensure
    FeatureFlags.disable!(:operational_supervisor, project: affected_only_project)
  end

  it "removes a projection when a project only in the affected set is disabled" do # @spec OPERATIONAL-SUPERVISOR-008
    affected_only_project = create(:project, account:)
    FeatureFlags.enable!(:operational_supervisor, project: affected_only_project)
    split_incident = create(:supervisor_incident, account:, status: "open",
      affected_project_ids: [ affected_only_project.id ], target_ids: { "project_ids" => [ project.id ] })
    existing_projection = { "incident_id" => split_incident.id, "fingerprint" => split_incident.fingerprint }
    FeatureFlags.disable!(:operational_supervisor, project: affected_only_project)

    result = described_class.call(incidents: [ split_incident ], existing: [ existing_projection ])

    expect(result.upsert).to be_empty
    expect(result.remove).to eq([ existing_projection ])
  ensure
    FeatureFlags.disable!(:operational_supervisor, project: affected_only_project)
  end
end
