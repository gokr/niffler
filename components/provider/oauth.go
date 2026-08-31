package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	sdk "niffler.dev/sdk"
)

const (
	openAICodexClientID = "app_EMoamEEZ73f0CkXaXp7hrann"
	anthropicClientID   = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

	oauthFlowLifetime = 15 * time.Minute
	oauthRefreshAhead = 5 * time.Minute
	maxOAuthBody      = 1 << 20
)

type oauthSpec struct {
	Protocol          string
	Name              string
	ClientID          string
	AuthorizeURL      string
	TokenURL          string
	RedirectURI       string
	CallbackHost      string
	CallbackPort      int
	CallbackPath      string
	Scopes            string
	DeviceUserCodeURL string
	DeviceTokenURL    string
	DeviceVerifyURL   string
	DeviceRedirectURI string
}

func defaultOAuthSpecs() map[string]oauthSpec {
	callbackHost := strings.TrimSpace(os.Getenv("NIF_OAUTH_CALLBACK_HOST"))
	if callbackHost == "" {
		callbackHost = "127.0.0.1"
	}
	return map[string]oauthSpec{
		protocolCodex: {
			Protocol:          protocolCodex,
			Name:              "OpenAI Codex (ChatGPT Plus/Pro)",
			ClientID:          openAICodexClientID,
			AuthorizeURL:      "https://auth.openai.com/oauth/authorize",
			TokenURL:          "https://auth.openai.com/oauth/token",
			RedirectURI:       "http://localhost:1455/auth/callback",
			CallbackHost:      callbackHost,
			CallbackPort:      1455,
			CallbackPath:      "/auth/callback",
			Scopes:            "openid profile email offline_access",
			DeviceUserCodeURL: "https://auth.openai.com/api/accounts/deviceauth/usercode",
			DeviceTokenURL:    "https://auth.openai.com/api/accounts/deviceauth/token",
			DeviceVerifyURL:   "https://auth.openai.com/codex/device",
			DeviceRedirectURI: "https://auth.openai.com/deviceauth/callback",
		},
		protocolAnthropic: {
			Protocol:     protocolAnthropic,
			Name:         "Anthropic (Claude Pro/Max)",
			ClientID:     anthropicClientID,
			AuthorizeURL: "https://claude.ai/oauth/authorize",
			TokenURL:     "https://platform.claude.com/v1/oauth/token",
			RedirectURI:  "http://localhost:53692/callback",
			CallbackHost: callbackHost,
			CallbackPort: 53692,
			CallbackPath: "/callback",
			Scopes: "org:create_api_key user:profile user:inference " +
				"user:sessions:claude_code user:mcp_servers user:file_upload",
		},
	}
}

type oauthFlow struct {
	ID                string
	Protocol          string
	Method            string
	Nickname          string
	Model             string
	Active            bool
	Verifier          string
	State             string
	CreatedAt         time.Time
	ExpiresAt         time.Time
	Code              string
	CallbackError     string
	DeviceAuthID      string
	UserCode          string
	PollInterval      time.Duration
	NextPoll          time.Time
	CallbackServer    *http.Server
	CallbackAvailable bool
}

type oauthManager struct {
	mu     sync.Mutex
	flows  map[string]*oauthFlow
	specs  map[string]oauthSpec
	client *http.Client
	sc     *storeClient
	comp   *sdk.Component
	now    func() time.Time
	randID func() (string, error)
}

func newOAuthManager(sc *storeClient, comp *sdk.Component) *oauthManager {
	return &oauthManager{
		flows:  make(map[string]*oauthFlow),
		specs:  defaultOAuthSpecs(),
		client: &http.Client{Timeout: 30 * time.Second},
		sc:     sc,
		comp:   comp,
		now:    time.Now,
		randID: randomBase64URL,
	}
}

func (m *oauthManager) registerTools() {
	m.comp.Tool("provider_oauth_start", map[string]any{
		"type":        "object",
		"description": "Start a ChatGPT or Claude subscription OAuth login. Interactive clients open the returned URL, then poll provider_oauth_complete.",
		"properties": map[string]any{
			"protocol": map[string]any{"type": "string", "enum": []string{protocolCodex, protocolAnthropic}},
			"method":   map[string]any{"type": "string", "enum": []string{"browser", "device"}, "description": "OpenAI supports browser or device; Anthropic supports browser"},
			"nickname": map[string]any{"type": "string", "description": "Stored provider nickname (defaults to the protocol name)"},
			"model":    map[string]any{"type": "string", "description": "Optional default model"},
			"active":   map[string]any{"type": "boolean", "description": "Make active after login (default true)"},
		},
		"required":  []string{"protocol"},
		"x-harness": map[string]any{"hidden": true, "timeoutMs": 30000},
	}, func(_ *sdk.Component, raw json.RawMessage) (any, error) {
		var args struct {
			Protocol string `json:"protocol"`
			Method   string `json:"method"`
			Nickname string `json:"nickname"`
			Model    string `json:"model"`
			Active   *bool  `json:"active"`
		}
		if err := decodeArgs(raw, &args); err != nil {
			return nil, err
		}
		return m.start(args.Protocol, args.Method, args.Nickname, args.Model, args.Active)
	})

	m.comp.Tool("provider_oauth_complete", map[string]any{
		"type":        "object",
		"description": "Poll an OAuth login and store the provider when authorization finishes. A redirect URL or code can be supplied when the local callback is unavailable.",
		"properties": map[string]any{
			"flowId": map[string]any{"type": "string"},
			"code":   map[string]any{"type": "string", "description": "Optional authorization code, code#state, or full redirect URL"},
		},
		"required":  []string{"flowId"},
		"x-harness": map[string]any{"hidden": true, "timeoutMs": 30000},
	}, func(_ *sdk.Component, raw json.RawMessage) (any, error) {
		var args struct {
			FlowID string `json:"flowId"`
			Code   string `json:"code"`
		}
		if err := decodeArgs(raw, &args); err != nil {
			return nil, err
		}
		return m.complete(strings.TrimSpace(args.FlowID), args.Code)
	})

	m.comp.Tool("provider_oauth_cancel", map[string]any{
		"type":        "object",
		"description": "Cancel a pending provider OAuth login and close its callback listener.",
		"properties":  map[string]any{"flowId": map[string]any{"type": "string"}},
		"required":    []string{"flowId"},
		"x-harness":   map[string]any{"hidden": true, "timeoutMs": 10000},
	}, func(_ *sdk.Component, raw json.RawMessage) (any, error) {
		var args struct {
			FlowID string `json:"flowId"`
		}
		if err := decodeArgs(raw, &args); err != nil {
			return nil, err
		}
		return map[string]any{"ok": m.cancel(strings.TrimSpace(args.FlowID))}, nil
	})
}

func (m *oauthManager) start(protocol, method, nickname, model string, active *bool) (map[string]any, error) {
	spec, ok := m.specs[strings.TrimSpace(protocol)]
	if !ok {
		return nil, errors.New("protocol must be openai-codex or anthropic")
	}
	method = strings.TrimSpace(method)
	if method == "" {
		method = "browser"
	}
	if method != "browser" && method != "device" {
		return nil, errors.New("method must be browser or device")
	}
	if method == "device" && spec.DeviceUserCodeURL == "" {
		return nil, fmt.Errorf("%s does not support device login", spec.Name)
	}
	nickname = strings.TrimSpace(nickname)
	if nickname == "" {
		nickname = protocol
	}
	if nickname == activeID {
		return nil, errors.New("reserved nickname")
	}

	flowID, err := m.randID()
	if err != nil {
		return nil, fmt.Errorf("create OAuth flow id: %w", err)
	}
	verifier, err := randomBase64URL()
	if err != nil {
		return nil, fmt.Errorf("create PKCE verifier: %w", err)
	}
	state, err := randomBase64URL()
	if err != nil {
		return nil, fmt.Errorf("create OAuth state: %w", err)
	}
	if protocol == protocolAnthropic {
		// Anthropic's current Claude Code flow uses the verifier as state.
		state = verifier
	}
	now := m.now()
	m.pruneExpired(now)
	m.cancelBrowserFlows(protocol)
	flow := &oauthFlow{
		ID: flowID, Protocol: protocol, Method: method,
		Nickname: nickname, Model: strings.TrimSpace(model),
		Active:   active == nil || *active,
		Verifier: verifier, State: state, CreatedAt: now,
		ExpiresAt: now.Add(oauthFlowLifetime), PollInterval: 5 * time.Second,
	}

	result := map[string]any{
		"ok": true, "flowId": flow.ID, "protocol": protocol,
		"provider": spec.Name, "method": method,
		"expiresAt": flow.ExpiresAt.UnixMilli(),
	}
	if method == "device" {
		device, err := m.startDevice(spec)
		if err != nil {
			return nil, err
		}
		flow.DeviceAuthID = device.DeviceAuthID
		flow.UserCode = device.UserCode
		flow.PollInterval = device.Interval
		flow.NextPoll = now
		result["url"] = spec.DeviceVerifyURL
		result["userCode"] = device.UserCode
		result["intervalMs"] = device.Interval.Milliseconds()
		result["callbackAvailable"] = false
	} else {
		result["url"] = authorizationURL(spec, verifier, state)
		available := m.startCallback(flow, spec)
		flow.CallbackAvailable = available
		result["callbackAvailable"] = available
	}

	m.mu.Lock()
	m.flows[flow.ID] = flow
	m.mu.Unlock()
	return result, nil
}

type deviceStart struct {
	DeviceAuthID string
	UserCode     string
	Interval     time.Duration
}

func (m *oauthManager) startDevice(spec oauthSpec) (deviceStart, error) {
	body, _ := json.Marshal(map[string]string{"client_id": spec.ClientID})
	response, data, err := m.do(context.Background(), http.MethodPost, spec.DeviceUserCodeURL,
		"application/json", body)
	if err != nil {
		return deviceStart{}, fmt.Errorf("start %s device login: %w", spec.Name, err)
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return deviceStart{}, oauthHTTPError("device code request", response.StatusCode, data)
	}
	var decoded struct {
		DeviceAuthID string          `json:"device_auth_id"`
		UserCode     string          `json:"user_code"`
		Interval     json.RawMessage `json:"interval"`
	}
	if err := json.Unmarshal(data, &decoded); err != nil {
		return deviceStart{}, fmt.Errorf("decode device code response: %w", err)
	}
	seconds := 5.0
	if len(decoded.Interval) > 0 {
		var number float64
		if json.Unmarshal(decoded.Interval, &number) != nil {
			var text string
			if json.Unmarshal(decoded.Interval, &text) == nil {
				number, _ = strconv.ParseFloat(strings.TrimSpace(text), 64)
			}
		}
		if number > 0 {
			seconds = number
		}
	}
	if decoded.DeviceAuthID == "" || decoded.UserCode == "" {
		return deviceStart{}, errors.New("device code response is missing fields")
	}
	return deviceStart{
		DeviceAuthID: decoded.DeviceAuthID,
		UserCode:     decoded.UserCode,
		Interval:     time.Duration(seconds * float64(time.Second)),
	}, nil
}

func authorizationURL(spec oauthSpec, verifier, state string) string {
	challengeBytes := sha256.Sum256([]byte(verifier))
	challenge := base64.RawURLEncoding.EncodeToString(challengeBytes[:])
	values := url.Values{
		"response_type":         {"code"},
		"client_id":             {spec.ClientID},
		"redirect_uri":          {spec.RedirectURI},
		"scope":                 {spec.Scopes},
		"code_challenge":        {challenge},
		"code_challenge_method": {"S256"},
		"state":                 {state},
	}
	if spec.Protocol == protocolCodex {
		values.Set("id_token_add_organizations", "true")
		values.Set("codex_cli_simplified_flow", "true")
		values.Set("originator", "niffler")
	} else if spec.Protocol == protocolAnthropic {
		values.Set("code", "true")
	}
	return spec.AuthorizeURL + "?" + values.Encode()
}

func (m *oauthManager) startCallback(flow *oauthFlow, spec oauthSpec) bool {
	address := net.JoinHostPort(spec.CallbackHost, strconv.Itoa(spec.CallbackPort))
	listener, err := net.Listen("tcp", address)
	if err != nil {
		return false
	}
	server := &http.Server{ReadHeaderTimeout: 5 * time.Second}
	server.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != spec.CallbackPath {
			oauthPage(w, http.StatusNotFound, "OAuth callback route not found", false)
			return
		}
		if oauthErr := r.URL.Query().Get("error"); oauthErr != "" {
			detail := r.URL.Query().Get("error_description")
			if detail == "" {
				detail = oauthErr
			}
			m.setCallbackError(flow.ID, detail)
			oauthPage(w, http.StatusBadRequest, detail, false)
			go closeOAuthServer(server)
			return
		}
		code := r.URL.Query().Get("code")
		state := r.URL.Query().Get("state")
		if code == "" || state != flow.State {
			oauthPage(w, http.StatusBadRequest, "Missing authorization code or OAuth state mismatch", false)
			return
		}
		m.setCallbackCode(flow.ID, code)
		oauthPage(w, http.StatusOK, "Authentication completed. You can close this window.", true)
		go closeOAuthServer(server)
	})
	flow.CallbackServer = server
	go func() {
		if err := server.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
			m.setCallbackError(flow.ID, err.Error())
		}
	}()
	return true
}

func oauthPage(w http.ResponseWriter, status int, message string, success bool) {
	color := "#ef4444"
	title := "Authentication failed"
	if success {
		color = "#22c55e"
		title = "Authentication complete"
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(status)
	_, _ = fmt.Fprintf(w, `<!doctype html><html><body style="font:16px system-ui;background:#111827;color:#e5e7eb;padding:3rem"><h1 style="color:%s">%s</h1><p>%s</p></body></html>`,
		color, html.EscapeString(title), html.EscapeString(message))
}

func (m *oauthManager) setCallbackCode(flowID, code string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if flow := m.flows[flowID]; flow != nil {
		flow.Code = code
	}
}

func (m *oauthManager) setCallbackError(flowID, message string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if flow := m.flows[flowID]; flow != nil {
		flow.CallbackError = message
	}
}

func (m *oauthManager) complete(flowID, manualInput string) (map[string]any, error) {
	if flowID == "" {
		return nil, errors.New("flowId required")
	}
	now := m.now()
	m.pruneExpired(now)
	m.mu.Lock()
	flow := m.flows[flowID]
	if flow == nil {
		m.mu.Unlock()
		return nil, errors.New("OAuth flow not found or expired")
	}
	spec := m.specs[flow.Protocol]
	if strings.TrimSpace(manualInput) != "" {
		code, state := parseAuthorizationInput(manualInput)
		if state != "" && state != flow.State {
			m.mu.Unlock()
			return nil, errors.New("OAuth state mismatch")
		}
		flow.Code = code
	}
	callbackError := flow.CallbackError
	code := flow.Code
	method := flow.Method
	nextPoll := flow.NextPoll
	m.mu.Unlock()

	if callbackError != "" {
		m.cancel(flowID)
		return nil, fmt.Errorf("OAuth callback failed: %s", callbackError)
	}
	redirectURI := spec.RedirectURI
	verifier := flow.Verifier
	if method == "device" && code == "" {
		if now.Before(nextPoll) {
			return pendingOAuthResult(flow, nextPoll.Sub(now)), nil
		}
		deviceCode, deviceVerifier, pending, retryAfter, err := m.pollDevice(spec, flow)
		if err != nil {
			m.cancel(flowID)
			return nil, err
		}
		if pending {
			m.mu.Lock()
			if current := m.flows[flowID]; current != nil {
				current.NextPoll = m.now().Add(retryAfter)
			}
			m.mu.Unlock()
			return pendingOAuthResult(flow, retryAfter), nil
		}
		code = deviceCode
		verifier = deviceVerifier
		redirectURI = spec.DeviceRedirectURI
	}
	if code == "" {
		return pendingOAuthResult(flow, time.Second), nil
	}

	credential, err := m.exchange(spec, code, flow.State, verifier, redirectURI)
	if err != nil {
		m.cancel(flowID)
		return nil, err
	}
	provider, err := m.storeOAuthProvider(flow, credential)
	if err != nil {
		m.cancel(flowID)
		return nil, err
	}
	m.cancel(flowID)
	return map[string]any{
		"ok": true, "pending": false, "active": provider.Active,
		"provider": provider,
	}, nil
}

func pendingOAuthResult(flow *oauthFlow, retryAfter time.Duration) map[string]any {
	if retryAfter < 250*time.Millisecond {
		retryAfter = 250 * time.Millisecond
	}
	return map[string]any{
		"ok": true, "pending": true, "flowId": flow.ID,
		"retryAfterMs": retryAfter.Milliseconds(),
	}
}

func (m *oauthManager) pollDevice(spec oauthSpec, flow *oauthFlow) (string, string, bool, time.Duration, error) {
	body, _ := json.Marshal(map[string]string{
		"device_auth_id": flow.DeviceAuthID,
		"user_code":      flow.UserCode,
	})
	response, data, err := m.do(context.Background(), http.MethodPost, spec.DeviceTokenURL,
		"application/json", body)
	if err != nil {
		return "", "", false, 0, fmt.Errorf("poll device login: %w", err)
	}
	if response.StatusCode == http.StatusForbidden || response.StatusCode == http.StatusNotFound {
		return "", "", true, flow.PollInterval, nil
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		var oauthErr struct {
			Error any `json:"error"`
		}
		_ = json.Unmarshal(data, &oauthErr)
		if strings.Contains(string(data), "authorization_pending") {
			return "", "", true, flow.PollInterval, nil
		}
		if strings.Contains(string(data), "slow_down") {
			return "", "", true, flow.PollInterval + 5*time.Second, nil
		}
		return "", "", false, 0, oauthHTTPError("device authorization", response.StatusCode, data)
	}
	var decoded struct {
		AuthorizationCode string `json:"authorization_code"`
		CodeVerifier      string `json:"code_verifier"`
	}
	if err := json.Unmarshal(data, &decoded); err != nil {
		return "", "", false, 0, fmt.Errorf("decode device authorization: %w", err)
	}
	if decoded.AuthorizationCode == "" || decoded.CodeVerifier == "" {
		return "", "", false, 0, errors.New("device authorization response is missing fields")
	}
	return decoded.AuthorizationCode, decoded.CodeVerifier, false, 0, nil
}

func (m *oauthManager) exchange(spec oauthSpec, code, state, verifier, redirectURI string) (*OAuthCredential, error) {
	if spec.Protocol == protocolAnthropic {
		body, _ := json.Marshal(map[string]string{
			"grant_type": "authorization_code", "client_id": spec.ClientID,
			"code": code, "state": state, "redirect_uri": redirectURI,
			"code_verifier": verifier,
		})
		return m.tokenRequest(spec, "token exchange", "application/json", body)
	}
	values := url.Values{
		"grant_type": {"authorization_code"}, "client_id": {spec.ClientID},
		"code": {code}, "code_verifier": {verifier}, "redirect_uri": {redirectURI},
	}
	return m.tokenRequest(spec, "token exchange", "application/x-www-form-urlencoded", []byte(values.Encode()))
}

func (m *oauthManager) refresh(spec oauthSpec, refreshToken string) (*OAuthCredential, error) {
	if strings.TrimSpace(refreshToken) == "" {
		return nil, errors.New("OAuth refresh token is missing; sign in again")
	}
	if spec.Protocol == protocolAnthropic {
		body, _ := json.Marshal(map[string]string{
			"grant_type": "refresh_token", "client_id": spec.ClientID,
			"refresh_token": refreshToken,
		})
		return m.tokenRequest(spec, "token refresh", "application/json", body)
	}
	values := url.Values{
		"grant_type": {"refresh_token"}, "client_id": {spec.ClientID},
		"refresh_token": {refreshToken},
	}
	return m.tokenRequest(spec, "token refresh", "application/x-www-form-urlencoded", []byte(values.Encode()))
}

func (m *oauthManager) tokenRequest(spec oauthSpec, operation, contentType string, body []byte) (*OAuthCredential, error) {
	response, data, err := m.do(context.Background(), http.MethodPost, spec.TokenURL, contentType, body)
	if err != nil {
		return nil, fmt.Errorf("%s %s: %w", spec.Name, operation, err)
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, oauthHTTPError(spec.Name+" "+operation, response.StatusCode, data)
	}
	var decoded struct {
		AccessToken  string `json:"access_token"`
		RefreshToken string `json:"refresh_token"`
		ExpiresIn    int64  `json:"expires_in"`
	}
	if err := json.Unmarshal(data, &decoded); err != nil {
		return nil, fmt.Errorf("decode %s response: %w", operation, err)
	}
	if decoded.AccessToken == "" || decoded.RefreshToken == "" || decoded.ExpiresIn <= 0 {
		return nil, fmt.Errorf("%s response is missing token fields", operation)
	}
	credential := &OAuthCredential{
		Access: decoded.AccessToken, Refresh: decoded.RefreshToken,
		Expires: m.now().Add(time.Duration(decoded.ExpiresIn) * time.Second).UnixMilli(),
	}
	if spec.Protocol == protocolCodex {
		credential.AccountID = openAIAccountID(decoded.AccessToken)
		if credential.AccountID == "" {
			return nil, errors.New("OpenAI OAuth token has no ChatGPT account id")
		}
	}
	return credential, nil
}

func (m *oauthManager) do(ctx context.Context, method, target, contentType string, body []byte) (*http.Response, []byte, error) {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, method, target, strings.NewReader(string(body)))
	if err != nil {
		return nil, nil, err
	}
	request.Header.Set("Content-Type", contentType)
	request.Header.Set("Accept", "application/json")
	request.Header.Set("User-Agent", "niffler/0.3")
	response, err := m.client.Do(request)
	if err != nil {
		return nil, nil, err
	}
	defer response.Body.Close()
	data, err := io.ReadAll(io.LimitReader(response.Body, maxOAuthBody+1))
	if err != nil {
		return nil, nil, err
	}
	if len(data) > maxOAuthBody {
		return nil, nil, errors.New("OAuth response is too large")
	}
	return response, data, nil
}

func oauthHTTPError(operation string, status int, body []byte) error {
	detail := strings.TrimSpace(string(body))
	if len(detail) > 1000 {
		detail = detail[:1000] + "…"
	}
	if detail == "" {
		return fmt.Errorf("%s failed (HTTP %d)", operation, status)
	}
	return fmt.Errorf("%s failed (HTTP %d): %s", operation, status, detail)
}

func (m *oauthManager) storeOAuthProvider(flow *oauthFlow, credential *OAuthCredential) (providerSummary, error) {
	raw, rev, err := m.sc.get(kindProvider, flow.Nickname)
	if err != nil {
		return providerSummary{}, err
	}
	p := Provider{Nickname: flow.Nickname}
	expectRev := 0
	if raw != nil && rev != nil {
		if err := json.Unmarshal(raw, &p); err != nil {
			return providerSummary{}, fmt.Errorf("corrupt provider %q: %w", flow.Nickname, err)
		}
		expectRev = *rev
	}
	previousProtocol := p.withDefaults().Protocol
	p.Nickname = flow.Nickname
	p.AuthType = authOAuth
	p.Protocol = flow.Protocol
	p.APIKey = ""
	p.OAuth = credential
	if previousProtocol != flow.Protocol {
		p.BaseURL = ""
		p.Catalog = ""
		p.Model = ""
	}
	if flow.Model != "" {
		p.Model = flow.Model
	}
	// A provider converted from another protocol should receive this protocol's
	// defaults instead of retaining an incompatible endpoint/catalog.
	if p.BaseURL == "" || (flow.Protocol == protocolCodex && !strings.Contains(p.BaseURL, "chatgpt.com")) ||
		(flow.Protocol == protocolAnthropic && strings.Contains(p.BaseURL, "chatgpt.com")) {
		p.BaseURL = ""
	}
	if (flow.Protocol == protocolCodex && p.Catalog == "anthropic") ||
		(flow.Protocol == protocolAnthropic && p.Catalog == "openai") {
		p.Catalog = ""
	}
	p = p.withDefaults()
	if _, err := m.sc.put(kindProvider, p.Nickname, p, expectRev); err != nil {
		return providerSummary{}, err
	}
	activate := flow.Active || !providerActiveExists(m.sc)
	if activate {
		if err := activateProvider(m.comp, m.sc, p.Nickname); err != nil {
			return providerSummary{}, err
		}
	}
	emitProviderChanged(m.comp, m.sc, "login", p.Nickname)
	return summarizeProvider(p, activate || providerActiveIs(m.sc, p.Nickname)), nil
}

func (m *oauthManager) effectiveProvider() (Provider, string, bool, error) {
	p, source, ok, err := effectiveProvider(m.sc)
	if err != nil || !ok || source != "store" || p.AuthType != authOAuth {
		return p, source, ok, err
	}
	raw, rev, err := m.sc.get(kindProvider, p.Nickname)
	if err != nil {
		return Provider{}, source, false, err
	}
	if raw == nil || rev == nil {
		return Provider{}, source, false, fmt.Errorf("provider %q disappeared", p.Nickname)
	}
	if err := json.Unmarshal(raw, &p); err != nil {
		return Provider{}, source, false, fmt.Errorf("corrupt provider %q: %w", p.Nickname, err)
	}
	p, err = m.ensureFresh(p.withDefaults(), *rev)
	if err != nil {
		return Provider{}, source, false, err
	}
	return p, source, p.hasCredential(), nil
}

func (m *oauthManager) ensureFresh(p Provider, rev int) (Provider, error) {
	if p.AuthType != authOAuth {
		return p, nil
	}
	if p.OAuth == nil || p.OAuth.Access == "" || p.OAuth.Refresh == "" {
		return Provider{}, fmt.Errorf("provider %q has an incomplete OAuth credential; sign in again", p.Nickname)
	}
	if p.OAuth.Expires > m.now().Add(oauthRefreshAhead).UnixMilli() {
		return p, nil
	}
	spec, ok := m.specs[p.Protocol]
	if !ok {
		return Provider{}, fmt.Errorf("provider %q has unsupported OAuth protocol %q", p.Nickname, p.Protocol)
	}
	credential, err := m.refresh(spec, p.OAuth.Refresh)
	if err != nil {
		return Provider{}, fmt.Errorf("refresh provider %q: %w", p.Nickname, err)
	}
	if credential.AccountID == "" {
		credential.AccountID = p.OAuth.AccountID
	}
	p.OAuth = credential
	if _, err := m.sc.put(kindProvider, p.Nickname, p, rev); err != nil {
		return Provider{}, fmt.Errorf("persist refreshed provider %q: %w", p.Nickname, err)
	}
	emitProviderChanged(m.comp, m.sc, "refresh", p.Nickname)
	return p, nil
}

func (m *oauthManager) cancel(flowID string) bool {
	m.mu.Lock()
	flow := m.flows[flowID]
	if flow != nil {
		delete(m.flows, flowID)
	}
	m.mu.Unlock()
	if flow != nil {
		closeOAuthServer(flow.CallbackServer)
		return true
	}
	return false
}

func (m *oauthManager) pruneExpired(now time.Time) {
	m.mu.Lock()
	var expired []*oauthFlow
	for id, flow := range m.flows {
		if !now.Before(flow.ExpiresAt) {
			delete(m.flows, id)
			expired = append(expired, flow)
		}
	}
	m.mu.Unlock()
	for _, flow := range expired {
		closeOAuthServer(flow.CallbackServer)
	}
}

func (m *oauthManager) cancelBrowserFlows(protocol string) {
	m.mu.Lock()
	var cancelled []*oauthFlow
	for id, flow := range m.flows {
		if flow.Protocol == protocol && flow.Method == "browser" {
			delete(m.flows, id)
			cancelled = append(cancelled, flow)
		}
	}
	m.mu.Unlock()
	for _, flow := range cancelled {
		closeOAuthServer(flow.CallbackServer)
	}
}

func (m *oauthManager) close() {
	m.mu.Lock()
	flows := m.flows
	m.flows = make(map[string]*oauthFlow)
	m.mu.Unlock()
	for _, flow := range flows {
		closeOAuthServer(flow.CallbackServer)
	}
}

func closeOAuthServer(server *http.Server) {
	if server == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	_ = server.Shutdown(ctx)
}

func randomBase64URL() (string, error) {
	data := make([]byte, 32)
	if _, err := rand.Read(data); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(data), nil
}

func parseAuthorizationInput(input string) (code, state string) {
	value := strings.TrimSpace(input)
	if value == "" {
		return "", ""
	}
	if parsed, err := url.Parse(value); err == nil && parsed.Scheme != "" {
		return parsed.Query().Get("code"), parsed.Query().Get("state")
	}
	if strings.Contains(value, "#") {
		parts := strings.SplitN(value, "#", 2)
		return strings.TrimSpace(parts[0]), strings.TrimSpace(parts[1])
	}
	if strings.Contains(value, "code=") {
		if values, err := url.ParseQuery(value); err == nil {
			return values.Get("code"), values.Get("state")
		}
	}
	return value, ""
}

func openAIAccountID(token string) string {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return ""
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return ""
	}
	var claims struct {
		AccountID string `json:"chatgpt_account_id"`
		Auth      struct {
			AccountID string `json:"chatgpt_account_id"`
		} `json:"https://api.openai.com/auth"`
		Organizations []struct {
			ID string `json:"id"`
		} `json:"organizations"`
	}
	if json.Unmarshal(payload, &claims) != nil {
		return ""
	}
	if claims.AccountID != "" {
		return claims.AccountID
	}
	if claims.Auth.AccountID != "" {
		return claims.Auth.AccountID
	}
	if len(claims.Organizations) > 0 {
		return claims.Organizations[0].ID
	}
	return ""
}
