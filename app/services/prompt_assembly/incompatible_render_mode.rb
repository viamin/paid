# frozen_string_literal: true

module PromptAssembly
  # A section declares a render mode its trust level does not permit.
  class IncompatibleRenderMode < Error; end
end
