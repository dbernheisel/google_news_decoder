defmodule GoogleNewsDecoder do
  @moduledoc File.read!("README.md")

  @timeout 10_000

  # Realistic browser headers to avoid bot detection
  @user_agent ~c"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

  # Page navigation headers (GET requests)
  @page_headers [
    {~c"user-agent", @user_agent},
    {~c"accept", ~c"text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"},
    {~c"accept-language", ~c"en-US,en;q=0.9"},
    {~c"sec-ch-ua",
     ~c"\"Google Chrome\";v=\"131\", \"Chromium\";v=\"131\", \"Not_A Brand\";v=\"24\""},
    {~c"sec-ch-ua-mobile", ~c"?0"},
    {~c"sec-ch-ua-platform", ~c"\"macOS\""},
    {~c"sec-fetch-dest", ~c"document"},
    {~c"sec-fetch-mode", ~c"navigate"},
    {~c"sec-fetch-site", ~c"none"},
    {~c"sec-fetch-user", ~c"?1"},
    {~c"upgrade-insecure-requests", ~c"1"}
  ]

  # XHR-style headers (POST to batchexecute)
  @xhr_headers [
    {~c"user-agent", @user_agent},
    {~c"accept", ~c"*/*"},
    {~c"accept-language", ~c"en-US,en;q=0.9"},
    {~c"sec-ch-ua",
     ~c"\"Google Chrome\";v=\"131\", \"Chromium\";v=\"131\", \"Not_A Brand\";v=\"24\""},
    {~c"sec-ch-ua-mobile", ~c"?0"},
    {~c"sec-ch-ua-platform", ~c"\"macOS\""},
    {~c"sec-fetch-dest", ~c"empty"},
    {~c"sec-fetch-mode", ~c"cors"},
    {~c"sec-fetch-site", ~c"same-origin"},
    {~c"origin", ~c"https://news.google.com"},
    {~c"referer", ~c"https://news.google.com/"},
    {~c"x-same-domain", ~c"1"}
  ]

  @doc """
  Resolves a URL, decoding it if it's a Google News redirect.

  Returns the original URL unchanged if it's not a Google News URL
  or if decoding fails.
  """
  @spec resolve(String.t()) :: String.t()
  def resolve(url) when is_binary(url) do
    if google_news_url?(url) do
      case decode(url) do
        {:ok, decoded} -> decoded
        {:error, _} -> url
      end
    else
      url
    end
  end

  @doc """
  Returns `true` if the URL is a Google News redirect URL.
  """
  @spec google_news_url?(term()) :: boolean()
  def google_news_url?(url) when is_binary(url) do
    uri = URI.parse(url)

    uri.host == "news.google.com" and
      String.match?(uri.path || "", ~r"/(articles|read)/")
  end

  def google_news_url?(_), do: false

  @doc """
  Decodes a Google News URL to its original source URL.

  Returns `{:ok, source_url}` or `{:error, reason}`.
  """
  @spec decode(String.t()) :: {:ok, String.t()} | {:error, term()}
  def decode(url) when is_binary(url) do
    with {:ok, article_id} <- extract_article_id(url),
         {:ok, signature, timestamp, cookies} <- fetch_decoding_params(article_id),
         {:ok, decoded_url} <- decode_via_batchexecute(article_id, signature, timestamp, cookies) do
      {:ok, decoded_url}
    end
  end

  defp extract_article_id(url) do
    uri = URI.parse(url)
    path = uri.path || ""

    case Regex.run(~r"/(articles|read)/([^/?]+)", path) do
      [_, _kind, article_id] -> {:ok, article_id}
      _ -> {:error, :invalid_google_news_url}
    end
  end

  # Cookie management

  defp seed_cookies do
    # Pre-seed Google consent cookie to bypass the consent gate
    ["CONSENT=PENDING+987"]
  end

  defp with_cookies(headers, []), do: headers

  defp with_cookies(headers, cookies) do
    [{~c"cookie", String.to_charlist(Enum.join(cookies, "; "))} | headers]
  end

  defp collect_cookies(response_headers, existing) do
    new =
      for {name, value} <- response_headers,
          List.to_string(name) |> String.downcase() == "set-cookie" do
        List.to_string(value) |> String.split(";", parts: 2) |> List.first() |> String.trim()
      end

    merge_cookies(existing, new)
  end

  defp merge_cookies(existing, new) do
    Map.merge(to_cookie_map(existing), to_cookie_map(new))
    |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)
  end

  defp to_cookie_map(cookies) do
    Map.new(cookies, fn cookie ->
      case String.split(cookie, "=", parts: 2) do
        [name, value] -> {name, value}
        [name] -> {name, ""}
      end
    end)
  end

  # HTTP requests

  defp fetch_decoding_params(article_id) do
    url = ~c"https://news.google.com/articles/#{article_id}"
    cookies = seed_cookies()
    headers = with_cookies(@page_headers, cookies)

    case :httpc.request(:get, {url, headers}, http_opts(), body_format: :binary) do
      {:ok, {{_, 200, _}, resp_headers, body}} when is_binary(body) ->
        cookies = collect_cookies(resp_headers, cookies)

        with {:ok, signature} <- extract_attr(body, "data-n-a-sg"),
             {:ok, timestamp} <- extract_attr(body, "data-n-a-ts") do
          {:ok, signature, timestamp, cookies}
        else
          _ -> {:error, :missing_decoding_params}
        end

      {:ok, {{_, status, _}, _headers, _body}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_attr(html, attr_name) do
    case Regex.run(~r/#{Regex.escape(attr_name)}="([^"]+)"/, html) do
      [_, value] -> {:ok, value}
      _ -> {:error, {:attr_not_found, attr_name}}
    end
  end

  defp decode_via_batchexecute(article_id, signature, timestamp, cookies) do
    url = ~c"https://news.google.com/_/DotsSplashUi/data/batchexecute"
    timestamp_int = String.to_integer(timestamp)

    inner_json =
      JSON.encode!([
        "garturlreq",
        [
          ["X", "X", ["X", "X"], nil, nil, 1, 1, "US:en", nil, 1, nil, nil, nil, nil, nil, 0, 1],
          "X",
          "X",
          1,
          [1, 1, 1],
          1,
          1,
          nil,
          0,
          0,
          nil,
          0
        ],
        article_id,
        timestamp_int,
        signature
      ])
      |> IO.iodata_to_binary()

    payload = JSON.encode!([[["Fbv4je", inner_json]]]) |> IO.iodata_to_binary()
    body = "f.req=#{URI.encode_www_form(payload)}"

    headers = with_cookies(@xhr_headers, cookies)
    content_type = ~c"application/x-www-form-urlencoded;charset=UTF-8"

    case :httpc.request(:post, {url, headers, content_type, body}, http_opts(),
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _headers, resp_body}} when is_binary(resp_body) ->
        parse_batchexecute_response(resp_body)

      {:ok, {{_, status, _}, _headers, _body}} ->
        {:error, {:batchexecute_http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_batchexecute_response(body) do
    # Response format: ")]}\n\n" prefix, then length-prefixed JSON chunks
    with [_, json_part] <- String.split(body, "\n\n", parts: 2),
         {:ok, parsed} <- json_decode(String.trim_trailing(json_part)),
         inner_json when is_binary(inner_json) <- get_in(parsed, [Access.at(0), Access.at(2)]),
         {:ok, inner} when is_list(inner) <- json_decode(inner_json),
         decoded_url when is_binary(decoded_url) <- Enum.at(inner, 1) do
      {:ok, decoded_url}
    else
      _ -> {:error, :failed_to_parse_batchexecute}
    end
  end

  defp json_decode(binary) do
    {:ok, JSON.decode!(binary)}
  rescue
    _ -> {:error, :invalid_json}
  end

  defp http_opts do
    [
      timeout: @timeout,
      autoredirect: true,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        depth: 3,
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    ]
  end
end
