# frozen_string_literal: true

RSpec.shared_examples "a configuration profile" do
  it "exposes a stable underscored name" do
    expect(described_class.name).to match(/\A[a-z0-9_]+\z/)
  end

  it "declares targets as a hash of known setting keys" do
    keys = described_class.targets.keys
    expect(keys).not_to be_empty
    expect(keys).to all(be_in(Configuration::Profiles::Settings::DESCRIPTORS.keys))
  end

  it "declares clarifying questions with ids that map to known settings" do
    ids = described_class.clarifying_questions.map { |question| question[:id].to_s }
    expect(ids).to all(be_in(Configuration::Profiles::Settings::DESCRIPTORS.keys))
  end

  it "requires a description so Registry.summaries can render every profile" do
    expect(described_class.description).to be_a(String)
  end

  it "uses registered labels for each target key" do
    described_class.targets.keys.each do |key|
      expect(Configuration::Profiles::Settings.fetch(key).label).to be_present
    end
  end

  it "derives override keys from clarifying-question ids only" do
    expected = described_class.clarifying_questions.map { |question| question[:id].to_s }
    expect(described_class.override_keys).to eq(expected)
  end

  it "returns an array of prerequisites for a fresh project" do
    project = build(:project)
    result = described_class.prerequisites_for(project, targets: described_class.targets)
    expect(result).to be_an(Array)
  end
end
