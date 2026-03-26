# frozen_string_literal: true

module Integrations
  # Base class for integration providers. Each provider represents a connection
  # to an external service (e.g., GitHub, Linear, Jira).
  #
  # Subclasses must implement:
  #   - self.key        → unique identifier (e.g., :github)
  #   - self.name       → human-readable name (e.g., "GitHub")
  #   - self.category   → one of CATEGORIES
  #   - self.icon_svg   → inline SVG string for the provider logo
  #   - self.model_class → the ActiveRecord model for this provider's tokens
  #   - self.new_path   → route helper path to the "add" form
  #   - self.index_path  → route helper path to the list view
  class Provider
    CATEGORIES = {
      repository: { label: "Repository", description: "Source code hosting and version control" },
      issue_tracking: { label: "Issue Tracking", description: "Project management and issue tracking" },
      llm_provider: { label: "LLM Providers", description: "AI model API keys for agent execution" }
    }.freeze

    class << self
      def key
        raise NotImplementedError, "#{name} must implement .key"
      end

      def provider_name
        raise NotImplementedError, "#{name} must implement .provider_name"
      end

      def category
        raise NotImplementedError, "#{name} must implement .category"
      end

      def icon_svg
        raise NotImplementedError, "#{name} must implement .icon_svg"
      end

      def model_class
        raise NotImplementedError, "#{name} must implement .model_class"
      end

      def new_path
        raise NotImplementedError, "#{name} must implement .new_path"
      end

      def index_path
        raise NotImplementedError, "#{name} must implement .index_path"
      end

      def category_label
        CATEGORIES.dig(category, :label)
      end

      def available?
        true
      end

      def configured?(account)
        model_class.where(account: account).exists?
      end

      def token_count(account)
        model_class.where(account: account).count
      end
    end
  end
end
