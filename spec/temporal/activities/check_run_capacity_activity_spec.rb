# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::CheckRunCapacityActivity do
  let(:activity) { described_class.new }

  describe "#execute" do
    before do
      allow(Rails.application.config.x).to receive(:max_concurrent_runs).and_return(2)
    end

    it "returns has_capacity: true when below limit" do
      create(:agent_run, :running)

      result = activity.execute({})

      expect(result[:has_capacity]).to be true
      expect(result[:active_count]).to eq(1)
      expect(result[:max_concurrent_runs]).to eq(2)
    end

    it "returns has_capacity: false when at limit" do
      create(:agent_run, :running)
      create(:agent_run) # pending counts as active

      result = activity.execute({})

      expect(result[:has_capacity]).to be false
      expect(result[:active_count]).to eq(2)
    end

    it "does not count queued runs as active" do
      create(:agent_run, :running)
      create(:agent_run, :queued)

      result = activity.execute({})

      expect(result[:has_capacity]).to be true
      expect(result[:active_count]).to eq(1)
    end

    it "does not count finished runs as active" do
      create(:agent_run, :completed)
      create(:agent_run, :failed)

      result = activity.execute({})

      expect(result[:has_capacity]).to be true
      expect(result[:active_count]).to eq(0)
    end
  end
end
