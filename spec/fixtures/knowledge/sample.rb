# frozen_string_literal: true

module SampleModule
  class SampleClass
    def initialize(name)
      @name = name
    end

    def greet
      "Hello, #{@name}"
    end

    def farewell
      "Goodbye, #{@name}"
    end
  end

  class AnotherClass
    def initialize
      @started = true
    end

    def perform
      true
    end
  end
end
