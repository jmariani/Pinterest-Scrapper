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

The Safari collector keeps scrolling until the rendered page stops exposing new
original image URLs and pin URLs for several consecutive scrolls.

While it runs, the command prints progress for each scroll with the original
image URL count, pin URL count, and current stable-scroll count.
During downloads, it also prints one progress line after each image attempt:
saved, replaced, skipped, or failed.

## Usage

```sh
ruby bin/pinterest_scrapper ./downloads https://www.pinterest.com/pin/123456789/
```

The app validates that:

- exactly two parameters are provided
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
