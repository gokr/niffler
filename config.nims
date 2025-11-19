switch("threads", "on")
switch("d", "ssl")
#switch("passL", "-lcrypto")
#switch("tlsEmulation", "off")

# Add path to natswrapper (sibling directory)
switch("path", "../natswrapper/src")

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
