defmodule GoogleNewsDecoderTest do
  use ExUnit.Case
  use Mimic

  @article_id "CBMic0FVX3lxTFB5ZTVlM08yaWhJRXU5eHdLX243N2xyLVN5UVZVQTdJcEFkems4UmVzZEZ2VGJCZGJtU1UzYkJpTHU3LWo3NXViWEF5ZXZnLVUxYk84YlBxazlyQ0dEbmpZVW15VzhGNzczaTFseElySXQxZmc"
  @articles_url "https://news.google.com/rss/articles/#{@article_id}"
  @read_url "https://news.google.com/read/#{@article_id}?hl=en-US&gl=US&ceid=US%3Aen"
  @source_url "https://www.reuters.com/world/us/some-article-2026"

  @signature "ABC123_signature"
  @timestamp "1713456789"

  @article_html """
  <html><body>
  <c-wiz data-n-a-sg="#{@signature}" data-n-a-ts="#{@timestamp}">
  <div class="content">Article content</div>
  </c-wiz>
  </body></html>
  """

  @batchexecute_response ")]}'\n\n" <>
                           (JSON.encode!([
                              [
                                "wrb.fr",
                                "Fbv4je",
                                JSON.encode!(["garturlres", @source_url])
                                |> IO.iodata_to_binary()
                              ]
                            ])
                            |> IO.iodata_to_binary())

  # Simulate Google setting cookies on the article page response
  @response_cookies [
    {~c"set-cookie",
     ~c"NID=abc123; expires=Sat, 19-Apr-2027 00:00:00 GMT; path=/; domain=.google.com; HttpOnly"},
    {~c"set-cookie",
     ~c"AEC=xyz789; expires=Sat, 19-Oct-2026 00:00:00 GMT; path=/; domain=.google.com"}
  ]

  defp stub_success(_context) do
    stub(:httpc, :request, fn
      :get, {_url, _headers}, _http_opts, _opts ->
        {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, @response_cookies, @article_html}}

      :post, {_url, _headers, _content_type, _body}, _http_opts, _opts ->
        {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], @batchexecute_response}}
    end)

    :ok
  end

  defp find_header(headers, name) do
    Enum.find_value(headers, fn {k, v} -> List.to_string(k) == name && List.to_string(v) end)
  end

  describe "google_news_url?/1" do
    test "recognizes /rss/articles/ URLs" do
      assert GoogleNewsDecoder.google_news_url?(@articles_url)
    end

    test "recognizes /read/ URLs" do
      assert GoogleNewsDecoder.google_news_url?(@read_url)
    end

    test "recognizes /articles/ without rss prefix" do
      assert GoogleNewsDecoder.google_news_url?("https://news.google.com/articles/#{@article_id}")
    end

    test "rejects non-Google News URLs" do
      refute GoogleNewsDecoder.google_news_url?("https://example.com/articles/foo")
    end

    test "rejects Google News URLs without article path" do
      refute GoogleNewsDecoder.google_news_url?("https://news.google.com/home")
      refute GoogleNewsDecoder.google_news_url?("https://news.google.com/search?q=test")
    end

    test "handles non-string input" do
      refute GoogleNewsDecoder.google_news_url?(nil)
      refute GoogleNewsDecoder.google_news_url?(123)
      refute GoogleNewsDecoder.google_news_url?(%{})
    end
  end

  describe "decode/1" do
    setup :stub_success

    test "decodes an /rss/articles/ URL to its source" do
      assert {:ok, @source_url} = GoogleNewsDecoder.decode(@articles_url)
    end

    test "decodes a /read/ URL to its source" do
      assert {:ok, @source_url} = GoogleNewsDecoder.decode(@read_url)
    end

    test "sends GET to the articles endpoint with the article ID" do
      expect(:httpc, :request, fn :get, {url, _headers}, _http_opts, _opts ->
        assert url == ~c"https://news.google.com/articles/#{@article_id}"
        {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, @response_cookies, @article_html}}
      end)

      expect(:httpc, :request, fn :post, _, _, _ ->
        {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], @batchexecute_response}}
      end)

      assert {:ok, _} = GoogleNewsDecoder.decode(@articles_url)
    end

    test "sends realistic browser headers on GET" do
      expect(:httpc, :request, fn :get, {_url, headers}, _, _ ->
        ua = find_header(headers, "user-agent")
        assert ua =~ "Chrome/"
        assert ua =~ "AppleWebKit"

        assert find_header(headers, "sec-fetch-dest") == "document"
        assert find_header(headers, "sec-fetch-mode") == "navigate"
        assert find_header(headers, "upgrade-insecure-requests") == "1"

        {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, @response_cookies, @article_html}}
      end)

      expect(:httpc, :request, fn :post, _, _, _ ->
        {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], @batchexecute_response}}
      end)

      assert {:ok, _} = GoogleNewsDecoder.decode(@articles_url)
    end

    test "sends XHR-style headers on POST with origin and referer" do
      expect(:httpc, :request, fn :get, _, _, _ ->
        {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, @response_cookies, @article_html}}
      end)

      expect(:httpc, :request, fn :post, {_url, headers, _ct, _body}, _, _ ->
        assert find_header(headers, "sec-fetch-dest") == "empty"
        assert find_header(headers, "sec-fetch-mode") == "cors"
        assert find_header(headers, "sec-fetch-site") == "same-origin"
        assert find_header(headers, "origin") == "https://news.google.com"
        assert find_header(headers, "referer") == "https://news.google.com/"
        assert find_header(headers, "x-same-domain") == "1"

        {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], @batchexecute_response}}
      end)

      assert {:ok, _} = GoogleNewsDecoder.decode(@articles_url)
    end

    test "seeds CONSENT cookie on the initial GET" do
      expect(:httpc, :request, fn :get, {_url, headers}, _, _ ->
        cookie = find_header(headers, "cookie")
        assert cookie =~ "CONSENT=PENDING+987"

        {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, @response_cookies, @article_html}}
      end)

      expect(:httpc, :request, fn :post, _, _, _ ->
        {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], @batchexecute_response}}
      end)

      assert {:ok, _} = GoogleNewsDecoder.decode(@articles_url)
    end

    test "collects Set-Cookie from GET and forwards to POST" do
      expect(:httpc, :request, fn :get, _, _, _ ->
        {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, @response_cookies, @article_html}}
      end)

      expect(:httpc, :request, fn :post, {_url, headers, _ct, _body}, _, _ ->
        cookie = find_header(headers, "cookie")
        # Seed cookie carried forward
        assert cookie =~ "CONSENT="
        # Cookies collected from GET response
        assert cookie =~ "NID=abc123"
        assert cookie =~ "AEC=xyz789"

        {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], @batchexecute_response}}
      end)

      assert {:ok, @source_url} = GoogleNewsDecoder.decode(@articles_url)
    end

    test "sends POST to batchexecute with signature, timestamp, and article ID" do
      expect(:httpc, :request, fn :get, _, _, _ ->
        {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, @response_cookies, @article_html}}
      end)

      expect(:httpc, :request, fn :post, {url, _headers, content_type, body}, _, _ ->
        assert url == ~c"https://news.google.com/_/DotsSplashUi/data/batchexecute"
        assert content_type == ~c"application/x-www-form-urlencoded;charset=UTF-8"

        decoded_body = URI.decode_www_form(String.replace(body, "f.req=", ""))
        assert decoded_body =~ @article_id
        assert decoded_body =~ @signature
        assert decoded_body =~ @timestamp

        {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], @batchexecute_response}}
      end)

      assert {:ok, @source_url} = GoogleNewsDecoder.decode(@articles_url)
    end

    test "returns error when article page returns non-200" do
      expect(:httpc, :request, fn :get, _, _, _ ->
        {:ok, {{~c"HTTP/1.1", 403, ~c"Forbidden"}, [], "blocked"}}
      end)

      assert {:error, {:http_error, 403}} = GoogleNewsDecoder.decode(@articles_url)
    end

    test "returns error when article page returns 429" do
      expect(:httpc, :request, fn :get, _, _, _ ->
        {:ok, {{~c"HTTP/1.1", 429, ~c"Too Many Requests"}, [], "rate limited"}}
      end)

      assert {:error, {:http_error, 429}} = GoogleNewsDecoder.decode(@articles_url)
    end

    test "returns error when GET request fails" do
      expect(:httpc, :request, fn :get, _, _, _ ->
        {:error, :timeout}
      end)

      assert {:error, :timeout} = GoogleNewsDecoder.decode(@articles_url)
    end

    test "returns error when signature attribute is missing" do
      expect(:httpc, :request, fn :get, _, _, _ ->
        {:ok,
         {{~c"HTTP/1.1", 200, ~c"OK"}, [],
          "<html><body><c-wiz data-n-a-ts=\"123\"></c-wiz></body></html>"}}
      end)

      assert {:error, :missing_decoding_params} = GoogleNewsDecoder.decode(@articles_url)
    end

    test "returns error when timestamp attribute is missing" do
      expect(:httpc, :request, fn :get, _, _, _ ->
        {:ok,
         {{~c"HTTP/1.1", 200, ~c"OK"}, [],
          "<html><body><c-wiz data-n-a-sg=\"sig123\"></c-wiz></body></html>"}}
      end)

      assert {:error, :missing_decoding_params} = GoogleNewsDecoder.decode(@articles_url)
    end

    test "returns error when batchexecute returns non-200" do
      expect(:httpc, :request, fn :get, _, _, _ ->
        {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, @response_cookies, @article_html}}
      end)

      expect(:httpc, :request, fn :post, _, _, _ ->
        {:ok, {{~c"HTTP/1.1", 500, ~c"Internal Server Error"}, [], "error"}}
      end)

      assert {:error, {:batchexecute_http_error, 500}} = GoogleNewsDecoder.decode(@articles_url)
    end

    test "returns error when batchexecute POST fails" do
      expect(:httpc, :request, fn :get, _, _, _ ->
        {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, @response_cookies, @article_html}}
      end)

      expect(:httpc, :request, fn :post, _, _, _ ->
        {:error,
         {:failed_connect,
          [{:to_address, {~c"news.google.com", 443}}, {:inet, [:inet], :nxdomain}]}}
      end)

      assert {:error, {:failed_connect, _}} = GoogleNewsDecoder.decode(@articles_url)
    end

    test "returns error when batchexecute response has no URL" do
      bad_response =
        ")]}'\n\n" <> (JSON.encode!([["wrb.fr", "Fbv4je", "null"]]) |> IO.iodata_to_binary())

      expect(:httpc, :request, fn :get, _, _, _ ->
        {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, @response_cookies, @article_html}}
      end)

      expect(:httpc, :request, fn :post, _, _, _ ->
        {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], bad_response}}
      end)

      assert {:error, :failed_to_parse_batchexecute} = GoogleNewsDecoder.decode(@articles_url)
    end

    test "returns error when batchexecute response is malformed JSON" do
      expect(:httpc, :request, fn :get, _, _, _ ->
        {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, @response_cookies, @article_html}}
      end)

      expect(:httpc, :request, fn :post, _, _, _ ->
        {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], ")]}'\n\nnot json at all"}}
      end)

      assert {:error, :failed_to_parse_batchexecute} = GoogleNewsDecoder.decode(@articles_url)
    end

    test "returns error for a non-Google News URL" do
      assert {:error, :invalid_google_news_url} =
               GoogleNewsDecoder.decode("https://example.com/article")
    end
  end

  describe "resolve/1" do
    setup :stub_success

    test "decodes Google News URLs to their source" do
      assert @source_url == GoogleNewsDecoder.resolve(@articles_url)
    end

    test "decodes /read/ URLs to their source" do
      assert @source_url == GoogleNewsDecoder.resolve(@read_url)
    end

    test "returns non-Google News URLs unchanged" do
      plain = "https://example.com/article"
      assert plain == GoogleNewsDecoder.resolve(plain)
    end

    test "returns original URL on decode failure" do
      expect(:httpc, :request, fn :get, _, _, _ ->
        {:error, :timeout}
      end)

      assert @articles_url == GoogleNewsDecoder.resolve(@articles_url)
    end
  end
end
