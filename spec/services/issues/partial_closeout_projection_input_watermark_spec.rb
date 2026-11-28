# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::PartialCloseoutProjectionInputWatermark do # @spec PARTIAL-CLOSEOUT-042
  it "aggregates model-selection count and latest update in one query per project batch" do
    projects = create_list(:project, 2)
    projects.each { |project| create(:model_selection, agent_run: create(:agent_run, project:)) }

    queries = capture_queries { described_class.for_projects(projects) }
    aggregations = queries.grep(/FROM "model_selections"/)

    expect(aggregations.size).to eq(1)
    expect(aggregations.first).to match(/COUNT\(\*\).*MAX\(/i)
  end

  it "keeps empty-scope snapshots stable across repeated reads" do
    project = create(:project)

    snapshot = described_class.for(project)

    expect(described_class.for(project)).to eq(snapshot)
  end

  it "changes the fingerprint when an older input disappears without moving the maximum" do
    project = create(:project)
    older = create(:model_selection, agent_run: create(:agent_run, project:), updated_at: 2.minutes.ago)
    create(:model_selection, agent_run: create(:agent_run, project:), updated_at: 1.minute.ago)
    before = described_class.for(project)

    older.delete
    after = described_class.for(project)

    expect(after.fingerprint).not_to eq(before.fingerprint)
    expect(after.watermark).to eq(before.watermark)
  end

  it "does not change another project's snapshot when inputs change" do
    first, second = create_list(:project, 2)
    before = described_class.for_projects([ first, second ])
    create(:model_selection, agent_run: create(:agent_run, project: first))
    after = described_class.for_projects([ first, second ])

    expect(after.fetch(first.id).fingerprint).not_to eq(before.fetch(first.id).fingerprint)
    expect(after.fetch(second.id)).to eq(before.fetch(second.id))
  end
end
