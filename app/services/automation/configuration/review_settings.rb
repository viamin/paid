# frozen_string_literal: true

module Automation
  module Configuration
    # Normalized view of a project's +review_settings+ JSONB field.
    # Construct via {.from_project}, which delegates to
    # +Project#effective_review_settings+ so defaults are already merged in.
    #
    # The object exposes per-method configs via {#method_for} (keyed by
    # symbol) and enabled-method helpers used by auto-review strategy
    # resolution.
    class ReviewSettings < ::Data.define(
      :enabled,
      :wait_for_reviews,
      :address_all_bot_reviews,
      :methods
    )
      class << self
        def from_project(project)
          from_hash(project.effective_review_settings)
        end

        def from_hash(hash)
          hash ||= {}
          methods_hash = hash["methods"] || {}
          methods = ReviewMethod::NAMES.each_with_object({}) do |name, memo|
            memo[name] = ReviewMethod.from_hash(name, methods_hash[name.to_s])
          end.freeze

          new(
            enabled: hash["enabled"] == true,
            wait_for_reviews: hash["wait_for_reviews"] != false,
            address_all_bot_reviews: hash["address_all_bot_reviews"] == true,
            methods: methods
          )
        end
      end

      def enabled? = enabled == true
      def wait_for_reviews? = wait_for_reviews == true
      def address_all_bot_reviews? = address_all_bot_reviews == true

      # Returns the {ReviewMethod} for +name+, or nil when the name is not
      # a known review method.
      def method_for(name)
        methods[name.to_sym]
      end

      def method_enabled?(name)
        method_for(name)&.enabled? == true
      end

      # Returns the symbol names of all enabled review methods, preserving
      # the canonical +ReviewMethod::NAMES+ ordering.
      def enabled_method_names
        ReviewMethod::NAMES.select { |n| methods[n].enabled? }
      end

      # Returns an Array of {ReviewMethod} objects for every enabled method.
      def enabled_methods
        enabled_method_names.map { |n| methods[n] }
      end
    end
  end
end
