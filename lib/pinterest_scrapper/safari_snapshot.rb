# frozen_string_literal: true

require "json"
require "open3"
require "securerandom"

require_relative "session_lock"

module PinterestScrapper
  class SafariSnapshot
    Snapshot = Struct.new(:url, :body, :urls, keyword_init: true)

    PROGRESS_PREFIX = "PinterestScrapperProgress: "
    STABLE_SCROLLS = 3
    WAIT_SECONDS = 2
    SCROLL_WAIT_SECONDS = 1

    COLLECT_URLS_JAVASCRIPT = <<~JS.freeze
      (() => {
        window.__pinterestScrapperUrls ||= new Set();
        const urls = window.__pinterestScrapperUrls;
        const add = (value) => {
          if (!value || typeof value !== "string") return;
          try {
            urls.add(new URL(value, document.baseURI).href);
          } catch (_) {}
        };

        document.querySelectorAll("[href]").forEach((node) => add(node.getAttribute("href")));
        document.querySelectorAll("[src]").forEach((node) => add(node.getAttribute("src")));
        document.querySelectorAll("[srcset]").forEach((node) => {
          node.getAttribute("srcset").split(",").forEach((entry) => add(entry.trim().split(/\\s+/)[0]));
        });
        document.querySelectorAll("*").forEach((node) => {
          Array.from(node.attributes || []).forEach((attribute) => {
            const value = attribute.value || "";
            value.match(/(?:https?:)?\\/\\/i\\.pinimg\\.com\\/[^"'<>\\s,)\\\\]+/gi)?.forEach(add);
            value.match(/(?:https?:)?\\/\\/(?:[a-z0-9-]+\\.)?pinterest\\.com\\/pin\\/\\d+\\/?|\\/pin\\/\\d+\\/?/gi)?.forEach(add);
          });
        });
        document.querySelectorAll("img").forEach((img) => {
          add(img.currentSrc);
          add(img.src);
          if (img.srcset) {
            img.srcset.split(",").forEach((entry) => add(entry.trim().split(/\\s+/)[0]));
          }
        });
        performance.getEntriesByType("resource").forEach((entry) => add(entry.name));

        return Array.from(urls);
      })()
    JS
    SNAPSHOT_JAVASCRIPT = <<~JS.freeze
      (() => {
        const urls = #{COLLECT_URLS_JAVASCRIPT};

        return JSON.stringify({
          url: location.href,
          html: document.documentElement.outerHTML,
          urls: urls
        });
      })();
    JS
    URL_COUNT_JAVASCRIPT = <<~JS.freeze
      (() => {
        const urls = #{COLLECT_URLS_JAVASCRIPT};
        const pinUrls = new Set();
        const originalImageUrls = new Set();
        const normalizeText = (text) => {
          const textarea = document.createElement("textarea");
          textarea.innerHTML = text;
          return textarea.value
            .replace(/\\\\\\//g, "/")
            .replace(/\\\\u002F/g, "/")
            .replace(/\\\\u002f/g, "/")
            .replace(/\\\\u003A/g, ":")
            .replace(/\\\\u003a/g, ":")
            .replace(/\\\\u0026/g, "&");
        };
        const percentDecode = (text) => {
          try {
            return decodeURIComponent(text);
          } catch (_) {
            return text;
          }
        };
        const addPinUrl = (url) => {
          try {
            const parsedUrl = new URL(url, document.baseURI);
            if (
              (parsedUrl.hostname === "pinterest.com" || parsedUrl.hostname.endsWith(".pinterest.com")) &&
              /^\\/pin\\/\\d+\\/?$/.test(parsedUrl.pathname)
            ) {
              parsedUrl.protocol = "https:";
              parsedUrl.hostname = "www.pinterest.com";
              parsedUrl.search = "";
              parsedUrl.hash = "";
              const pathname = parsedUrl.pathname.endsWith("/") ? parsedUrl.pathname : `${parsedUrl.pathname}/`;
              pinUrls.add(`${parsedUrl.origin}${pathname}`);
            }
          } catch (_) {}
        };
        const addOriginalImageUrl = (url) => {
          try {
            const parsedUrl = new URL(url, document.baseURI);
            if (
              parsedUrl.hostname === "i.pinimg.com" &&
              parsedUrl.pathname.startsWith("/originals/")
            ) {
              parsedUrl.search = "";
              parsedUrl.hash = "";
              originalImageUrls.add(parsedUrl.href);
            }
          } catch (_) {}
        };

        urls.forEach((url) => {
          addPinUrl(url);
          addOriginalImageUrl(url);
        });

        const html = normalizeText(percentDecode(document.documentElement.outerHTML));
        html.match(/(?:https?:)?\\/\\/(?:[a-z0-9-]+\\.)?pinterest\\.com\\/pin\\/\\d+\\/?|\\/pin\\/\\d+\\/?/gi)?.forEach(addPinUrl);
        html.match(/(?:https?:)?\\/\\/i\\.pinimg\\.com\\/[^"'<>\\s,)\\\\]+/gi)?.forEach(addOriginalImageUrl);
        html.match(/srcset\\s*=\\s*(["'])(.*?)\\1/gim)?.forEach((attribute) => {
          const srcset = attribute.replace(/^srcset\\s*=\\s*["']|["']$/gi, "");
          srcset.split(",").forEach((entry) => {
            const url = entry.trim().split(/\\s+/)[0];
            if (url) addOriginalImageUrl(url);
          });
        });

        return `${pinUrls.size + originalImageUrls.size},${pinUrls.size},${originalImageUrls.size}`;
      })();
    JS

    def capture(url, progress: nil)
      script = apple_script(url)
      stdout, stderr, status = run_script(script, progress: progress)
      raise "Safari snapshot failed: #{stderr.strip}" unless status.success?

      payload = parse_script_output(stdout)
      Snapshot.new(
        url: payload.fetch("url"),
        body: payload.fetch("html"),
        urls: payload.fetch("urls")
      )
    rescue JSON::ParserError => e
      raise "Safari snapshot returned invalid data: #{e.message}"
    end

    private

    def parse_script_output(stdout)
      tab_marker, snapshot_json = stdout.split("\t", 2)
      @tab_marker = tab_marker unless tab_marker.to_s.empty?

      JSON.parse(snapshot_json)
    rescue TypeError
      JSON.parse(stdout)
    end

    def run_script(script, progress:)
      stdout_data = +""
      stderr_data = +""

      Open3.popen3("osascript", "-e", script) do |stdin, stdout, stderr, wait_thread|
        stdin.close

        stdout_thread = Thread.new { stdout_data = stdout.read }
        stderr_thread = Thread.new do
          stderr.each_line do |line|
            if line.start_with?(PROGRESS_PREFIX)
              progress&.call(line.delete_prefix(PROGRESS_PREFIX).strip)
            else
              stderr_data << line
            end
          end
        end

        stdout_thread.join
        stderr_thread.join

        [stdout_data, stderr_data, wait_thread.value]
      end
    end

    def apple_script(url)
      @tab_marker ||= "pinterest-scrapper-#{SecureRandom.uuid}"

      <<~APPLESCRIPT
        on pinterestScrapperSessionLocked()
          try
            set lockState to do shell script "/usr/sbin/ioreg -n Root -d1 2>/dev/null | /usr/bin/grep -E '\\\"CGSSessionScreenIsLocked\\\"[[:space:]]*=[[:space:]]*Yes' >/dev/null && echo locked || echo unlocked"
            return lockState is "locked"
          on error
            return false
          end try
        end pinterestScrapperSessionLocked

        on pinterestScrapperWaitUntilUnlocked()
          set reportedLocked to false

          repeat while pinterestScrapperSessionLocked()
            if reportedLocked is false then
              log #{(PROGRESS_PREFIX + "Machine is locked. Pausing until it is unlocked...").to_json}
              set reportedLocked to true
            end if

            delay #{SessionLock::CHECK_INTERVAL_SECONDS}
          end repeat

          if reportedLocked is true then
            log #{(PROGRESS_PREFIX + "Machine unlocked. Resuming...").to_json}
          end if
        end pinterestScrapperWaitUntilUnlocked

        pinterestScrapperWaitUntilUnlocked()
        log #{(PROGRESS_PREFIX + "opening Safari").to_json}

        set tabMarker to #{@tab_marker.to_json}

        tell application "Safari"
          activate
          if (count of windows) = 0 then
            make new document with properties {URL:#{url.to_s.to_json}}
            set targetWindow to front window
            set targetTab to current tab of targetWindow
          else
            set targetWindow to missing value
            set targetTab to missing value

            repeat with safariWindow in windows
              repeat with safariTab in tabs of safariWindow
                try
                  if (do JavaScript "window.name" in safariTab) is tabMarker then
                    set targetWindow to safariWindow
                    set targetTab to safariTab
                    exit repeat
                  end if
                end try
              end repeat

              if targetTab is not missing value then exit repeat
            end repeat

            if targetWindow is missing value then
              set targetWindow to front window
              set targetTab to current tab of targetWindow
            end if

            set current tab of targetWindow to targetTab
            set URL of targetTab to #{url.to_s.to_json}
          end if
        end tell

        delay #{WAIT_SECONDS}

        tell application "Safari"
          do JavaScript #{("window.name = #{@tab_marker.to_json}; window.__pinterestScrapperUrls = new Set();").to_json} in targetTab
        end tell

        set previousUrlCount to -1
        set stableScrollCount to 0
        set scrollNumber to 0

        repeat while stableScrollCount < #{STABLE_SCROLLS}
          pinterestScrapperWaitUntilUnlocked()
          set scrollNumber to scrollNumber + 1
          tell application "Safari"
            do JavaScript "window.scrollBy(0, Math.max(document.documentElement.clientHeight, 900));" in targetTab
          end tell
          delay #{SCROLL_WAIT_SECONDS}

          tell application "Safari"
            set currentProgressJson to do JavaScript #{URL_COUNT_JAVASCRIPT.to_json} in targetTab
          end tell

          set AppleScript's text item delimiters to ","
          set currentProgressParts to text items of currentProgressJson
          set AppleScript's text item delimiters to ""
          set currentUrlCount to item 1 of currentProgressParts as integer
          set currentPinCount to item 2 of currentProgressParts as integer
          set currentOriginalCount to item 3 of currentProgressParts as integer

          if currentUrlCount > previousUrlCount then
            set previousUrlCount to currentUrlCount
            set stableScrollCount to 0
          else
            set stableScrollCount to stableScrollCount + 1
          end if

          log #{PROGRESS_PREFIX.to_json} & "scroll " & scrollNumber & ": " & currentOriginalCount & " original image URLs, " & currentPinCount & " pin URLs, stable " & stableScrollCount & "/#{STABLE_SCROLLS}"
        end repeat

        pinterestScrapperWaitUntilUnlocked()
        log #{(PROGRESS_PREFIX + "creating final snapshot").to_json}

        tell application "Safari"
          set snapshotJson to do JavaScript #{SNAPSHOT_JAVASCRIPT.to_json} in targetTab
        end tell

        return tabMarker & tab & snapshotJson
      APPLESCRIPT
    end
  end
end
