#!/bin/bash
# Step 1: restart gateway inside sandbox
echo "Restarting OpenClaw gateway inside sandbox..."
nemoclaw svclaw connect << 'SANDBOX'
kill $(grep -rl "openclaw-gatewa" /proc/*/comm 2>/dev/null | grep -o '[0-9]*' | head -1) 2>/dev/null
sleep 2
openclaw gateway --port 18789 --bind lan &
sleep 3
SANDBOX

# Step 2: reset port forward on host
echo "Resetting port forward..."
openshell forward stop 18789 svclaw 2>/dev/null
sleep 1
openshell forward start 0.0.0.0:18789 svclaw -d

# Step 3: verify
echo "Port status:"
ss -tlnp | grep 18789
