# NemoClaw on Equinix — Distributed AI Hub Integration

> Deploy NVIDIA NemoClaw with OpenShell security sandbox, routing inference through a self-hosted LiteLLM gateway on Equinix infrastructure.

[![NemoClaw](https://img.shields.io/badge/NemoClaw-0.1.0-76b900)](https://github.com/NVIDIA/NemoClaw)
[![OpenClaw](https://img.shields.io/badge/OpenClaw-2026.3.11-orange)](https://openclaw.ai)
[![LiteLLM](https://img.shields.io/badge/LiteLLM-latest-blue)](https://github.com/BerriAI/litellm)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue)](LICENSE)

---

## Overview

This repo documents how to deploy [NVIDIA NemoClaw](https://github.com/NVIDIA/NemoClaw) on Equinix infrastructure and connect its inference layer to a self-hosted [LiteLLM](https://github.com/BerriAI/litellm) gateway — replacing the default NVIDIA Cloud API with your own model routing, spend tracking, and observability stack.

### Architecture

```
VM2 — NemoClaw (this repo)          VM1 — Distributed AI Hub
┌─────────────────────────┐         ┌──────────────────────────┐
│  OpenShell Gateway      │         │  LiteLLM Proxy :4000     │
│  └── k3s cluster        │         │  └── AWS Bedrock         │
│       └── Sandbox pod   │─────────│  └── Groq                │
│            └── OpenClaw │  VLAN   │  └── Azure OpenAI        │
│                 agent   │ private │                          │
│                         │         │  Langfuse :3000          │
│  NGINX reverse proxy    │         │  Qdrant :6333            │
│  svclaw.yourdomain.com  │         └──────────────────────────┘
└─────────────────────────┘
```

**Traffic flow:**
1. OpenClaw agent → inference.local/v1 (virtual endpoint)
2. OpenShell egress proxy intercepts → checks policy → allows if allowlisted
3. Forwards to LiteLLM proxy on VM1 (private VLAN IP)
4. LiteLLM routes to target LLM, logs trace to Langfuse
5. Response returns to agent

---

## Prerequisites

### VM2 (NemoClaw host)
- Ubuntu 22.04 LTS
- 4 vCPU, **8GB RAM** (4GB works but is unstable), 64GB disk
- Docker installed
- Node.js 22+ (OpenClaw requires `>=22.16.0`)
- Connected to same VLAN as VM1

### VM1 (LiteLLM / Distributed AI Hub)
- Existing LiteLLM stack running on port 4000
- LiteLLM master key available
- Port 4000 accessible from VM2's VLAN IP

---

## Installation

### 1. Base dependencies

```bash
sudo apt update && sudo apt upgrade -y

# Docker
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER && newgrp docker

# Node.js 22 (required — system default is too old)
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt install -y nodejs
node -v  # must be v22.x.x
```

### 2. Clone and build NemoClaw

```bash
git clone https://github.com/NVIDIA/NemoClaw.git
cd NemoClaw

# Apply remote dashboard fix (PR #114 — not yet merged upstream)
git remote add deepujain https://github.com/deepujain/NemoClaw.git
git fetch deepujain fix/20-remote-dashboard-bind
git cherry-pick deepujain/fix/20-remote-dashboard-bind

# Fix Dockerfile to include write-openclaw-gateway-config.py
sed -i 's|COPY scripts/nemoclaw-start.sh /usr/local/bin/nemoclaw-start|COPY scripts/ /usr/local/bin/\nCOPY scripts/nemoclaw-start.sh /usr/local/bin/nemoclaw-start|' Dockerfile

# Build TypeScript CLI
cd nemoclaw && npm install && npm run build && cd ..

# Install globally
sudo npm link
nemoclaw help  # verify install
```

### 3. Configure network policy

Before onboarding, add your LiteLLM endpoint to the sandbox policy:

```bash
cat >> ~/NemoClaw/nemoclaw-blueprint/policies/openclaw-sandbox.yaml << 'EOF'
  litellm_full:
    name: litellm_full
    endpoints:
      - host: <VM1-VLAN-IP>       # e.g. 192.168.x.x
        port: 4000
        access: full
    binaries:
      - { path: /usr/local/bin/openclaw }
      - { path: /usr/bin/curl }
      - { path: /usr/local/bin/node }
  wttr:
    name: wttr
    endpoints:
      - host: wttr.in
        port: 443
        access: full
    binaries:
      - { path: /usr/local/bin/openclaw }
      - { path: /usr/bin/curl }
EOF
```

> ⚠️ **Critical**: Network policies are locked at sandbox creation. You cannot add `network_policies` to a live sandbox without recreating it. Always update `openclaw-sandbox.yaml` before running `nemoclaw onboard`.

### 4. Run onboard wizard

```bash
nemoclaw onboard
# When asked for sandbox name: svclaw (or your preferred name)
# When asked for inference provider: select NVIDIA Cloud (we override this next)
```

### 5. Set LiteLLM as inference provider

> ⚠️ Run this **immediately** after onboard — onboard always resets inference to nvidia-nim.

```bash
# Create LiteLLM provider
openshell provider create \
  --name litellm \
  --type openai \
  --credential "api_key=<LITELLM_MASTER_KEY>" \
  --config "base_url=http://<VM1-VLAN-IP>:4000"

# Set as active inference route
openshell inference set \
  --provider litellm \
  --model groq/openai/gpt-oss-20b \
  --no-verify

# Verify
openshell inference get
```

### 6. Fix openclaw.json inside sandbox

The sandbox image hardcodes NVIDIA as the provider. Update it:

```bash
nemoclaw svclaw connect

# Inside sandbox — run this Python script:
python3 << 'EOF'
import json
with open('/sandbox/.openclaw/openclaw.json', 'r') as f:
    config = json.load(f)

LITELLM_IP = "<VM1-VLAN-IP>"
LITELLM_KEY = "<LITELLM_MASTER_KEY>"
MODEL = "groq/openai/gpt-oss-20b"

config['models']['providers'] = {
    'litellm': {
        'baseUrl': f'http://{LITELLM_IP}:4000',
        'apiKey': LITELLM_KEY,
        'api': 'openai-completions',
        'models': [{
            'id': MODEL,
            'name': 'GPT OSS 20B via LiteLLM',
            'reasoning': False,
            'input': ['text'],
            'cost': {'input': 0, 'output': 0, 'cacheRead': 0, 'cacheWrite': 0},
            'contextWindow': 131072,
            'maxTokens': 4096
        }]
    }
}
config['agents']['defaults']['model']['primary'] = f'litellm/{MODEL}'
config['agents']['defaults']['models'] = {f'litellm/{MODEL}': {}}

with open('/sandbox/.openclaw/openclaw.json', 'w') as f:
    json.dump(config, f, indent=2)
print('done')
EOF
```

### 7. Test inference

```bash
# Still inside sandbox
openclaw agent --agent main --local \
  -m "what is 2+2?" \
  --session-id test1
```

Check LiteLLM dashboard on VM1 to confirm the request was logged with spend tracking.

---

## Remote Web UI (Control Dashboard)

OpenClaw's web UI runs inside the sandbox on port 18789.

### Setup (one-time)

**Inside sandbox** — start gateway bound to all interfaces:
```bash
openclaw gateway stop 2>/dev/null; sleep 1
openclaw gateway --port 18789 --bind lan &
```

Also add your domain to `allowedOrigins` in `/sandbox/.openclaw/openclaw.json`:
```json
"gateway": {
  "controlUi": {
    "allowedOrigins": [
      "http://127.0.0.1:18789",
      "https://your-domain.com"
    ],
    "allowInsecureAuth": true,
    "dangerouslyDisableDeviceAuth": true
  }
}
```

**On VM host** — forward port with 0.0.0.0 bind:
```bash
openshell forward start 0.0.0.0:18789 svclaw -d
```

**NGINX config** (on your reverse proxy VM):
```nginx
server {
    listen 443 ssl;
    server_name svclaw.yourdomain.com;

    location / {
        proxy_pass http://<VM2-VLAN-IP>:18789;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

### Access

Get your token:
```bash
grep '"token"' /sandbox/.openclaw/openclaw.json
```

Open in browser (use `#token=` format due to [known bug #39611](https://github.com/openclaw/openclaw/issues/39611)):
```
https://your-domain.com/#token=<your-gateway-token>
```

---

## Model Selection

Not all models work with OpenClaw. Known working models via LiteLLM:

| Model | Provider | Notes |
|-------|----------|-------|
| `us.amazon.nova-lite-v1:0` | AWS Bedrock | ✅ Stable, recommended |
| `us.amazon.nova-pro-v1:0` | AWS Bedrock | ✅ Higher quality |
| `groq/llama-3.3-70b-versatile` | Groq | ⚠️ tool_use_failed occasionally |
| `groq/openai/gpt-oss-20b` | Groq | ❌ reasoning_content error |
| `groq/openai/gpt-oss-120b` | Groq | ❌ reasoning_content error |
| `us.anthropic.claude-sonnet-4-6` | AWS Bedrock | ⚠️ Sometimes hangs |

**Avoid models with `reasoning: true`** — Groq rejects `reasoning_content` in message history.

To change model inside sandbox:
```bash
python3 << 'EOF'
import json
MODEL = "us.amazon.nova-lite-v1:0"  # change this
with open('/sandbox/.openclaw/openclaw.json', 'r') as f:
    config = json.load(f)
config['models']['providers']['litellm']['models'][0]['id'] = MODEL
config['agents']['defaults']['model']['primary'] = f'litellm/{MODEL}'
config['agents']['defaults']['models'] = {f'litellm/{MODEL}': {}}
with open('/sandbox/.openclaw/openclaw.json', 'w') as f:
    json.dump(config, f, indent=2)
print('done')
EOF
```

---

## Known Issues & Workarounds

| Issue | Workaround |
|-------|-----------|
| `openshell inference set` ignores `base_url` | Hardcode `baseUrl` + `apiKey` directly in sandbox `openclaw.json` |
| `nemoclaw onboard` resets inference to nvidia-nim | Re-run `openshell inference set` immediately after every onboard |
| Cannot add network_policies to live sandbox | Update `openclaw-sandbox.yaml` before onboard, then recreate sandbox |
| network_policies YAML schema undocumented | Use `access: full` (not `protocol: rest`) for HTTP endpoints |
| Gateway TLS cert BadSignature after restart | `openshell gateway stop && openshell gateway start` |
| Session file locked | `rm -f /sandbox/.openclaw/agents/main/sessions/*.lock` |
| "device identity required" in Control UI | Use `#token=` URL format (not `?token=`). See [#39611](https://github.com/openclaw/openclaw/issues/39611) |
| k3s instability / sandbox provisioning timeout | Upgrade to 8GB RAM. Retry `nemoclaw onboard` after clean state |
| `reasoning_content` error with Groq models | Use non-reasoning models (Nova Lite, Llama 3.3) |
| Node.js too old (system default 12) | Use NodeSource `setup_22.x` — requires Node 22+ |

### Full state reset (nuclear option)

```bash
docker stop $(docker ps -q --filter "name=openshell") 2>/dev/null
docker rm $(docker ps -aq --filter "name=openshell") 2>/dev/null
docker volume rm $(docker volume ls -q --filter "name=openshell") 2>/dev/null
rm -rf ~/.config/openshell/ ~/.nemoclaw/
nemoclaw onboard
```

---

## Post-Onboard Checklist

Every time you run `nemoclaw onboard`, complete these steps:

```bash
# 1. Set inference provider
openshell inference set \
  --provider litellm \
  --model us.amazon.nova-lite-v1:0 \
  --no-verify

# 2. Apply network policy
openshell policy set svclaw \
  --policy ~/NemoClaw/nemoclaw-blueprint/policies/openclaw-sandbox.yaml \
  --wait

# 3. Connect and fix openclaw.json
nemoclaw svclaw connect
# Run the Python fix script (see Installation step 6)

# 4. Start gateway for web UI
openclaw gateway --port 18789 --bind lan &

# 5. Forward port
# (from VM host, separate terminal)
openshell forward start 0.0.0.0:18789 svclaw -d
```

---

## Architecture Notes

### Why a separate VM?

NemoClaw's OpenShell runtime uses k3s (lightweight Kubernetes) inside Docker, requiring `SYS_ADMIN` + `NET_ADMIN` capabilities and Docker socket access. Running this on the same VM as your LiteLLM stack creates unacceptable security risks — a NemoClaw container would have full Docker daemon control over your production stack.

### Two-layer security model

```
Layer 1 — OpenShell (software):
  Agent-level policy enforcement
  Egress allowlist via YAML
  Inference credential injection
  Filesystem confinement (/sandbox, /tmp only)

Layer 2 — Equinix Fabric (network):
  Private VLAN connectivity
  NemoClaw ↔ LiteLLM traffic never hits public internet
  LiteLLM port 4000 not exposed externally
```

### OpenShell component map

```
openshell gateway (Docker container)
  └── k3s cluster
        ├── openshell pod (gateway control plane, gRPC :8080)
        └── svclaw pod (sandbox)
              ├── OpenClaw agent (Node.js)
              ├── NemoClaw plugin (/opt/nemoclaw)
              ├── Egress proxy (Squid :3128) ← intercepts all outbound traffic
              └── inference.local ← virtual endpoint, intercepted by OpenShell
```

---

## References

- [NVIDIA NemoClaw](https://github.com/NVIDIA/NemoClaw)
- [NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell)
- [NemoClaw Docs](https://docs.nvidia.com/nemoclaw/latest/)
- [OpenShell Docs](https://docs.nvidia.com/openshell/latest/)
- [OpenClaw](https://github.com/openclaw/openclaw)
- [PR #114 — Remote dashboard bind fix](https://github.com/NVIDIA/NemoClaw/pull/114)
- [Issue #39611 — device identity required bug](https://github.com/openclaw/openclaw/issues/39611)
- [GTC 2026 NemoClaw announcement](https://nvidianews.nvidia.com/news/nvidia-announces-nemoclaw)

---

## License

Apache 2.0 — same as upstream NemoClaw.
