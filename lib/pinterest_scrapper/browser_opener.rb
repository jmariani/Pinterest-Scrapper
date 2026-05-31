# frozen_string_literal: true

module PinterestScrapper
  class BrowserOpener
    def open(url)
      system("open", "-a", "Safari", url.to_s)
    end
  end
end
