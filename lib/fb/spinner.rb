# frozen_string_literal: true

module FB
  module Spinner
    FRAMES = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze

    def self.spin(message)
      result = nil

      unless $stderr.tty?
        result = yield
        return result
      end

      done = false
      thread = Thread.new do
        i = 0
        while !done
          $stderr.print "\r#{FRAMES[i % FRAMES.length]} #{message}"
          $stderr.flush
          i += 1
          sleep 0.08
        end
      end

      begin
        result = yield
      ensure
        done = true
        thread.join
        $stderr.print "\r✓ #{message}\n"
      end

      result
    end
  end
end
