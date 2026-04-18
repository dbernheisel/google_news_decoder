# GoogleNewsDecoder

Decode Google News redirect URLs to their original source URLs.

Google News wraps every article link in an encrypted redirect (`news.google.com/rss/articles/CBMi...`). This library resolves those back to the real URL by extracting decoding parameters from the article page and calling Google's internal `batchexecute` endpoint.

**Zero dependencies** — uses Erlang's built-in `:httpc` for HTTP and Elixir's built-in `JSON` module for encoding/decoding.

This library **does not avoid** rate-limiting or CAPTCHAs presented by Google.

## Installation

Add `google_news_decoder` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:google_news_decoder, "~> 0.1.0"}
  ]
end
```

## Quickstart

### Decode a Google News URL

```elixir
{:ok, url} = GoogleNewsDecoder.decode("https://news.google.com/rss/articles/CBMiK2h0dHBz...")
# {:ok, "https://www.reuters.com/world/..."}
```

### Resolve (decode or pass through)

If you have a mix of Google News and regular URLs, `resolve/1` handles both — it decodes Google News URLs and returns everything else unchanged:

```elixir
GoogleNewsDecoder.resolve("https://news.google.com/rss/articles/CBMiK2h0dHBz...")
# "https://www.reuters.com/world/..."

GoogleNewsDecoder.resolve("https://example.com/article")
# "https://example.com/article"
```

### Check if a URL is a Google News redirect

```elixir
GoogleNewsDecoder.google_news_url?("https://news.google.com/rss/articles/CBMi...")
# true

GoogleNewsDecoder.google_news_url?("https://example.com")
# false
```

### Batch decoding

Decode a list of URLs concurrently with `Task.async_stream/3`:

```elixir
urls
|> Task.async_stream(&GoogleNewsDecoder.resolve/1, max_concurrency: 5, timeout: 15_000)
|> Enum.map(fn {:ok, url} -> url end)
```

## API

| Function | Returns | Description |
|---|---|---|
| `decode/1` | `{:ok, url}` or `{:error, reason}` | Decode a Google News URL to its source |
| `resolve/1` | `url` | Decode if Google News, otherwise pass through |
| `google_news_url?/1` | `boolean` | Check if a URL is a Google News redirect |

## How it works

1. Extracts the base64-encoded article ID from the URL path
2. Fetches the Google News article page to obtain a signature (`data-n-a-sg`) and timestamp (`data-n-a-ts`)
3. POSTs those parameters to Google's `batchexecute` endpoint
4. Parses the nested JSON response to extract the original source URL

## Requirements

- Elixir ~> 1.18 (for the built-in `JSON` module)
- Erlang/OTP 25+ (for `:public_key.cacerts_get/0`)

## License

MIT License. See [LICENSE.md](LICENSE.md).
