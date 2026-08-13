# frozen_string_literal: true

module Knowledge
  module Analyzers
    # Analyzes structural code artifacts to detect patterns that inform style
    # guide suggestions. Examines naming conventions, method/class metrics,
    # and language distribution from TreeSitterCollector output.
    #
    # @example
    #   artifacts = TreeSitterCollector.new(...).collect
    #   analysis = StructuralAnalyzer.call(artifacts)
    #   analysis[:naming_conventions] # => { "method" => { dominant: "snake", ... } }
    class StructuralAnalyzer
      attr_reader :artifacts

      def initialize(artifacts)
        @artifacts = artifacts.select { |a| a[:artifact_type] == "structure" }
      end

      def self.call(artifacts)
        new(artifacts).analyze
      end

      def analyze
        {
          naming_conventions: detect_naming_conventions,
          method_metrics: analyze_method_metrics,
          class_metrics: analyze_class_metrics,
          languages: detect_languages
        }
      end

      private

      def detect_naming_conventions
        by_element = artifacts.group_by { |a| a[:metadata][:element_type] }

        by_element.transform_values do |group|
          styles = group.filter_map { |a| a[:metadata][:naming_style] }.tally
          dominant = styles.max_by { |_, count| count }&.first
          { styles: styles, dominant: dominant, total: group.size }
        end
      end

      def analyze_method_metrics
        methods = artifacts.select do |a|
          %w[method function].include?(a[:metadata][:element_type])
        end
        return {} if methods.empty?

        line_counts = methods.filter_map { |m| m[:metadata][:line_count] }
        param_counts = methods.map { |m| count_params(m[:metadata][:params]) }

        {
          count: methods.size,
          avg_length: safe_average(line_counts),
          max_length: line_counts.max || 0,
          avg_params: safe_average(param_counts),
          max_params: param_counts.max || 0,
          long_methods: methods.count { |m| (m[:metadata][:line_count] || 0) > 20 }
        }
      end

      def analyze_class_metrics
        classes = artifacts.select do |a|
          %w[class struct].include?(a[:metadata][:element_type])
        end
        return {} if classes.empty?

        with_parent = classes.count { |c| c[:metadata][:parent] }
        line_counts = classes.filter_map { |c| c[:metadata][:line_count] }

        {
          count: classes.size,
          with_inheritance: with_parent,
          avg_length: safe_average(line_counts),
          max_length: line_counts.max || 0,
          large_classes: classes.count { |c| (c[:metadata][:line_count] || 0) > 100 }
        }
      end

      def detect_languages
        artifacts.filter_map { |a| a[:metadata][:language] }.uniq.sort
      end

      def count_params(params_str)
        return 0 if params_str.nil? || params_str.strip.empty?
        params_str.split(",").size
      end

      def safe_average(values)
        return 0 if values.empty?
        (values.sum.to_f / values.size).round(1)
      end
    end
  end
end
