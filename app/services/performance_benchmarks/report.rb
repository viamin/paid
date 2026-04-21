# frozen_string_literal: true

module PerformanceBenchmarks
  class Report
    attr_reader :measurements, :generated_at

    def initialize(measurements:, generated_at: Time.current)
      @measurements = measurements
      @generated_at = generated_at
    end

    def to_h
      {
        generated_at: generated_at.iso8601,
        environment: environment,
        summary: summary,
        metrics: measurements.map(&:to_h)
      }
    end

    def to_markdown
      lines = [
        "# Performance Benchmark Report",
        "",
        "- Generated at: #{generated_at.iso8601}",
        "- Rails environment: #{Rails.env}",
        "- Git SHA: #{git_sha}",
        "",
        "| Metric | Samples | P50 | P95 | Budget | Status |",
        "| --- | ---: | ---: | ---: | ---: | --- |"
      ]

      measurements.each do |measurement|
        data = measurement.to_h
        lines << [
          "| #{data.fetch(:name)}",
          data.fetch(:sample_count).to_s,
          format_ms(data[:p50_ms]),
          format_ms(data[:p95_ms]),
          format_ms(data[:budget_ms]),
          "#{data.fetch(:status)} |"
        ].join(" | ")
      end

      skipped = measurements.select(&:skipped?)
      return lines.join("\n") if skipped.empty?

      lines += [ "", "## Skipped Metrics" ]
      skipped.each do |measurement|
        lines << "- #{measurement.name}: #{measurement.skipped_reason}"
      end
      lines.join("\n")
    end

    private

    def summary
      statuses = measurements.group_by { |measurement| measurement.to_h.fetch(:status) }
      {
        total: measurements.size,
        passed: statuses.fetch("pass", []).size,
        failed: statuses.fetch("fail", []).size,
        skipped: statuses.fetch("skipped", []).size
      }
    end

    def environment
      {
        rails_env: Rails.env,
        ruby_version: RUBY_VERSION,
        git_sha: git_sha
      }
    end

    def git_sha
      @git_sha ||= `git rev-parse --short HEAD 2>/dev/null`.strip.presence || "unknown"
    end

    def format_ms(value)
      value.nil? ? "n/a" : "#{value} ms"
    end
  end
end
