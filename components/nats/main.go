// Command nats-server is the NATS server component for the Niffler harness.
//
// It is a faithful copy of the official nats-server main (github.com/nats-io/
// nats-server/v2, Apache-2.0 — see DEPENDENCIES.md upstream), rebuilt here so
// the harness's one external bus dependency is a first-class component:
// `make build` produces var/bin/nats-server from this source, pinned by
// go.mod. Core prefers that binary over a PATH install (core/niffler.nim,
// spawnNats), which removes the last prerequisite for pure desktop use.
//
// It is NOT a bus component in the runtime sense: core spawns it before the
// bus exists and it registers no tools, so it is deliberately absent from
// manifest.yaml. It must stay CLI-compatible with the official binary —
// core passes -a/-p/-m/--ports_file_dir and relies on the server exiting
// non-zero when the requested port cannot be bound.
package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/nats-io/nats-server/v2/server"
)

var usageStr = `
Usage: nats-server [options]

Server Options:
    -a, --addr, --net <host>         Bind to host address (default: 0.0.0.0)
    -p, --port <port>                Use port for clients (default: 4222)
    -n, --name
        --server_name <server_name>  Server name (default: auto)
    -P, --pid <file>                 File to store PID
    -m, --http_port <port>           Use port for http monitoring
    -ms,--https_port <port>          Use port for https monitoring
    -c, --config <file>              Configuration file
    -t                               Test configuration and exit
    -sl,--signal <signal>[=<pid>]    Send signal to nats-server process (ldm, stop, quit, term, reopen, reload)
                                     <pid> can be either a PID (e.g. 1) or the path to a PID file (e.g. /var/run/nats-server.pid)
        --client_advertise <string>  Client URL to advertise to other servers
        --ports_file_dir <dir>       Creates a ports file in the specified directory (<executable_name>_<pid>.ports).

Logging Options:
    -l, --log <file>                 File to redirect log output
    -T, --logtime                    Timestamp log entries (default: true)
    -s, --syslog                     Log to syslog or windows event log
    -r, --remote_syslog <addr>       Syslog server addr (udp://localhost:514)
    -D, --debug                      Enable debugging output
    -V, --trace                      Trace the raw protocol
    -VV                              Verbose trace (traces system account as well)
    -DV                              Debug and trace
    -DVV                             Debug and verbose trace (traces system account as well)
        --log_size_limit <limit>     Logfile size limit (default: auto)
        --max_traced_msg_len <len>   Maximum printable length for traced messages (default: unlimited)

JetStream Options:
    -js, --jetstream                 Enable JetStream functionality
    -sd, --store_dir <dir>           Set the storage directory

Authorization Options:
        --user <user>                User required for connections
        --pass <password>            Password required for connections
        --auth <token>               Authorization token required for connections

TLS Options:
        --tls                        Enable TLS, do not verify clients (default: false)
        --tlscert <file>             Server certificate file
        --tlskey <file>              Private key for server certificate
        --tlsverify                  Enable TLS, verify client certificates
        --tlscacert <file>           Client certificate CA for verification

Cluster Options:
        --routes <rurl-1, rurl-2>    Routes to solicit and connect
        --cluster <cluster-url>      Cluster URL for solicited routes
        --cluster_name <string>      Cluster Name, if not set one will be dynamically generated
        --no_advertise <bool>        Do not advertise known cluster information to clients
        --cluster_advertise <string> Cluster URL to advertise to other servers
        --connect_retries <number>   For implicit routes, number of connect retries
        --cluster_listen <url>       Cluster url from which members can solicit routes

Profiling Options:
        --profile <port>             Profiling HTTP port

Common Options:
    -h, --help                       Show this message
    -v, --version                    Show version
        --help_tls                   TLS help
`

// usage will print out the flag options for the server.
func usage() {
	fmt.Printf("%s\n", usageStr)
	os.Exit(0)
}

func main() {
	exe := "nats-server"

	// Create a FlagSet and sets the usage
	fs := flag.NewFlagSet(exe, flag.ExitOnError)
	fs.Usage = usage

	// Configure the options from the flags/config file
	opts, err := server.ConfigureOptions(fs, os.Args[1:],
		server.PrintServerAndExit,
		fs.Usage,
		server.PrintTLSHelpAndDie)
	if err != nil {
		server.PrintAndDie(fmt.Sprintf("%s: %s", exe, err))
	} else if opts.CheckConfig {
		fmt.Fprintf(os.Stderr, "%s: configuration file %s is valid (%s)\n", exe, opts.ConfigFile, opts.ConfigDigest())
		os.Exit(0)
	}

	// Redact secret arguments before expvar reads them.
	server.RedactArgs(os.Args)

	// Create the server with appropriate options.
	s, err := server.NewServer(opts)
	if err != nil {
		server.PrintAndDie(fmt.Sprintf("%s: %s", exe, err))
	}

	// Configure the logger based on the flags.
	s.ConfigureLogger()

	// Start things up. Block here until done.
	if err := server.Run(s); err != nil {
		server.PrintAndDie(err.Error())
	}

	s.WaitForShutdown()
}
