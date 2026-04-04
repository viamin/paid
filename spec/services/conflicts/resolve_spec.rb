# frozen_string_literal: true

require "rails_helper"

RSpec.describe Conflicts::Resolve do
  describe ".call" do
    it "returns resolved when no conflicts detected" do
      detection = { has_conflicts: false, conflicting_pairs: [] }

      result = described_class.call(detection_result: detection, project_id: 1, strategy: :auto_rebase)

      expect(result[:resolved]).to be true
      expect(result[:resolutions]).to be_empty
    end

    it "raises on unknown strategy" do
      expect {
        described_class.call(
          detection_result: { has_conflicts: true, conflicting_pairs: [] },
          project_id: 1, strategy: :unknown
        )
      }.to raise_error(ArgumentError, /Unknown strategy/)
    end

    it "defaults nil strategy to auto_rebase" do
      detection = { has_conflicts: false, conflicting_pairs: [] }

      result = described_class.call(detection_result: detection, project_id: 1, strategy: nil)

      expect(result[:resolved]).to be true
      expect(result[:strategy]).to eq(:auto_rebase)
    end

    it "raises a clear error for invalid strategy types" do
      expect {
        described_class.call(
          detection_result: { has_conflicts: true, conflicting_pairs: [] },
          project_id: 1, strategy: []
        )
      }.to raise_error(ArgumentError, /strategy must be a String or Symbol/)
    end

    context "with :manual strategy" do
      it "flags all pairs for manual review" do
        detection = {
          has_conflicts: true,
          conflicting_pairs: [ { runs: [ 1, 2 ], files: [ "src/app.rb" ] } ]
        }

        result = described_class.call(detection_result: detection, project_id: 1, strategy: :manual)

        expect(result[:resolved]).to be false
        expect(result[:requires_manual_review]).to be true
        expect(result[:resolutions].first[:action]).to eq(:manual)
      end
    end

    context "with :re_run strategy" do
      it "marks conflicting runs for re-execution" do
        detection = {
          has_conflicts: true,
          conflicting_pairs: [ { runs: [ 10, 20 ], files: [ "lib/service.rb" ] } ]
        }

        result = described_class.call(detection_result: detection, project_id: 1, strategy: :re_run)

        expect(result[:resolved]).to be true
        expect(result[:resolutions].first[:action]).to eq(:re_run)
        expect(result[:resolutions].first[:re_run_ids]).to eq([ 20 ])
      end
    end

    context "with :auto_rebase strategy" do
      let(:project) { create(:project) }

      it "falls back to manual when runs are not found" do
        detection = {
          has_conflicts: true,
          conflicting_pairs: [ { runs: [ -1, -2 ], files: [ "src/app.rb" ] } ]
        }

        result = described_class.call(detection_result: detection, project_id: project.id, strategy: :auto_rebase)

        expect(result[:resolved]).to be false
        expect(result[:resolutions].first[:action]).to eq(:manual)
        expect(result[:resolutions].first[:reason]).to eq("runs_not_found")
        expect(result[:resolutions].first[:message]).to include("could not be found")
      end

      it "falls back to manual when container is unavailable" do
        run_a = create(:agent_run, :completed, project: project, completed_at: 10.minutes.ago)
        run_b = create(:agent_run, :completed, project: project, completed_at: 5.minutes.ago, container_id: nil)
        detection = {
          has_conflicts: true,
          conflicting_pairs: [ { runs: [ run_a.id, run_b.id ], files: [ "src/app.rb" ] } ]
        }

        result = described_class.call(detection_result: detection, project_id: project.id, strategy: :auto_rebase)

        expect(result[:resolved]).to be false
        expect(result[:resolutions].first[:action]).to eq(:manual)
        expect(result[:resolutions].first[:reason]).to eq("rebase_failed")
        expect(result[:resolutions].first[:message]).to include("rebased cleanly")
      end

      it "resolves via rebase when rebase succeeds" do
        run_a = create(:agent_run, :completed, project: project,
          completed_at: 10.minutes.ago, branch_name: "paid/feature-a-abc")
        run_b = create(:agent_run, :completed, project: project,
          completed_at: 5.minutes.ago, container_id: "ctr-123", branch_name: "paid/feature-b-def")
        stub_successful_rebase(run_a.branch_name)
        detection = conflict_detection(run_a.id, run_b.id)

        result = described_class.call(detection_result: detection, project_id: project.id, strategy: :auto_rebase)

        expect(result[:resolved]).to be true
        expect(result[:resolutions].first[:action]).to eq(:rebased)
      end

      it "falls back to manual when rebase fails" do
        run_a = create(:agent_run, :completed, project: project,
          completed_at: 10.minutes.ago, branch_name: "paid/feature-a-abc")
        run_b = create(:agent_run, :completed, project: project,
          completed_at: 5.minutes.ago, container_id: "ctr-123", branch_name: "paid/feature-b-def")
        stub_failed_rebase(run_a.branch_name)
        detection = conflict_detection(run_a.id, run_b.id)

        result = described_class.call(detection_result: detection, project_id: project.id, strategy: :auto_rebase)

        expect(result[:resolved]).to be false
        expect(result[:resolutions].first[:action]).to eq(:manual)
      end
    end

    context "with multiple conflicting pairs" do
      it "processes each pair independently" do
        detection = {
          has_conflicts: true,
          conflicting_pairs: [
            { runs: [ 1, 2 ], files: [ "a.rb" ] },
            { runs: [ 2, 3 ], files: [ "b.rb" ] }
          ]
        }

        result = described_class.call(detection_result: detection, project_id: 1, strategy: :re_run)

        expect(result[:resolutions].size).to eq(2)
        expect(result[:resolutions]).to all(include(action: :re_run))
      end
    end
  end

  private

  def stub_successful_rebase(branch_name)
    mock_container = instance_double(Containers::Provision)
    allow(Containers::Provision).to receive(:reconnect).and_return(mock_container)
    mock_git_ops = instance_double(Containers::GitOperations)
    allow(Containers::GitOperations).to receive(:new).and_return(mock_git_ops)
    allow(mock_git_ops).to receive(:rebase_onto).with(branch_name).and_return(true)
    allow(mock_git_ops).to receive(:push_force_with_lease).and_return("abc123")
  end

  def stub_failed_rebase(branch_name)
    mock_container = instance_double(Containers::Provision)
    allow(Containers::Provision).to receive(:reconnect).and_return(mock_container)
    mock_git_ops = instance_double(Containers::GitOperations)
    allow(Containers::GitOperations).to receive(:new).and_return(mock_git_ops)
    allow(mock_git_ops).to receive(:rebase_onto).with(branch_name).and_return(false)
  end

  def conflict_detection(run_a_id, run_b_id)
    {
      has_conflicts: true,
      conflicting_pairs: [ { runs: [ run_a_id, run_b_id ], files: [ "src/app.rb" ] } ]
    }
  end
end
