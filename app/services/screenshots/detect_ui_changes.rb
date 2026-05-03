# frozen_string_literal: true

module Screenshots
  # Determines whether a set of changed file paths includes UI-facing changes.
  #
  # UI-facing changes are defined as modifications to files that directly
  # affect what a user sees in the browser: views, stylesheets, JavaScript,
  # layout templates, and frontend components.
  #
  # @example
  #   result = Screenshots::DetectUiChanges.call(changed_files: ["app/views/projects/index.html.erb"])
  #   result[:ui_changes?]  # => true
  #   result[:ui_files]     # => ["app/views/projects/index.html.erb"]
  class DetectUiChanges
    UI_FILE_EXCLUSIONS = [
      %r{\Aapp/views/devise/mailer/},
      %r{\Aapp/views/layouts/mailer(?:\.text)?\.erb\z},
      %r{\Aapp/views/pwa/}
    ].freeze

    UI_FILE_PATTERNS = [
      %r{\Aapp/views/},
      %r{\Aapp/javascript/},
      %r{\Aapp/assets/stylesheets/},
      %r{\Aapp/assets/builds/},
      %r{\Aapp/helpers/.*_helper\.rb\z},
      %r{\Aapp/components/},
      %r{\Aapp/frontend/},
      %r{\Aconfig/locales/.*\.yml\z},
      %r{\.html\.erb\z},
      %r{\.html\.haml\z},
      %r{\.html\.slim\z},
      %r{\.js\z},
      %r{\.jsx\z},
      %r{\.ts\z},
      %r{\.tsx\z},
      %r{\.css\z},
      %r{\.scss\z},
      %r{\.sass\z},
      %r{\.vue\z},
      %r{\.svelte\z}
    ].freeze

    # @param changed_files [Array<String>] list of file paths changed in the PR
    # @return [Hash] with :ui_changes? boolean and :ui_files array
    def self.call(changed_files:)
      new(changed_files: changed_files).call
    end

    def initialize(changed_files:)
      @changed_files = Array(changed_files)
    end

    def call
      ui_files = @changed_files.select { |path| ui_file?(path) }

      {
        ui_changes?: ui_files.any?,
        ui_files: ui_files
      }
    end

    private

    def ui_file?(path)
      return false if UI_FILE_EXCLUSIONS.any? { |pattern| pattern.match?(path) }

      UI_FILE_PATTERNS.any? { |pattern| pattern.match?(path) }
    end
  end
end
