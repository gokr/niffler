package sdk

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/nats-io/nats.go"
)

// startTestNATS lets NATS allocate its own loopback port (no
// bind-close-start race) and returns the published client URL.
func startTestNATS(t *testing.T) string {
	t.Helper()
	serverBin, err := exec.LookPath("nats-server")
	if err != nil {
		t.Skip("nats-server is not installed")
	}
	portsDir, err := os.MkdirTemp("", "niffler-sdk-test-*")
	if err != nil {
		t.Fatal(err)
	}
	server := exec.Command(serverBin, "-a", "127.0.0.1", "-p", "-1",
		"--ports_file_dir", portsDir)
	if err := server.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = server.Process.Kill()
		_ = server.Wait()
		_ = os.RemoveAll(portsDir)
	})
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		entries, globErr := filepath.Glob(filepath.Join(portsDir, "*.ports"))
		if globErr == nil {
			for _, path := range entries {
				data, readErr := os.ReadFile(path)
				if readErr != nil {
					continue
				}
				var ports struct {
					Nats []string `json:"nats"`
				}
				if json.Unmarshal(data, &ports) == nil && len(ports.Nats) > 0 {
					routerBin, err := filepath.Abs("../../var/bin/test_catalog_router")
					if err != nil {
						t.Fatal(err)
					}
					ready := filepath.Join(portsDir, "router-ready")
					router := exec.Command(routerBin, ports.Nats[0], ready)
					if err := router.Start(); err != nil {
						t.Fatalf("build test_catalog_router first: %v", err)
					}
					t.Cleanup(func() { _ = router.Process.Kill(); _ = router.Wait() })
					for i := 0; i < 100; i++ {
						if _, err := os.Stat(ready); err == nil {
							return ports.Nats[0]
						}
						time.Sleep(20 * time.Millisecond)
					}
					t.Fatal("catalog router did not become ready")
				}
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("nats-server did not publish a client port")
	return ""
}

func TestShouldLog(t *testing.T) {
	tests := []struct {
		level     string
		threshold string
		want      bool
	}{
		{"debug", "debug", true},
		{"debug", "info", false},
		{"info", "info", true},
		{"warn", "info", true},
		{"error", "warn", true},
		{"info", "invalid", true},
		{"debug", "invalid", false},
	}
	for _, tt := range tests {
		got, err := shouldLog(tt.level, tt.threshold)
		if err != nil {
			t.Fatalf("shouldLog(%q, %q): %v", tt.level, tt.threshold, err)
		}
		if got != tt.want {
			t.Errorf("shouldLog(%q, %q) = %v, want %v",
				tt.level, tt.threshold, got, tt.want)
		}
	}
}

func TestShouldLogRejectsUnknownLevel(t *testing.T) {
	if _, err := shouldLog("notice", "info"); err == nil {
		t.Fatal("shouldLog accepted an unknown level")
	}
}

func TestSignalShutdownIsIdempotent(t *testing.T) {
	c := New("test", "0.1.0")
	c.signalShutdown()
	c.signalShutdown()
	select {
	case <-c.shutdown:
	default:
		t.Fatal("shutdown signal did not close the channel")
	}
}

func TestToolConcurrentExecution(t *testing.T) {
	url := startTestNATS(t)
	client, err := nats.Connect(url)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	t.Setenv("NIF_NATS_URL", url)

	tests := []struct {
		name       string
		component  string
		concurrent bool
		limit      int
		wantSecond bool
	}{
		{name: "ordinary tools stay serialized", component: "go-serial", wantSecond: false},
		{name: "concurrent tools overlap", component: "go-concurrent", concurrent: true, wantSecond: true},
		{name: "concurrent limit applies backpressure", component: "go-concurrent-one", concurrent: true, limit: 1, wantSecond: false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			started := make(chan struct{}, 2)
			release := make(chan struct{})
			var releaseOnce sync.Once
			releaseAll := func() { releaseOnce.Do(func() { close(release) }) }
			handler := func(_ *Component, _ json.RawMessage) (any, error) {
				started <- struct{}{}
				<-release
				return map[string]bool{"ok": true}, nil
			}

			component := New(tt.component, "0.1.0")
			if tt.limit > 0 {
				component.ConcurrentLimit(tt.limit)
			}
			if tt.concurrent {
				component.ToolConcurrent("wait", map[string]any{
					"type": "object", "properties": map[string]any{},
				}, handler)
			} else {
				component.Tool("wait", map[string]any{
					"type": "object", "properties": map[string]any{},
				}, handler)
			}
			if err := component.Connect(); err != nil {
				t.Fatal(err)
			}
			defer component.Close()
			defer releaseAll()

			errs := make(chan error, 2)
			request := func(id string) {
				env := Envelope{V: 1, ID: id, Kind: KindCall,
					Tool: "wait", Args: json.RawMessage(`{}`)}
				data, marshalErr := env.Marshal()
				if marshalErr != nil {
					errs <- marshalErr
					return
				}
				_, requestErr := client.Request("svc."+tt.component+".call", data,
					3*time.Second)
				errs <- requestErr
			}

			go request("first")
			select {
			case <-started:
			case <-time.After(2 * time.Second):
				releaseAll()
				t.Fatal("first handler did not start")
			}
			go request("second")

			secondStarted := false
			select {
			case <-started:
				secondStarted = true
			case <-time.After(250 * time.Millisecond):
			}
			if secondStarted != tt.wantSecond {
				t.Errorf("second handler started before release = %v, want %v",
					secondStarted, tt.wantSecond)
			}

			releaseAll()
			if !secondStarted {
				select {
				case <-started:
				case <-time.After(2 * time.Second):
					t.Fatal("serialized second handler did not start after release")
				}
			}
			for i := 0; i < 2; i++ {
				select {
				case requestErr := <-errs:
					if requestErr != nil {
						t.Errorf("request failed: %v", requestErr)
					}
				case <-time.After(3 * time.Second):
					t.Fatal("request did not finish")
				}
			}
		})
	}
}

func TestSerializedToolExcludesConcurrentHandlers(t *testing.T) {
	url := startTestNATS(t)
	client, err := nats.Connect(url)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	t.Setenv("NIF_NATS_URL", url)

	parallelStarted := make(chan struct{})
	serialStarted := make(chan struct{})
	releaseParallel := make(chan struct{})
	component := New("go-exclusive", "0.1.0").
		ToolConcurrent("parallel", map[string]any{
			"type": "object", "properties": map[string]any{},
		}, func(_ *Component, _ json.RawMessage) (any, error) {
			close(parallelStarted)
			<-releaseParallel
			return map[string]bool{"ok": true}, nil
		}).
		Tool("serial", map[string]any{
			"type": "object", "properties": map[string]any{},
		}, func(_ *Component, _ json.RawMessage) (any, error) {
			close(serialStarted)
			return map[string]bool{"ok": true}, nil
		})
	if err := component.Connect(); err != nil {
		t.Fatal(err)
	}
	defer component.Close()
	var releaseOnce sync.Once
	release := func() { releaseOnce.Do(func() { close(releaseParallel) }) }
	defer release()

	request := func(tool, id string, done chan<- error) {
		env := Envelope{V: 1, ID: id, Kind: KindCall,
			Tool: tool, Args: json.RawMessage(`{}`)}
		data, marshalErr := env.Marshal()
		if marshalErr != nil {
			done <- marshalErr
			return
		}
		_, requestErr := client.Request("svc.go-exclusive.call", data, 3*time.Second)
		done <- requestErr
	}
	done := make(chan error, 2)
	go request("parallel", "parallel", done)
	select {
	case <-parallelStarted:
	case <-time.After(2 * time.Second):
		t.Fatal("concurrent handler did not start")
	}
	go request("serial", "serial", done)
	select {
	case <-serialStarted:
		t.Error("serialized handler overlapped a concurrent handler")
	case <-time.After(250 * time.Millisecond):
	}
	release()
	select {
	case <-serialStarted:
	case <-time.After(2 * time.Second):
		t.Fatal("serialized handler did not start after concurrent handler")
	}
	for i := 0; i < 2; i++ {
		if requestErr := <-done; requestErr != nil {
			t.Errorf("request failed: %v", requestErr)
		}
	}
}

func TestCloseWaitsForActiveHandler(t *testing.T) {
	url := startTestNATS(t)
	var client *nats.Conn
	var err error
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		client, err = nats.Connect(url, nats.Timeout(100*time.Millisecond))
		if err == nil {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if err != nil {
		t.Fatalf("connect to test server: %v", err)
	}
	defer client.Close()
	t.Setenv("NIF_NATS_URL", url)

	started := make(chan struct{})
	finished := make(chan struct{})
	c := New("slow-test", "0.1.0").Tool("slow", map[string]any{
		"type": "object", "properties": map[string]any{},
	}, func(c *Component, args json.RawMessage) (any, error) {
		close(started)
		time.Sleep(500 * time.Millisecond)
		close(finished)
		return map[string]bool{"ok": true}, nil
	})
	if err := c.Connect(); err != nil {
		t.Fatal(err)
	}

	request := Envelope{V: 1, ID: NewID(), Kind: KindCall,
		Tool: "slow", Args: json.RawMessage(`{}`)}
	data, _ := request.Marshal()
	replied := make(chan error, 1)
	go func() {
		_, requestErr := client.Request("svc.slow-test.call", data, 3*time.Second)
		replied <- requestErr
	}()
	select {
	case <-started:
	case <-time.After(2 * time.Second):
		t.Fatal("slow handler did not start")
	}

	c.Close()
	select {
	case <-finished:
	default:
		t.Fatal("Close returned before the active handler finished")
	}
	if err := <-replied; err != nil {
		t.Fatalf("active handler reply was lost during Close: %v", err)
	}

	concurrentStarted := make(chan struct{})
	concurrentFinished := make(chan struct{})
	concurrent := New("slow-concurrent-test", "0.1.0").ToolConcurrent("slow", map[string]any{
		"type": "object", "properties": map[string]any{},
	}, func(_ *Component, _ json.RawMessage) (any, error) {
		close(concurrentStarted)
		time.Sleep(500 * time.Millisecond)
		close(concurrentFinished)
		return map[string]bool{"ok": true}, nil
	})
	if err := concurrent.Connect(); err != nil {
		t.Fatal(err)
	}
	request = Envelope{V: 1, ID: NewID(), Kind: KindCall,
		Tool: "slow", Args: json.RawMessage(`{}`)}
	data, _ = request.Marshal()
	replied = make(chan error, 1)
	go func() {
		_, requestErr := client.Request("svc.slow-concurrent-test.call", data, 3*time.Second)
		replied <- requestErr
	}()
	select {
	case <-concurrentStarted:
	case <-time.After(2 * time.Second):
		t.Fatal("concurrent handler did not start")
	}
	concurrent.Close()
	select {
	case <-concurrentFinished:
	default:
		t.Fatal("Close returned before the concurrent handler finished")
	}
	if err := <-replied; err != nil {
		t.Fatalf("concurrent handler reply was lost during Close: %v", err)
	}

	closeFromHandler := New("handler-close-test", "0.1.0").ToolConcurrent("close", map[string]any{
		"type": "object", "properties": map[string]any{},
	}, func(c *Component, args json.RawMessage) (any, error) {
		c.Close()
		return map[string]bool{"ok": true}, nil
	})
	if err := closeFromHandler.Connect(); err != nil {
		t.Fatal(err)
	}
	request = Envelope{V: 1, ID: NewID(), Kind: KindCall,
		Tool: "close", Args: json.RawMessage(`{}`)}
	data, _ = request.Marshal()
	startedAt := time.Now()
	if _, err := client.Request("svc.handler-close-test.call", data, 3*time.Second); err != nil {
		t.Fatalf("Close invoked by a handler lost its reply: %v", err)
	}
	closeFromHandler.Close()
	if elapsed := time.Since(startedAt); elapsed > 2*time.Second {
		t.Fatalf("Close invoked by a handler self-waited: %v", elapsed)
	}
}

// TestSlashRegistrationPublishesSpec verifies that Slash() defaults the
// target tool to the command name and that reg.publish carries the full
// declarative spec (docs/WIRE.md) so core can validate and checkpoint it.
func TestSlashRegistrationPublishesSpec(t *testing.T) {
	url := startTestNATS(t)

	sub, err := nats.Connect(url)
	if err != nil {
		t.Fatal(err)
	}
	defer sub.Close()
	received := make(chan map[string]any, 1)
	if _, err := sub.Subscribe("reg.publish", func(m *nats.Msg) {
		var payload map[string]any
		if err := json.Unmarshal(m.Data, &payload); err == nil {
			received <- payload
		}
	}); err != nil {
		t.Fatal(err)
	}

	c := New("deploy-test", "0.1.0").
		Tool("deploy_run", map[string]any{
			"type": "object", "properties": map[string]any{},
		}, func(c *Component, args json.RawMessage) (any, error) {
			return map[string]bool{"ok": true}, nil
		}).
		Slash(SlashCommand{
			Name:        "Deploy", // core lowercases
			Description: "deploy the current branch",
			Params: []SlashParam{
				{Name: "env", Kind: "enum", Description: "target environment",
					Source: &SlashSource{Tool: "deploy.envs", Args: map[string]any{}}},
				{Name: "force", Kind: "bool", Default: false},
			},
		})
	t.Setenv("NIF_NATS_URL", url)
	if err := c.Connect(); err != nil {
		t.Fatal(err)
	}
	defer c.Close()

	var payload map[string]any
	select {
	case payload = <-received:
	case <-time.After(3 * time.Second):
		t.Fatal("reg.publish was not observed")
	}
	slash, ok := payload["slash"].([]any)
	if !ok || len(slash) != 1 {
		t.Fatalf("slash section missing or wrong: %v", payload["slash"])
	}
	cmd, ok := slash[0].(map[string]any)
	if !ok {
		t.Fatalf("slash entry is not an object: %v", slash[0])
	}
	if cmd["name"] != "Deploy" {
		t.Fatalf("slash name = %v, want Deploy", cmd["name"])
	}
	if cmd["tool"] != "Deploy" {
		t.Fatalf("slash tool = %v, want Deploy (defaulted to name)", cmd["tool"])
	}
	if cmd["description"] != "deploy the current branch" {
		t.Fatalf("slash description = %v", cmd["description"])
	}
	params, ok := cmd["params"].([]any)
	if !ok || len(params) != 2 {
		t.Fatalf("slash params = %v", cmd["params"])
	}
	env, ok := params[0].(map[string]any)
	if !ok || env["kind"] != "enum" {
		t.Fatalf("first param = %v, want env/enum", params[0])
	}
	src, ok := env["source"].(map[string]any)
	if !ok || src["tool"] != "deploy.envs" {
		t.Fatalf("first param source = %v", env["source"])
	}
	force, ok := params[1].(map[string]any)
	if !ok || force["kind"] != "bool" || force["default"] != false {
		t.Fatalf("second param = %v, want force/bool/false", params[1])
	}
}

func TestRejectedInstanceCannotServe(t *testing.T) {
	url := startTestNATS(t)
	t.Setenv("NIF_NATS_URL", url)
	schema := map[string]any{"type": "object", "properties": map[string]any{}}
	accepted := New("admission", "1").Tool("admission_ping", schema,
		func(_ *Component, _ json.RawMessage) (any, error) { return map[string]bool{"accepted": true}, nil })
	if err := accepted.Connect(); err != nil {
		t.Fatal(err)
	}
	defer accepted.Close()
	rejected := New("admission", "1").Tool("admission_ping", schema,
		func(_ *Component, _ json.RawMessage) (any, error) {
			t.Error("rejected handler executed")
			return nil, nil
		})
	rejected.Tool("admission_extra", schema,
		func(_ *Component, _ json.RawMessage) (any, error) { return nil, nil })
	if err := rejected.Connect(); err == nil {
		t.Fatal("incompatible registration accepted")
	}
	rejected.Close()
	for i := 0; i < 20; i++ {
		data, err := accepted.Request("admission", "admission_ping", map[string]any{}, time.Second)
		if err != nil {
			t.Fatal(err)
		}
		var result struct {
			Accepted bool `json:"accepted"`
		}
		if err := json.Unmarshal(data, &result); err != nil || !result.Accepted {
			t.Fatalf("wrong provider: %s", data)
		}
	}
}
