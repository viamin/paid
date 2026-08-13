# frozen_string_literal: true

require "rails_helper"

RSpec.describe ContainerMetric do
  subject(:metric) { build(:container_metric) }

  describe "validations" do
    it { is_expected.to belong_to(:agent_run) }
    it { is_expected.to validate_presence_of(:container_id) }
    it { is_expected.to validate_length_of(:container_id).is_at_most(128) }
    it { is_expected.to validate_presence_of(:recorded_at) }
    it { is_expected.to validate_numericality_of(:cpu_percent).is_greater_than_or_equal_to(0.0) }
    it { is_expected.to validate_numericality_of(:memory_bytes).only_integer.is_greater_than_or_equal_to(0) }
    it { is_expected.to validate_numericality_of(:memory_limit_bytes).only_integer.is_greater_than_or_equal_to(0) }
    it { is_expected.to validate_numericality_of(:memory_percent).is_greater_than_or_equal_to(0.0) }
    it { is_expected.to validate_numericality_of(:pids_count).only_integer.is_greater_than_or_equal_to(0).allow_nil }
  end

  describe "#memory_mb" do
    it "converts bytes to megabytes" do
      record = build(:container_metric, memory_bytes: 1_073_741_824)
      expect(record.memory_mb).to eq(1024.0)
    end
  end

  describe "#memory_limit_mb" do
    it "converts limit bytes to megabytes" do
      record = build(:container_metric, memory_limit_bytes: 4_294_967_296)
      expect(record.memory_limit_mb).to eq(4096.0)
    end
  end

  describe "scopes" do
    it "orders by recorded_at with .for_run" do
      agent_run = create(:agent_run, :running)
      older = create(:container_metric, agent_run: agent_run, recorded_at: 2.minutes.ago)
      newer = create(:container_metric, agent_run: agent_run, recorded_at: 1.minute.ago)

      expect(described_class.for_run(agent_run.id)).to eq([ older, newer ])
    end
  end
end
