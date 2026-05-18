# frozen_string_literal: true

module LegacyAttributeBridge
  extend ActiveSupport::Concern

  class_methods do
    def synchronize_bridge_attributes(attributes, bridges)
      synced = attributes.to_h.stringify_keys

      bridges.each do |legacy_name, runner_name|
        if synced.key?(runner_name)
          synced[legacy_name] = synced[runner_name]
        elsif synced.key?(legacy_name)
          synced[runner_name] = synced[legacy_name]
        end
      end

      synced
    end
  end

  def update_column(name, value, touch: nil)
    attributes = { name => value }
    attributes[:touch] = touch unless touch.nil?

    update_columns(attributes)
  end
end
