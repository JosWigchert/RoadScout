package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// The NAS runner may be containerized while the Docker daemon is on the host.
// Exercise deployment selection without assuming the runner's filesystem can
// validate a Docker-host bind mount.
func TestNASDeploymentTrafficOverride(t *testing.T) {
	for _, tc := range []struct {
		name, path                 string
		failCheck                  bool
		wantError, wantRun, wantUp bool
	}{
		{"builtin defaults", "", false, false, false, true},
		{"absolute host override", "/mnt/user/appdata/roadscout/staging/traffic.json", false, false, true, true},
		{"relative path rejected", "relative.json", false, true, false, false},
		{"host mount check fails", "/missing/traffic.json", true, true, true, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			log := filepath.Join(dir, "commands")
			docker := filepath.Join(dir, "docker")
			mock := `#!/bin/sh
printf '%s\n' "$*" >> "$TEST_LOG"
case " $* " in
  *' config --format json '*) python3 -c 'import json,os; print(json.dumps({"services":{"routing-api":{"environment":{"ROUTING_HOST":"staging.example.com","TRAFFIC_CONFIG_HOST_FILE":os.environ.get("TEST_TRAFFIC_OVERRIDE", "")}}}}))' ;;
  *' run '*) [ "$TEST_FAIL_CHECK" != 1 ] ;;
  *) exit 0 ;;
esac
`
			if err := os.WriteFile(docker, []byte(mock), 0700); err != nil {
				t.Fatal(err)
			}
			envFile := filepath.Join(dir, "nas.env")
			if err := os.WriteFile(envFile, []byte("# simulated\n"), 0600); err != nil {
				t.Fatal(err)
			}
			cmd := exec.Command("sh", "../scripts/deploy-nas.sh", "staging")
			cmd.Env = append(os.Environ(), "PATH="+dir+string(os.PathListSeparator)+os.Getenv("PATH"),
				"NAS_ENV_FILE="+envFile, "RELEASE_ID=test", "TEST_LOG="+log,
				"TEST_TRAFFIC_OVERRIDE="+tc.path)
			if tc.failCheck {
				cmd.Env = append(cmd.Env, "TEST_FAIL_CHECK=1")
			} else {
				cmd.Env = append(cmd.Env, "TEST_FAIL_CHECK=0")
			}
			out, err := cmd.CombinedOutput()
			if (err != nil) != tc.wantError {
				t.Fatalf("error=%v output=%s", err, out)
			}
			commands, err := os.ReadFile(log)
			if err != nil {
				t.Fatal(err)
			}
			text := string(commands)
			if strings.Contains(text, " run --rm ") != tc.wantRun || strings.Contains(text, " up -d ") != tc.wantUp {
				t.Fatalf("unexpected commands:\n%s", text)
			}
			if tc.wantRun && !strings.Contains(text, "compose.traffic-override.yaml") {
				t.Fatalf("missing override:\n%s", text)
			}
			if !tc.wantRun && strings.Contains(text, "compose.traffic-override.yaml") {
				t.Fatalf("unexpected override:\n%s", text)
			}
		})
	}
}
