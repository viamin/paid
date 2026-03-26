# frozen_string_literal: true

module Integrations
  # Central registry for all integration providers. New providers register
  # themselves here and can be discovered by the UI without modifying
  # core integration management code.
  class Registry
    class << self
      def providers
        @providers ||= []
      end

      def register(provider_class)
        providers << provider_class unless providers.include?(provider_class)
      end

      def reset!
        @providers = []
      end

      def find(key)
        providers.find { |p| p.key == key.to_sym }
      end

      def by_category
        providers.group_by(&:category)
      end

      def categories
        Provider::CATEGORIES.keys.select { |cat| providers.any? { |p| p.category == cat } }
      end
    end
  end
end
