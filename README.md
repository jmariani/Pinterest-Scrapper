# Pinterest Scrapper

A small Ruby command-line app that accepts a target folder and a Pinterest URL.
It opens the Pinterest URL in Safari, scrolls the rendered page, collects pin
URLs and Pinterest image original URLs, saves the original images, then writes
the results to `url_manifest.json` and `pins_manifest.json` in the target
folder.
Original image URLs are collected from regular image URLs and `srcset`
attributes.
If multiple images resolve to the same filename, the downloader keeps the file
with the highest detected resolution.
Images are saved in a two-level folder structure using the filename prefix:
`00c5ca...jpg` is saved as `00/c5/00c5ca...jpg`.

The Safari collector keeps scrolling until the rendered page stops exposing new
original image URLs and pin URLs for several consecutive scrolls.
The first Safari capture marks its tab with a unique run id, and later pin
captures find and reuse that same marked tab for the rest of the run.
The app processes the unprocessed pins already present in `pins_manifest.json`.
Pins discovered during that pass are held aside, then appended to the manifest
as unprocessed only after the current manifest queue is finished.

While it runs, the command prints progress for each scroll with the original
image URL count, pin URL count, and current stable-scroll count.
During downloads, it also prints one progress line after each image attempt:
saved, replaced, skipped, or failed.
Images download in parallel with a 10-worker pool.
Pressing Ctrl-C requests a graceful stop. The app finishes the current safe
step, writes the manifests, and exits without an abort stack trace.

## Usage

```sh
ruby bin/pinterest_scrapper ./downloads https://www.pinterest.com/pin/123456789/
```

To resume from the first unprocessed pin in `pins_manifest.json`, omit the URL:

```sh
ruby bin/pinterest_scrapper ./downloads
```

If no manifest exists, or every pin in the manifest is already processed, the
app prompts for a Pinterest URL.

The app validates that:

- one or two parameters are provided
- the Pinterest URL uses `http` or `https`
- the URL host is `pinterest.com` or one of its subdomains

If the target folder does not exist, it will be created.

Safari may ask for permission to automate the browser. If collection falls back
to the initial HTML only, enable Safari's **Develop > Allow JavaScript from
Apple Events** setting and run the command again.

## Run Tests

```sh
ruby test/pinterest_scrapper_test.rb
```
