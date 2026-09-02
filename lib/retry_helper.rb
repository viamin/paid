# frozen_string_literal: true

module RetryHelper
  # Retries a block with exponential backoff when errors match the retryable predicate.
  #
  # @param max_attempts [Integer] Maximum number of retry attempts (including the first)
  # @param retryable [Proc] Callable that takes an error and returns true if it should be retried
  # @param delay_fn [Proc, nil] Callable that takes (attempt, error) and returns delay in seconds.
  #                             If nil, uses default exponential backoff (1, 2, 4, 8, ...).
  # @param sleep_fn [Proc, nil] Callable that takes delay and sleeps. If nil, uses global sleep.
  # @yield Block to retry; should raise on error
  # @return Result of the block
  # @raise [StandardError] The last error if max_attempts is exhausted
  def self.with_retries(max_attempts:, retryable:, delay_fn: nil, sleep_fn: nil)
    attempt = 0
    loop do
      attempt += 1
      begin
        return yield
      rescue => error
        if retryable.call(error) && attempt < max_attempts
          delay = delay_fn ? delay_fn.call(attempt, error) : (1.0 * (2 ** (attempt - 1)))
          if sleep_fn
            sleep_fn.call(delay)
          else
            sleep(delay)
          end
        else
          raise
        end
      end
    end
  end
end
