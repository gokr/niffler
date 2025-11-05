## Test NATS with synchronous subscriptions (like official example)

import std/strformat
import nats

# Initialize NATS library
let initStatus = nats_Open(-1)
if initStatus != NATS_OK:
  echo fmt"Failed to initialize NATS: {initStatus}"
  quit(1)

# Connect
var nc: ptr natsConnection = nil
let connectStatus = natsConnection_ConnectTo(addr nc, "nats://localhost:4222")
if connectStatus != NATS_OK:
  echo fmt"Failed to connect: {connectStatus}"
  quit(1)

echo "Connected to NATS!"

# Subscribe synchronously
var sub: ptr natsSubscription = nil
let subStatus = natsConnection_SubscribeSync(addr sub, nc, "test.subject")
if subStatus != NATS_OK:
  echo fmt"Failed to subscribe: {subStatus}"
  quit(1)

echo "Subscribed to test.subject"

# Publish a message
let pubStatus = natsConnection_PublishString(nc, "test.subject", "Hello NATS!")
if pubStatus != NATS_OK:
  echo fmt"Failed to publish: {pubStatus}"
  quit(1)

# Flush to ensure delivery
discard natsConnection_Flush(nc)
echo "Published message"

# Try to receive the message (timeout 1000ms)
var msg: ptr natsMsg = nil
let recvStatus = natsSubscription_NextMsg(addr msg, sub, 1000)
if recvStatus == NATS_OK and msg != nil:
  echo fmt"Received: {natsMsg_GetData(msg)}"
  natsMsg_Destroy(msg)
elif recvStatus == NATS_TIMEOUT:
  echo "Timeout waiting for message"
else:
  echo fmt"Error receiving: {recvStatus}"

# Cleanup
discard natsSubscription_Unsubscribe(sub)
natsSubscription_Destroy(sub)
natsConnection_Close(nc)
natsConnection_Destroy(nc)
nats_Close()

echo "Test complete!"
