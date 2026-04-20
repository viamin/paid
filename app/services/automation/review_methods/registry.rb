# frozen_string_literal: true

module Automation
  module ReviewMethods
    # Registry of known review method plugins.
    #
    # {Strategies::AutoReview} looks up the plugin class for a given
    # {Configuration::ReviewMethod} by name; tests MAY register a fake
    # plugin class via {.register} to exercise the strategy without
    # touching provider-specific behavior.
    class Registry
      UnknownMethodError = Class.new(StandardError)

      DEFAULTS = {
        paid_agent: PaidAgent,
        copilot: Copilot,
        codex: Codex,
        manual: Manual,
        ci_action: CiAction
      }.freeze

      class << self
        def resolve(name)
          klass = registry.fetch(name.to_sym) do
            raise UnknownMethodError, "No review method plugin registered for #{name.inspect}"
          end
          klass
        end

        def register(name, plugin_class)
          registry[name.to_sym] = plugin_class
        end

        def reset!
          @registry = nil
        end

        def known
          registry.keys
        end

        private

        def registry
          @registry ||= DEFAULTS.dup
        end
      end
    end
  end
end
