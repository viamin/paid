# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProjectConventions::SyncDetected do
  let(:project) { create(:project) }
  let(:first_version) { create(:project_version, project:) }
  let(:second_version) { create(:project_version, project:) }
  let(:detections) do
    [
      {
        key: "hook_manager",
        detector_key: "hooks",
        confidence: 1.0,
        value: { "type" => "husky" },
        evidence: { "paths" => [ ".husky/pre-commit" ] }
      }
    ]
  end
  let(:alternate_detection) do
    {
      key: "hook_manager",
      detector_key: "readme",
      confidence: 0.6,
      value: { "type" => "githooks" },
      evidence: { "paths" => [ "README.md" ] }
    }
  end

  it "upserts detections for the current project version" do
    older_detection = create(:project_convention_detection,
      project:,
      project_version: first_version,
      key: "hook_manager",
      detector_key: "hooks",
      value: { "type" => "lefthook" })

    described_class.call(project:, project_version: second_version, detections:)

    expect(project.project_convention_detections.where(key: "hook_manager").count).to eq(2)
    expect(older_detection.reload.value).to eq("type" => "lefthook")
    expect(
      project.project_convention_detections.find_by!(project_version: second_version, key: "hook_manager").value
    ).to eq("type" => "husky")
  end

  it "keeps distinct detector evidence for the same key within one project version" do
    described_class.call(project:, project_version: second_version, detections: [ detections.first, alternate_detection ])

    records = project.project_convention_detections.where(project_version: second_version, key: "hook_manager")

    expect(records.count).to eq(2)
    expect(records.find_by!(detector_key: "hooks").value).to eq("type" => "husky")
    expect(records.find_by!(detector_key: "readme").value).to eq("type" => "githooks")
  end

  it "removes stale detections only for the current project version" do
    stale_current = create(:project_convention_detection,
      project:,
      project_version: second_version,
      key: "ci_entrypoint")
    retained_other_version = create(:project_convention_detection,
      project:,
      project_version: first_version,
      key: "ci_entrypoint")

    described_class.call(project:, project_version: second_version, detections:)

    expect { stale_current.reload }.to raise_error(ActiveRecord::RecordNotFound)
    expect(retained_other_version.reload).to be_present
  end

  it "removes stale detections by key and detector within the current project version" do
    retained = create(:project_convention_detection,
      project:,
      project_version: second_version,
      key: "hook_manager",
      detector_key: "hooks")
    stale = create(:project_convention_detection,
      project:,
      project_version: second_version,
      key: "hook_manager",
      detector_key: "readme")

    described_class.call(project:, project_version: second_version, detections:)

    expect(retained.reload).to be_present
    expect { stale.reload }.to raise_error(ActiveRecord::RecordNotFound)
  end
end
