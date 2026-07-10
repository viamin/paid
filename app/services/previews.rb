# frozen_string_literal: true

module Previews
  # Default localhost port range the reverse proxy forwards /previews/:token
  # traffic to (RDR-045). Override with the PREVIEW_PORT_RANGE env var
  # ("8200-8299"). The pool is bounded so concurrent previews are capped.
  DEFAULT_PORT_RANGE = (8200..8299).freeze

  module_function

  def port_range
    return DEFAULT_PORT_RANGE if ENV["PREVIEW_PORT_RANGE"].blank?

    bounds = ENV["PREVIEW_PORT_RANGE"].to_s.split("-", 2).map { |v| Integer(v.strip, 10) rescue nil }
    return DEFAULT_PORT_RANGE unless bounds.size == 2 && bounds.all? && bounds.first <= bounds.last

    (bounds.first..bounds.last)
  end
end
