# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApplicationHelper, "#local_time" do
  describe "#local_time" do
    let(:time) { Time.utc(2024, 6, 15, 14, 30, 0) }

    it "returns nil for nil time" do
      expect(helper.local_time(nil)).to be_nil
    end

    it "renders a <time> element with ISO 8601 datetime" do
      result = helper.local_time(time)
      expect(result).to include('datetime="2024-06-15T14:30:00Z"')
    end

    it "includes the local-time Stimulus controller" do
      result = helper.local_time(time)
      expect(result).to include('data-controller="local-time"')
    end

    it "defaults to long format" do
      result = helper.local_time(time)
      expect(result).to include('data-local-time-format-value="long"')
    end

    it "uses the specified format" do
      result = helper.local_time(time, format: :short)
      expect(result).to include('data-local-time-format-value="short"')
    end

    it "renders a UTC fallback for long format" do
      result = helper.local_time(time)
      expect(result).to include("June 15, 2024")
      expect(result).to include("UTC")
    end

    it "renders a UTC fallback for short format" do
      result = helper.local_time(time, format: :short)
      expect(result).to include("Jun 15, 2024 14:30 UTC")
    end

    it "renders a date-only fallback for date format" do
      result = helper.local_time(time, format: :date)
      expect(result).to include("Jun 15, 2024")
    end

    it "renders a time-only fallback for time format" do
      result = helper.local_time(time, format: :time)
      expect(result).to include("14:30:00 UTC")
    end

    it "renders a relative fallback for relative format" do
      result = helper.local_time(time, format: :relative)
      expect(result).to include("ago")
    end

    it "wraps content in a <time> tag" do
      result = helper.local_time(time)
      expect(result).to match(%r{\A<time .+</time>\z})
    end
  end
end
