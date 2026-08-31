package main

import (
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

func testCodexToken(accountID string) string {
	header := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"none"}`))
	payload, _ := json.Marshal(map[string]any{
		"https://api.openai.com/auth": map[string]string{"chatgpt_account_id": accountID},
	})
	return header + "." + base64.RawURLEncoding.EncodeToString(payload) + ".signature"
}

func TestAuthorizationURL(t *testing.T) {
	tests := []struct {
		protocol string
		check    func(*testing.T, url.Values)
	}{
		{protocolCodex, func(t *testing.T, values url.Values) {
			if values.Get("client_id") != openAICodexClientID || values.Get("originator") != "niffler" {
				t.Fatalf("unexpected Codex authorization values: %v", values)
			}
			if values.Get("codex_cli_simplified_flow") != "true" {
				t.Fatalf("missing Codex simplified-flow flag: %v", values)
			}
		}},
		{protocolAnthropic, func(t *testing.T, values url.Values) {
			if values.Get("client_id") != anthropicClientID || values.Get("code") != "true" {
				t.Fatalf("unexpected Anthropic authorization values: %v", values)
			}
		}},
	}
	for _, test := range tests {
		t.Run(test.protocol, func(t *testing.T) {
			spec := defaultOAuthSpecs()[test.protocol]
			parsed, err := url.Parse(authorizationURL(spec, "verifier", "state"))
			if err != nil {
				t.Fatal(err)
			}
			values := parsed.Query()
			if values.Get("response_type") != "code" || values.Get("state") != "state" ||
				values.Get("code_challenge_method") != "S256" || values.Get("code_challenge") == "" {
				t.Fatalf("incomplete PKCE authorization URL: %v", values)
			}
			test.check(t, values)
		})
	}
}

func TestParseAuthorizationInput(t *testing.T) {
	for input, want := range map[string][2]string{
		"code-only": {"code-only", ""},
		"abc#state": {"abc", "state"},
		"http://localhost/callback?code=abc&state=state": {"abc", "state"},
		"code=abc&state=state":                           {"abc", "state"},
	} {
		code, state := parseAuthorizationInput(input)
		if code != want[0] || state != want[1] {
			t.Fatalf("parseAuthorizationInput(%q) = %q, %q; want %q, %q", input, code, state, want[0], want[1])
		}
	}
}

func TestOpenAIAccountID(t *testing.T) {
	if got := openAIAccountID(testCodexToken("account-123")); got != "account-123" {
		t.Fatalf("account id = %q", got)
	}
	if got := openAIAccountID("not-a-jwt"); got != "" {
		t.Fatalf("invalid JWT account id = %q", got)
	}
}

func TestOpenAIDeviceFlowAndTokenExchange(t *testing.T) {
	polls := 0
	access := testCodexToken("account-device")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/device/start":
			var body map[string]string
			_ = json.NewDecoder(r.Body).Decode(&body)
			if body["client_id"] != openAICodexClientID {
				t.Errorf("device client_id = %q", body["client_id"])
			}
			_ = json.NewEncoder(w).Encode(map[string]any{
				"device_auth_id": "device-id", "user_code": "ABCD-1234", "interval": "1",
			})
		case "/device/poll":
			polls++
			if polls == 1 {
				http.Error(w, `{"error":"deviceauth_authorization_pending"}`, http.StatusForbidden)
				return
			}
			_ = json.NewEncoder(w).Encode(map[string]string{
				"authorization_code": "auth-code", "code_verifier": "device-verifier",
			})
		case "/token":
			data, _ := io.ReadAll(r.Body)
			values, _ := url.ParseQuery(string(data))
			if values.Get("code") != "auth-code" || values.Get("code_verifier") != "device-verifier" ||
				values.Get("redirect_uri") != "https://example.test/device/callback" {
				t.Errorf("bad exchange form: %v", values)
			}
			_ = json.NewEncoder(w).Encode(map[string]any{
				"access_token": access, "refresh_token": "refresh-token", "expires_in": 3600,
			})
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	manager := newOAuthManager(nil, nil)
	manager.client = server.Client()
	manager.now = func() time.Time { return time.Unix(1000, 0) }
	spec := defaultOAuthSpecs()[protocolCodex]
	spec.DeviceUserCodeURL = server.URL + "/device/start"
	spec.DeviceTokenURL = server.URL + "/device/poll"
	spec.DeviceRedirectURI = "https://example.test/device/callback"
	spec.TokenURL = server.URL + "/token"

	device, err := manager.startDevice(spec)
	if err != nil {
		t.Fatal(err)
	}
	if device.DeviceAuthID != "device-id" || device.UserCode != "ABCD-1234" || device.Interval != time.Second {
		t.Fatalf("device start = %+v", device)
	}
	flow := &oauthFlow{DeviceAuthID: device.DeviceAuthID, UserCode: device.UserCode, PollInterval: device.Interval}
	if _, _, pending, retry, err := manager.pollDevice(spec, flow); err != nil || !pending || retry != time.Second {
		t.Fatalf("first poll: pending=%v retry=%v err=%v", pending, retry, err)
	}
	code, verifier, pending, _, err := manager.pollDevice(spec, flow)
	if err != nil || pending || code != "auth-code" || verifier != "device-verifier" {
		t.Fatalf("second poll: code=%q verifier=%q pending=%v err=%v", code, verifier, pending, err)
	}
	credential, err := manager.exchange(spec, code, "state", verifier, spec.DeviceRedirectURI)
	if err != nil {
		t.Fatal(err)
	}
	if credential.Access != access || credential.Refresh != "refresh-token" ||
		credential.AccountID != "account-device" || credential.Expires != time.Unix(4600, 0).UnixMilli() {
		t.Fatalf("credential = %+v", credential)
	}
}

func TestAnthropicRefreshUsesJSONWithoutScope(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Content-Type") != "application/json" {
			t.Errorf("content type = %q", r.Header.Get("Content-Type"))
		}
		var body map[string]string
		_ = json.NewDecoder(r.Body).Decode(&body)
		if body["grant_type"] != "refresh_token" || body["refresh_token"] != "old-refresh" ||
			body["client_id"] != anthropicClientID {
			t.Errorf("refresh body = %#v", body)
		}
		if _, exists := body["scope"]; exists {
			t.Errorf("Anthropic refresh must omit scope: %#v", body)
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"access_token": "new-access", "refresh_token": "new-refresh", "expires_in": 1800,
		})
	}))
	defer server.Close()

	manager := newOAuthManager(nil, nil)
	manager.client = server.Client()
	manager.now = func() time.Time { return time.Unix(2000, 0) }
	spec := defaultOAuthSpecs()[protocolAnthropic]
	spec.TokenURL = server.URL
	credential, err := manager.refresh(spec, "old-refresh")
	if err != nil {
		t.Fatal(err)
	}
	if credential.Access != "new-access" || credential.Refresh != "new-refresh" ||
		credential.Expires != time.Unix(3800, 0).UnixMilli() {
		t.Fatalf("credential = %+v", credential)
	}
}

func TestValidStoredProvider(t *testing.T) {
	oauth := Provider{
		Nickname: "codex", AuthType: authOAuth, Protocol: protocolCodex,
		OAuth: &OAuthCredential{Access: "access", Refresh: "refresh", Expires: 1},
	}.withDefaults()
	if !validStoredProvider(oauth) {
		t.Fatal("valid OAuth provider rejected")
	}
	api := Provider{Nickname: "deepseek", APIKey: "key"}.withDefaults()
	if !validStoredProvider(api) {
		t.Fatal("legacy API-key provider rejected")
	}
	api.Protocol = protocolCodex
	if validStoredProvider(api) {
		t.Fatal("Codex must not accept a plain API-key provider")
	}
}

func TestOAuthHTTPErrorIsBounded(t *testing.T) {
	err := oauthHTTPError("exchange", 400, []byte(strings.Repeat("x", 2000)))
	if len(err.Error()) > 1100 || !strings.Contains(err.Error(), "HTTP 400") {
		t.Fatalf("unexpected error: %s", err)
	}
}
