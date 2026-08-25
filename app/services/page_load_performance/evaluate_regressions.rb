# frozen_string_literal: true

module PageLoadPerformance
  # Compares each measured route against the previous capture on the same pull
  # request and maintains the regression findings that follow from it.
  #
  # A route is flagged only when it is slower by both the configured ratio and
  # the configured absolute floor — ratio alone flags trivial drift on fast
  # pages, the floor alone ignores a slow page that doubled.
  #
  # @spec PAGE-LOAD-REGRESSION-001, PAGE-LOAD-REGRESSION-002
  class EvaluateRegressions
    TRAILING_WINDOW = 20

    def self.call(...) = new(...).call

    def initialize(agent_run:, measurements:, hints: {}, changed_files: [])
      @agent_run = agent_run
      @measurements = Array(measurements)
      @hints = hints.to_h
      @changed_files = Array(changed_files)
    end

    def call
      comparisons = measurements.map { |measurement| evaluate(measurement) }
      supersede_unmeasured_findings!
      comparisons
    end

    private

    attr_reader :agent_run, :measurements, :hints, :changed_files

    # @spec PAGE-LOAD-REGRESSION-003
    def evaluate(measurement)
      baseline = measurement.baseline
      return comparison(measurement, "no_baseline", nil, nil, nil) if baseline.nil?
      return comparison(measurement, "not_comparable", nil, nil, nil) unless comparable?(measurement, baseline)

      metric = resolved_metric(measurement, baseline)
      return comparison(measurement, "not_comparable", nil, nil, nil) if metric.nil?

      current = measurement.metric(metric)
      before = baseline.metric(metric)
      return comparison(measurement, "regressed", metric, before, current, finding: raise_finding(measurement, baseline, metric, before, current)) if regressed?(before, current)

      resolve_finding(measurement)
      comparison(measurement, "unchanged", metric, before, current)
    end

    # A comparison only means something when both captures measured the same
    # page in the same shape.
    # @spec PAGE-LOAD-REGRESSION-004
    def comparable?(measurement, baseline)
      measurement.route_path == baseline.route_path &&
        measurement.http_status == baseline.http_status &&
        measurement.viewport == baseline.viewport
    end

    # @spec PAGE-LOAD-REGRESSION-001
    def resolved_metric(measurement, baseline)
      configured = settings.comparison_metric
      return configured if measurement.metric(configured) && baseline.metric(configured)

      fallback = PageLoadMeasurement::FALLBACK_METRIC
      return fallback if measurement.metric(fallback) && baseline.metric(fallback)

      nil
    end

    def regressed?(before, current)
      return false if before.to_i.zero?

      delta = current - before
      delta > settings.regression_floor_ms && delta > before * settings.regression_ratio
    end

  # @spec PAGE-LOAD-REGRESSION-005, PAGE-LOAD-REGRESSION-009
  def raise_finding(measurement, baseline, metric, before, current)
    finding = PageLoadRegressionFinding.find_or_initialize_by(
      project_id: project.id,
      pull_request_number: measurement.pull_request_number,
      route_name: measurement.route_name,
      status: "open"
    )
    finding.assign_attributes(
      account_id: project.account_id,
      agent_run_id: agent_run.id,
      comparison_metric: metric,
      baseline_ms: before,
      current_ms: current,
      delta_ms: current - before,
      delta_ratio: ((current - before).to_f / before).round(4),
      baseline_commit_sha: baseline.commit_sha,
      commit_sha: measurement.commit_sha,
      route_path: measurement.route_path,
      sample_spread: { "baseline" => baseline.samples[metric], "current" => measurement.samples[metric] }.compact,
      changed_files: changed_files,
      actionable: hints.key?(measurement.route_name.to_s)
    )
    finding.save!
    finding
  end

    # @spec PAGE-LOAD-REGRESSION-006
    def resolve_finding(measurement)
      open_findings.find { |finding| finding.route_name == measurement.route_name }&.resolve!
    end

    # @spec PAGE-LOAD-REGRESSION-008
    def supersede_unmeasured_findings!
      measured = measurements.map(&:route_name)
      open_findings.reject { |finding| measured.include?(finding.route_name) }.each(&:supersede!)
    end

    def open_findings
      @open_findings ||= PageLoadRegressionFinding
        .where(project_id: project.id, pull_request_number: agent_run.pull_request_number)
        .open_findings
        .to_a
    end

    def comparison(measurement, status, metric, baseline_ms, current_ms, finding: nil)
      Comparison.new(
        route_name: measurement.route_name,
        status: status,
        metric: metric,
        baseline_ms: baseline_ms,
        current_ms: current_ms,
        delta_ms: baseline_ms && current_ms ? current_ms - baseline_ms : nil,
        trailing_median_ms: trailing_median(measurement, metric),
        finding: finding
      )
    end

    def trailing_median(measurement, metric)
      metric ||= settings.comparison_metric
      values = PageLoadMeasurement
        .where(project_id: project.id, route_name: measurement.route_name)
        .where.not(commit_sha: measurement.commit_sha)
        .recent_first
        .limit(TRAILING_WINDOW)
        .filter_map { |row| row.metric(metric) }
      return nil if values.empty?

      Median.of(values)
    end

    def settings
      @settings ||= Settings.for(project)
    end

    def project
      @project ||= agent_run.project
    end
  end
end
