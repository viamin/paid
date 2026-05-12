# frozen_string_literal: true

module ConfigurationBundles
  module Canonicalization
    private

    def canonicalize(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, nested_value), normalized|
          normalized[key.to_s] = canonicalize(nested_value)
        end.sort.to_h
      when Array
        value.map { |nested_value| canonicalize(nested_value) }
      else
        value
      end
    end

    def normalized_mcp_servers(source)
      snapshots = source.is_a?(Hash) ? source["mcp_servers"] : source

      Array(snapshots)
        .filter_map { |snapshot| canonicalize(snapshot) if snapshot.is_a?(Hash) }
        .sort_by { |snapshot| JSON.generate(snapshot) }
    end
  end
end
