# frozen_string_literal: true

module PageLoadPerformance
  # Normalizes the timing document the capture runner wrote inside the agent's
  # container.
  #
  # The document is container output, so it is untrusted in the same sense as
  # anything else an agent produces: it reaches the database, a pull request
  # comment, and a follow-up prompt. Every field is coerced to the shape the
  # ledger stores, and anything that fails coercion is dropped rather than
  # allowed to raise mid-insert or land unbounded in jsonb.
  #
  # @spec PAGE-LOAD-MEASURE-013
  module TimingDocument
    MAX_ROUTES = 100
    MAX_ROUTE_NAME = 255
    MAX_ROUTE_PATH = 2048
    # No page load is 24 hours; anything beyond this is a broken clock or a
    # crafted value, not a measurement.
    MAX_METRIC_MS = 86_400_000
    DEFAULT_MAX_SAMPLES = 10
    SAMPLE_KEYS = %w[min max].freeze

    def self.parse(document, max_routes: MAX_ROUTES, max_samples: DEFAULT_MAX_SAMPLES)
      return nil unless document.is_a?(Hash)

      routes = document["routes"]
      return nil unless routes.is_a?(Hash)

      normalized = routes.first(max_routes).each_with_object({}) do |(name, route), acc|
        clean = normalize_route(route, max_samples: max_samples)
        acc[truncate(name, MAX_ROUTE_NAME)] = clean if clean
      end

      document.merge("routes" => normalized)
    end

    def self.normalize_route(route, max_samples:)
      return nil unless route.is_a?(Hash)

      metrics = normalize_metrics(route["metrics"], max_samples: max_samples)
      return nil if metrics.empty?

      {
        "path" => truncate(route["path"], MAX_ROUTE_PATH),
        "http_status" => http_status(route["http_status"]),
        "samples" => sample_count(route["samples"], max_samples: max_samples),
        "metrics" => metrics
      }
    end

    def self.normalize_metrics(metrics, max_samples:)
      return {} unless metrics.is_a?(Hash)

      metrics.each_with_object({}) do |(name, values), acc|
        next unless PageLoadMeasurement::METRICS.include?(name)
        next unless values.is_a?(Hash)

        median = metric_value(values["median"])
        next if median.nil?

        acc[name] = SAMPLE_KEYS.index_with { |key| metric_value(values[key]) }.compact.merge(
          "median" => median,
          "values" => Array(values["values"]).first(max_samples).filter_map { |v| metric_value(v) }
        )
      end
    end

    # A metric that has not fired yet reports as 0 in the Navigation Timing
    # API. Recording that as a measurement would poison medians and read as a
    # large improvement on the next comparison, so it is dropped like any other
    # unusable value.
    def self.metric_value(value)
      return nil unless value.is_a?(Numeric)

      rounded = value.round
      return nil unless rounded.positive? && rounded <= MAX_METRIC_MS

      rounded
    end

    def self.http_status(value)
      return nil unless value.is_a?(Numeric)

      status = value.to_i
      status.between?(100, 599) ? status : nil
    end

    def self.sample_count(value, max_samples:)
      return 1 unless value.is_a?(Numeric)

      value.to_i.clamp(1, max_samples)
    end

    def self.truncate(value, limit)
      value&.to_s&.slice(0, limit)
    end

    private_class_method :normalize_route, :normalize_metrics, :metric_value, :http_status,
      :sample_count, :truncate
  end
end
