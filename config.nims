switch("threads", "on")
switch("d", "ssl")
#switch("passL", "-lcrypto")
#switch("tlsEmulation", "off")

# Nim compiler settings
#switch("warning", "[LockLevel]:off")
#switch("hints", "off")
switch("linedir", "on")
switch("debuginfo")
switch("stacktrace", "on")
switch("linetrace", "on")
switch("d", "debug")
switch("opt", "none")
switch("debugger", "native")

# Enables system copy paste
switch("d", "useSystemClipboard")

if hostOS == "macosx":
  # This adds the paths specifically when building on macOS
  switch("passL", "-L/opt/homebrew/lib")
  switch("passC", "-I/opt/homebrew/include")