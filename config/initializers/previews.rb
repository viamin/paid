# frozen_string_literal: true

module Previews
  DEFAULT_PORT_RANGE = (8200..8299).freeze unless const_defined?(:DEFAULT_PORT_RANGE)

  def self.port_range
    return DEFAULT_PORT_RANGE if ENV["PREVIEW_PORT_RANGE"].blank?

    bounds = ENV["PREVIEW_PORT_RANGE"].to_s.split("-", 2).map { |value| Integer(value.strip, 10) rescue nil }
    return DEFAULT_PORT_RANGE unless bounds.size == 2 && bounds.all? && bounds.first <= bounds.last

    (bounds.first..bounds.last)
  end
end
