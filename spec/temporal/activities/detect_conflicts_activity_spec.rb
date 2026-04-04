# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::DetectConflictsActivity do
  let(:activity) { described_class.new }

  describe "#execute" do
    it "delegates to Conflicts::Detect service" do
      expected_result = {
        has_conflicts: false,
        conflicting_pairs: [],
        files_by_run: [],
        total_runs_checked: 0,
        project_id: 42
      }

      allow(Conflicts::Detect).to receive(:call)
        .with(agent_run_ids: [ 1, 2 ], project_id: 42)
        .and_return(expected_result)

      result = activity.execute({ agent_run_ids: [ 1, 2 ], project_id: 42 })

      expect(result[:has_conflicts]).to be false
      expect(Conflicts::Detect).to have_received(:call)
    end

    it "returns conflict details when conflicts exist" do
      detection = {
        has_conflicts: true,
        conflicting_pairs: [ { runs: [ 1, 2 ], files: [ "app.rb" ] } ],
        files_by_run: [
          { agent_run_id: 1, files: [ "app.rb" ] },
          { agent_run_id: 2, files: [ "app.rb", "test.rb" ] }
        ],
        total_runs_checked: 2,
        project_id: 10
      }

      allow(Conflicts::Detect).to receive(:call).and_return(detection)

      result = activity.execute({ agent_run_ids: [ 1, 2 ], project_id: 10 })

      expect(result[:has_conflicts]).to be true
      expect(result[:conflicting_pairs].size).to eq(1)
    end

    it "handles empty agent_run_ids" do
      allow(Conflicts::Detect).to receive(:call)
        .with(agent_run_ids: [], project_id: nil)
        .and_return(has_conflicts: false, conflicting_pairs: [], files_by_run: [], total_runs_checked: 0, project_id: nil)

      result = activity.execute({})

      expect(result[:has_conflicts]).to be false
    end
  end
end
