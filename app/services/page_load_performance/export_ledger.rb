# frozen_string_literal: true

module PageLoadPerformance
  # Regenerates the project's page load ledger document from the measurement
  # rows and writes it beside the project's screenshots.
  #
  # Regeneration — rather than read-modify-write on the stored document — is
  # what makes concurrent captures on different pull requests safe: object
  # storage has no compare-and-swap, so a merge would silently drop history.
  #
  # @spec PAGE-LOAD-EXPORT-001, PAGE-LOAD-EXPORT-002
  class ExportLedger
    ENTRIES_PER_ROUTE = 100
    FILENAME = "page-load-times.json"

    def self.call(...) = new(...).call

    def initialize(project:, storage: nil, logger: Rails.logger)
      @project = project
      @storage = storage
      @logger = logger
    end

    def call
      return skip unless ArtifactStorage.configured?

      storage.upload_document(key: key, body: JSON.pretty_generate(document), content_type: "application/json")
    rescue Screenshots::Storage::StorageError => e
      logger.warn(message: "page_load.export_failed", project_id: project.id, error: e.message)
      nil
    end

    private

    attr_reader :project, :logger

    # @spec PAGE-LOAD-EXPORT-003
    def skip
      logger.info(message: "page_load.export_skipped", project_id: project.id, reason: "storage_unconfigured")
      nil
    end

    def key
      "#{Screenshots::Storage.namespace_prefix(org: project.owner, repo: project.repo)}#{FILENAME}"
    end

    def document
      {
        "project" => project.full_name,
        "generated_at" => Time.current.utc.iso8601,
        "comparison_metric" => settings.comparison_metric,
        "routes" => routes
      }
    end

    def routes
      measurements_by_route.transform_values do |rows|
        entries = rows.first(ENTRIES_PER_ROUTE)
        { "entries" => entries.map { |row| entry(row) }, "summary" => summary(entries) }
      end
    end

    # Loading every measurement the project has ever recorded just to keep the
    # newest ENTRIES_PER_ROUTE of each would grow with retention and PR volume,
    # inside the capture path. Route names come from one cheap distinct query,
    # then each route loads only the rows the document will actually hold.
    def measurements_by_route
      route_names.index_with do |route_name|
        PageLoadMeasurement
          .where(project_id: project.id, route_name: route_name)
          .recent_first
          .limit(ENTRIES_PER_ROUTE)
          .to_a
      end.reject { |_, rows| rows.empty? }
    end

    def route_names
      PageLoadMeasurement.where(project_id: project.id).distinct.pluck(:route_name)
    end

    def entry(row)
      {
        "captured_at" => row.captured_at.utc.iso8601,
        "pull_request_number" => row.pull_request_number,
        "commit_sha" => row.commit_sha,
        "route_path" => row.route_path,
        "http_status" => row.http_status,
        "sample_count" => row.sample_count
      }.merge(PageLoadMeasurement::METRICS.index_with { |metric| row.metric(metric) })
    end

    def summary(entries)
      values = entries.filter_map { |row| row.metric(settings.comparison_metric) || row.metric(PageLoadMeasurement::FALLBACK_METRIC) }
      return { "trailing_median_ms" => nil, "best_ms" => nil, "worst_ms" => nil } if values.empty?

      {
        "trailing_median_ms" => Median.of(values),
        "best_ms" => values.min,
        "worst_ms" => values.max,
        "last_direction" => direction(values)
      }
    end

    def direction(values)
      return "flat" if values.size < 2

      values.first > values[1] ? "slower" : "faster"
    end

    def settings
      @settings ||= Settings.for(project)
    end

    def storage
      @storage ||= Screenshots::Storage.new
    end
  end
end
