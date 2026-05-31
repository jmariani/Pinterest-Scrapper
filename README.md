# Pinterest Scrapper

A small Ruby command-line app that accepts a target folder and a Pinterest URL.

## Usage

```sh
ruby bin/pinterest_scrapper ./downloads https://www.pinterest.com/pin/123456789/
```

The app validates that:

- exactly two parameters are provided
- the Pinterest URL uses `http` or `https`
- the URL host is `pinterest.com` or one of its subdomains

If the target folder does not exist, it will be created.

## Run Tests

```sh
ruby test/pinterest_scrapper_test.rb
```
