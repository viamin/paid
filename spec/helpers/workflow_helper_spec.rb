# frozen_string_literal: true

require "rails_helper"

RSpec.describe WorkflowHelper do
  describe "#workflow_status_class" do
    it "returns blue classes for running status" do
      expect(helper.workflow_status_class("running")).to eq("bg-blue-100 text-blue-800")
    end

    it "returns green classes for completed status" do
      expect(helper.workflow_status_class("completed")).to eq("bg-green-100 text-green-800")
    end

    it "returns red classes for failed status" do
      expect(helper.workflow_status_class("failed")).to eq("bg-red-100 text-red-800")
    end

    it "returns gray classes for cancelled status" do
      expect(helper.workflow_status_class("cancelled")).to eq("bg-gray-100 text-gray-600")
    end

    it "returns orange classes for timed_out status" do
      expect(helper.workflow_status_class("timed_out")).to eq("bg-orange-100 text-orange-800")
    end

    it "returns yellow classes for unknown status" do
      expect(helper.workflow_status_class("unknown")).to eq("bg-yellow-100 text-yellow-800")
    end
  end

  describe "#workflow_duration" do
    it "returns dash when started_at is nil" do
      workflow = build(:workflow_state, started_at: nil)
      expect(helper.workflow_duration(workflow)).to eq("-")
    end

    it "returns seconds for short durations" do
      workflow = build(:workflow_state, started_at: 30.seconds.ago, completed_at: Time.current)
      expect(helper.workflow_duration(workflow)).to eq("30s")
    end

    it "returns minutes and seconds for medium durations" do
      workflow = build(:workflow_state, started_at: 125.seconds.ago, completed_at: Time.current)
      expect(helper.workflow_duration(workflow)).to eq("2m 5s")
    end

    it "returns hours and minutes for long durations" do
      workflow = build(:workflow_state, started_at: 3725.seconds.ago, completed_at: Time.current)
      expect(helper.workflow_duration(workflow)).to eq("1h 2m")
    end

    it "uses current time when completed_at is nil" do
      workflow = build(:workflow_state, started_at: 10.seconds.ago, completed_at: nil)
      result = helper.workflow_duration(workflow)
      expect(result).to match(/\d+s/)
    end
  end
end
