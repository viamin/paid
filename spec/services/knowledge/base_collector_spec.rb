# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::BaseCollector do
  subject(:collector) do
    described_class.new(
      project: project,
      project_version: project_version,
      collector_run: collector_run
    )
  end

  let(:project) { build(:project) }
  let(:project_version) { build(:project_version, project: project) }
  let(:collector_run) { build(:collector_run, project_version: project_version) }


  describe "#collect" do
    it "raises NotImplementedError" do
      expect { collector.collect }.to raise_error(NotImplementedError)
    end
  end

  describe "#collector_type" do
    it "raises NotImplementedError" do
      expect { collector.collector_type }.to raise_error(NotImplementedError)
    end
  end

  describe "#tool_version" do
    it "returns nil by default" do
      expect(collector.tool_version).to be_nil
    end
  end
end
