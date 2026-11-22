# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers::DockerStatsParser do
  let(:raw_stats) do
    {
      "cpu_stats" => {
        "cpu_usage" => { "total_usage" => 500_000_000 },
        "system_cpu_usage" => 10_000_000_000,
        "online_cpus" => 2
      },
      "precpu_stats" => {
        "cpu_usage" => { "total_usage" => 400_000_000 },
        "system_cpu_usage" => 9_000_000_000
      },
      "memory_stats" => {
        "usage" => 2_147_483_648,
        "limit" => 4_294_967_296
      },
      "pids_stats" => {
        "current" => 42
      }
    }
  end

  describe ".parse_stats" do
    # @spec CONTAINER-RUNTIME-005
    it "returns a hash with all expected keys" do
      result = described_class.parse_stats(raw_stats)

      expect(result).to include(
        cpu_percent: 20.0,
        memory_bytes: 2_147_483_648,
        memory_limit_bytes: 4_294_967_296,
        memory_percent: 50.0,
        pids_count: 42
      )
    end

    # @spec CONTAINER-RUNTIME-005
    [ nil, [], "not Docker stats" ].each do |raw_stats|
      it "rejects #{raw_stats.inspect} as an unavailable stats sample" do
        expect { described_class.parse_stats(raw_stats) }
          .to raise_error(described_class::InvalidStatsError, "docker stats payload must be a hash")
      end
    end

    # @spec CONTAINER-RUNTIME-005
    it "normalizes malformed nested stats into unavailable samples" do
      invalid_stats = [
        {},
        raw_stats.merge("cpu_stats" => raw_stats.fetch("cpu_stats").merge("cpu_usage" => "invalid")),
        raw_stats.merge("memory_stats" => { "usage" => "invalid", "limit" => 1 }),
        raw_stats.merge("pids_stats" => { "current" => "invalid" })
      ]

      invalid_stats.each do |stats|
        expect { described_class.parse_stats(stats) }
          .to raise_error(described_class::InvalidStatsError)
      end
    end

    # @spec CONTAINER-RUNTIME-005
    it "preserves measured zero values and optional PID metrics" do
      raw_stats["cpu_stats"]["cpu_usage"]["total_usage"] = 0
      raw_stats["precpu_stats"]["cpu_usage"]["total_usage"] = 0
      raw_stats["cpu_stats"]["system_cpu_usage"] = 0
      raw_stats["precpu_stats"]["system_cpu_usage"] = 0
      raw_stats["memory_stats"] = { "usage" => 0, "limit" => 0 }
      raw_stats.delete("pids_stats")

      expect(described_class.parse_stats(raw_stats)).to include(
        cpu_percent: 0.0,
        memory_bytes: 0,
        memory_limit_bytes: 0,
        memory_percent: 0.0,
        pids_count: nil
      )
    end
  end

  describe ".parse_cpu" do
    it "calculates CPU percentage correctly" do
      expect(described_class.parse_cpu(raw_stats)).to eq(20.0)
    end

    it "returns 0.0 when system_delta is zero" do
      raw_stats["precpu_stats"]["system_cpu_usage"] = 10_000_000_000
      expect(described_class.parse_cpu(raw_stats)).to eq(0.0)
    end

    it "returns 0.0 when cpu_delta is negative" do
      raw_stats["precpu_stats"]["cpu_usage"]["total_usage"] = 600_000_000
      expect(described_class.parse_cpu(raw_stats)).to eq(0.0)
    end

    context "when online_cpus is absent" do
      let(:raw_stats) do
        {
          "cpu_stats" => {
            "cpu_usage" => {
              "total_usage" => 500_000_000,
              "percpu_usage" => [ 250_000_000, 250_000_000, 0, 0 ]
            },
            "system_cpu_usage" => 10_000_000_000
          },
          "precpu_stats" => {
            "cpu_usage" => { "total_usage" => 400_000_000 },
            "system_cpu_usage" => 9_000_000_000
          },
          "memory_stats" => {},
          "pids_stats" => {}
        }
      end

      it "falls back to percpu_usage length" do
        expect(described_class.parse_cpu(raw_stats)).to eq(40.0)
      end
    end
  end

  describe ".parse_memory_percent" do
    it "calculates memory percentage correctly" do
      expect(described_class.parse_memory_percent(raw_stats)).to eq(50.0)
    end

    it "returns 0.0 when limit is zero" do
      raw_stats["memory_stats"]["limit"] = 0
      expect(described_class.parse_memory_percent(raw_stats)).to eq(0.0)
    end
  end

  describe ".parse_pids" do
    it "returns the pids count as integer" do
      expect(described_class.parse_pids(raw_stats)).to eq(42)
    end

    it "returns nil when pids_stats.current is absent" do
      raw_stats["pids_stats"] = {}
      expect(described_class.parse_pids(raw_stats)).to be_nil
    end
  end
end
