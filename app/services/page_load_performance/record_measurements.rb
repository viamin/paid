# frozen_string_literal: true

module PageLoadPerformance
  # Turns the timing document the capture runner wrote into measurement rows.
  #
  # A missing, unparseable, or route-less document records nothing: the
  # screenshots are still worth publishing, so measurement degrades to today's
  # behavior rather than failing the capture.
  #
  # @spec PAGE-LOAD-LEDGER-001, PAGE-LOAD-MEASURE-008
  class RecordMeasurements
    def self.call(...) = new(...).call

    def initialize(agent_run:, document:, viewport:, source: "screenshot_capture")
      @agent_run = agent_run
      @document = document
      @viewport = viewport
      @source = source
    end

    def call
      return [] if routes.blank?

      routes.filter_map { |route_name, route| record(route_name, route) }
    end

    private

    attr_reader :agent_run, :source

    def routes
      @routes ||= @document.is_a?(Hash) ? @document["routes"] : nil
    end

    # @spec PAGE-LOAD-LEDGER-003
    def record(route_name, route)
      return nil unless route.is_a?(Hash)

      measurement = PageLoadMeasurement.find_or_initialize_by(
        project_id: project.id,
        pull_request_number: agent_run.pull_request_number,
        commit_sha: commit_sha,
        route_name: route_name
      )
      measurement.assign_attributes(attributes_for(route))
      measurement.save!
      measurement
    end

    def attributes_for(route)
      metrics = route["metrics"].to_h

      {
        account_id: project.account_id,
        project_id: project.id,
        agent_run_id: agent_run.id,
        route_path: route["path"],
        http_status: route["http_status"],
        source: source,
        sample_count: [ route["samples"].to_i, 1 ].max,
        samples: spread(metrics),
        viewport_width: viewport["width"],
        viewport_height: viewport["height"],
        captured_at: captured_at
      }.merge(medians(metrics))
    end

    # @spec PAGE-LOAD-MEASURE-005
    def medians(metrics)
      PageLoadMeasurement::METRICS.index_with { |name| metrics.dig(name, "median") }.symbolize_keys
    end

    def spread(metrics)
      metrics.each_with_object({}) do |(name, values), acc|
        next unless PageLoadMeasurement::METRICS.include?(name)

        acc[name] = values.slice("values", "min", "max")
      end
    end

    # The viewport is a host fact: the host knows what it asked the runner to
    # render at, and reading it back from the container document would let a
    # wrong value silently disqualify every later comparison. The keyword is
    # required and a blank one raises, so a host that forgets it fails loudly
    # instead of recording measurements that can never compare.
    # @spec PAGE-LOAD-MEASURE-014
    def viewport
      resolved = @viewport.to_h.stringify_keys
      raise ArgumentError, "RecordMeasurements requires the host's viewport" if resolved.blank?

      resolved
    end

    def captured_at
      Time.zone.parse(@document["captured_at"].to_s) || Time.current
    rescue ArgumentError, TypeError
      Time.current
    end

    def commit_sha
      agent_run.result_commit_sha || agent_run.base_commit_sha || agent_run.branch_name
    end

    def project
      @project ||= agent_run.project
    end
  end
end
