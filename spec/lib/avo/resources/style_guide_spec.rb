# frozen_string_literal: true

require "rails_helper"

RSpec.describe Avo::Resources::StyleGuide, :no_db do
  it "registers the expected style guide fields" do
    resource = described_class.new(view: :show).detect_fields

    expect(described_class.model_class).to eq(StyleGuide)
    expect(described_class.authorization_policy).to eq(OperatorConsole::StyleGuidePolicy)
    expect(resource.get_field_definitions.map(&:id)).to include(
      :name,
      :account_id,
      :project_id,
      :language,
      :active,
      :compression_state,
      :compressed_at
    )
  end

  it "attaches the recompress action to the resource" do
    file, line = described_class.instance_method(:actions).source_location
    source = File.readlines(file)[(line - 1), 4].join

    expect(source).to include("action Avo::Actions::RecompressStyleGuides")
  end
end
