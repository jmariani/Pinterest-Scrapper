# frozen_string_literal: true

module PinterestScrapper
  class SessionLock
    CHECK_INTERVAL_SECONDS = 5

    def locked?
      output = `ioreg -n Root -d1 2>/dev/null`

      output.match?(/"CGSSessionScreenIsLocked"\s*=\s*Yes/)
    rescue StandardError
      false
    end
  end
end
