# frozen_string_literal: true

require "rails_helper"

RSpec.describe PerformanceBenchmarks::Benchmarks::SearchLatency do
  describe ".call" do
    it "selects the first project with an active artifact identifier" do
      create(:knowledge_artifact, identifier: "")
      searchable_artifact = create(:knowledge_artifact, identifier: "POST /api/users")

      measurement = described_class.call

      expect(measurement).not_to be_skipped
      expect(measurement.metadata).to include(
        project_id: searchable_artifact.project_id,
        query: "POST /api/users"
      )
    end

    it "ignores blank artifact identifiers when choosing the default query" do
      project = create(:project)
      collector_run = create(:collector_run, project_version: create(:project_version, project: project))
      create(:knowledge_artifact, collector_run: collector_run, project: project, identifier: "")
      create(:knowledge_artifact, collector_run: collector_run, project: project, identifier: "UsersController")

      measurement = described_class.call(project: project)

      expect(measurement).not_to be_skipped
      expect(measurement.metadata).to include(query: "UsersController")
    end
  end
end
