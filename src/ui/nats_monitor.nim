## NATS Traffic Monitor
##
## Debug tool that displays all NATS traffic on niffler.> subjects.
## Run with: niffler --nats-monitor
##
## Shows timestamped messages with color-coded subjects and formatted payloads.

import std/[options, strformat, logging, times, json, terminal, strutils]
import ../core/[nats_client, log_file]

proc formatTimestamp(): string =
  now().format("HH:mm:ss.fff")

proc colorForSubject(subject: string): ForegroundColor =
  if subject.contains(".request"):
    fgCyan
  elif subject.contains(".response"):
    fgGreen
  elif subject.contains(".status"):
    fgYellow
  elif subject.contains("presence"):
    fgMagenta
  else:
    fgWhite

proc formatPayload(data: string): string =
  try:
    let json = parseJson(data)
    return json.pretty()
  except:
    return data

proc startNatsMonitor*(natsUrl: string, level: Level, dump: bool = false, logFile: string = "") =
  ## Start the NATS traffic monitor (runs in main thread)

  # Setup file logging if logFile is provided
  if logFile.len > 0:
    # Setup file and console logging (main function didn't add console logger)
    let logManager = initLogFileManager(logFile)
    setGlobalLogManager(logManager)

    let logger = newFileAndConsoleLogger(logManager)
    addHandler(logger)
    logManager.activateLogFile()
    debug(fmt"File logging enabled: {logFile}")
  else:
    let consoleLogger = newConsoleLogger(useStderr = true)
    addHandler(consoleLogger)

  setLogFilter(level)

  echo "NATS Traffic Monitor"
  echo "===================="
  echo fmt("Connecting to: {natsUrl}")
  echo "Subscribing to: niffler.>"
  echo "Press Ctrl+C to exit"
  echo ""

  var client: NifflerNatsClient
  try:
    client = initNatsClient(natsUrl, "", presenceTTL = 0)
    echo "Connected to NATS server"
    echo ""
  except Exception as e:
    echo fmt("Failed to connect to NATS: {e.msg}")
    echo ""
    echo "Make sure NATS server is running:"
    echo "  nats-server"
    return

  # Subscribe to all niffler traffic
  var subscription = client.subscribe("niffler.>")

  try:
    while true:
      let maybeMsg = subscription.nextMsg(timeoutMs = 100)
      if maybeMsg.isSome():
        let msg = maybeMsg.get()
        let ts = formatTimestamp()
        let color = colorForSubject(msg.subject)

        # Print header line with timestamp and subject
        stdout.setForegroundColor(fgWhite, bright = false)
        stdout.write(fmt("[{ts}] "))
        stdout.setForegroundColor(color, bright = true)
        stdout.write(msg.subject)
        stdout.resetAttributes()
        echo ""

        # Print formatted payload
        let payload = formatPayload(msg.data)
        for line in payload.splitLines():
          echo "  " & line
        echo ""

  except CatchableError as e:
    if e.msg.contains("interrupted"):
      echo ""
      echo "Interrupted"
    else:
      echo fmt("Error: {e.msg}")
  finally:
    subscription.unsubscribe()
    client.close()
    echo "Monitor stopped"
