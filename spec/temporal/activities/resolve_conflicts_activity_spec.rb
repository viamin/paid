# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::ResolveConflictsActivity do
  let(:activity) { described_class.new }
  let(:detection_with_conflicts) do
    { has_conflicts: true, conflicting_pairs: [ { runs: [ 1, 2 ], files: [ "app.rb" ] } ] }
  end

  describe "#execute" do
    it "delegates to Conflicts::Resolve service" do
      resolution = build_resolution(resolved: false, requires_manual_review: true)
      allow(Conflicts::Resolve).to receive(:call)
        .with(detection_result: detection_with_conflicts, project_id: 42, strategy: "manual")
        .and_return(resolution)

      result = activity.execute({
        detection_result: detection_with_conflicts, project_id: 42, strategy: "manual"
      })

      expect(result[:resolved]).to be false
      expect(result[:requires_manual_review]).to be true
    end

    it "defaults to auto_rebase strategy" do
      detection = { has_conflicts: false, conflicting_pairs: [] }
      allow(Conflicts::Resolve).to receive(:call)
        .with(detection_result: detection, project_id: 1, strategy: nil)
        .and_return(resolved: true, strategy: :auto_rebase, resolutions: [], project_id: 1)

      result = activity.execute({ detection_result: detection, project_id: 1 })

      expect(result[:resolved]).to be true
      expect(Conflicts::Resolve).to have_received(:call).with(
        detection_result: detection, project_id: 1, strategy: nil
      )
    end

    it "defaults nil strategy to auto_rebase" do
      detection = { has_conflicts: false, conflicting_pairs: [] }
      allow(Conflicts::Resolve).to receive(:call)
        .with(detection_result: detection, project_id: 1, strategy: nil)
        .and_return(resolved: true, strategy: :auto_rebase, resolutions: [], project_id: 1)

      activity.execute({ detection_result: detection, project_id: 1, strategy: nil })

      expect(Conflicts::Resolve).to have_received(:call).with(
        detection_result: detection, project_id: 1, strategy: nil
      )
    end
  end

  private

  def build_resolution(resolved:, requires_manual_review: false)
    {
      resolved: resolved,
      strategy: :manual,
      resolutions: [ { runs: [ 1, 2 ], files: [ "app.rb" ], resolved: resolved, action: :manual } ],
      project_id: 42,
      requires_manual_review: requires_manual_review
    }
  end
end
