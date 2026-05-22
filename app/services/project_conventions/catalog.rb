# frozen_string_literal: true

module ProjectConventions
  module Catalog
    DEFINITIONS = {
      "release_automation" => {
        category: "release_automation",
        default: {}
      },
      "commit_style" => {
        category: "commit_convention_policy",
        default: {
          "type" => "conventional_commits",
          "required" => false,
          "default_type" => "feat"
        }
      },
      "pr_title_style" => {
        category: "pr_title_policy",
        default: {
          "type" => "conventional_commits",
          "required" => false
        }
      },
      "hook_manager" => {
        category: "hook_system",
        default: {}
      },
      "issue_dependency_format" => {
        category: "issue_dependency_wording",
        default: {
          "depends_on_prefix" => "Depends on",
          "blocked_by_prefix" => "Blocked by",
          "heading" => "## Dependencies"
        }
      },
      "ci_entrypoint" => {
        category: "ci_entrypoints",
        default: {}
      }
    }.freeze

    module_function

    def category_for(key)
      definition_for(key).fetch(:category)
    end

    def default_for(key)
      definition_for(key).fetch(:default).deep_dup
    end

    def known_keys
      DEFINITIONS.keys
    end

    def definition_for(key)
      DEFINITIONS.fetch(key.to_s) do
        {
          category: "custom",
          default: {}
        }
      end
    end
  end
end
