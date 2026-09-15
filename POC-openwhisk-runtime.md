# POC Iteration 2: OpenWhisk Go Runtime as the MicroVM Receiver

**Date:** 2026-09-15 · **Cell:** sfo3-staging · **Team:** 5186275
**Result: all steps passed. The OpenWhisk Go runtime works as the in-guest receiver, inside a real microVM, with better numbers than the custom receiver.**

---

## Why this iteration exists

Iteration 1 ([POC.md](POC.md)) proved the code-passing mechanism with a custom-written receiver ("the mailbox"). The team then decided the production receiver should not be custom code. It should be the **OpenWhisk Go runtime image** — the same `/init` + `/run` program that Functions containers run today under gVisor. Not full OpenWhisk, not containers inside VMs: just that one runtime process as the VM's workload.

This iteration reruns the whole experiment with that image. The passing mechanism is unchanged. Only the receiver changed.

## Why the OpenWhisk runtime is the better receiver

1. **The customer programming model is unchanged.** Functions customers write `Main(args) → result`, not web servers. The runtime runs exactly that shape. The custom receiver could only host full HTTP servers, which is a different product.
2. **Deploy artifacts already fit.** Today's pipeline packages code in the exact format `/init` expects (base64 zip). Zero format conversion.
3. **Nothing new to maintain.** The runtime is battle-tested upstream and in serverless/main. The custom receiver would be new code owned forever.
4. **Simpler setup.** The image is public on docker.io, so `CreateImage` needs no registry credential. One port (8080) serves both `/init` and `/run`, so no additional ingress port and no `x-microvm-dst-port` header.

## What changed vs iteration 1

| Piece | Iteration 1 (custom receiver) | Iteration 2 (OpenWhisk runtime) |
|---|---|---|
| Image | `fn-receiver:v2` (5 MB, private DOCR) | `docker.io/openwhisk/action-golang-v1.23` (1.1 GB, public) |
| Registry credential | required | not needed |
| Code delivery endpoint | `POST /swap` on port 8081 | `POST /init` on port 8080 |
| Delivery payload | raw binary | JSON: `{"value": {"code": "<base64 zip>", "binary": true, "main": "Main"}}` |
| Invocation | any HTTP request on 8080 | `POST /run {"value": {...}}` on 8080 |
| Ports on the VM | 2 | 1 |
| Everything else (create VM, guest_ready, ingress headers, mTLS, checkpoint, clone) | — | **identical** |

## The run, step by step

### 1. Compile the action (what the deploy service will do per deploy)

The runtime image is its own compiler:

```bash
docker run -i --rm --platform linux/amd64 openwhisk/action-golang-v1.23:latest \
  -compile Main < hello.go > hello-bin.zip
```

Result: an 846 KB zip containing `exec` + `exec.env` (the actionloop precompiled format).

The action source (`hello.go`) is a normal OpenWhisk Go action:

```go
package main

import "fmt"

func Main(args map[string]interface{}) map[string]interface{} {
    name, _ := args["name"].(string)
    if name == "" { name = "world" }
    return map[string]interface{}{
        "body": fmt.Sprintf("hello %s from an OpenWhisk action inside a microVM", name),
    }
}
```

### 2. Register the image (public ref, no credential)

```bash
grpcurl ... -proto microvm/v1/images.proto \
  -d '{"image": {"name": "ow-action-golang-v123", "team_id": 5186275,
       "source": {"oci": {"image_ref": "docker.io/openwhisk/action-golang-v1.23:latest"}}}}' \
  ... microvm.v1.ImageService/CreateImage
```

Result: `image_id = 01a0a58c-d2cb-779b-84d9-da211b0b11e2`. Ingest took ~7 minutes (1.1 GB image — the pipeline downloads, flattens, and uploads it once per runtime).

### 3. Create the VM and start it (single port)

```bash
grpcurl ... -d '{"micro_vm": {"name": "fn-poc-ow-runtime", "team_id": 5186275,
     "image_id": "01a0a58c-d2cb-...", "size": {"slug": {"slug": "mv-1vcpu-256mb"}},
     "network": {"http_ingress_port": 8080}}}' ... CreateMicroVM
# → microvm_id = 01a0a590-008a-7a7e-8d31-1ada3ba146bb, READY in 7 s

grpcurl ... -d '{"execution": {"microvm_id": "01a0a590-..."}}' ... CreateMicroVMExecution
# → execution_id = 01a0a590-6c9f-7ade-923f-74669ed4367d, guest_ready in 2 s
```

### 4. Pass the code: /init through the ingress

```bash
curl -sS --cert ~/.ssh/staff.crt --key ~/.ssh/staff.key \
  -H "region: sfo3" -H "cell: staging" \
  -H "x-microvm-id: 01a0a590-..." -H "x-execution-id: 01a0a590-6c9f-..." \
  -H "Content-Type: application/json" --data-binary @ow-init.json \
  https://microvm-activator-sfo3-staging.apis.internal.digitalocean.com/init
```

(`ow-init.json` = `{"value": {"name": "hellofn", "main": "Main", "binary": true, "code": "<base64 of hello-bin.zip>"}}`, 1.1 MB total.)

Result: `{"ok":true}` in **6.7 s** (payload upload from a laptop over VPN dominates).

### 5. Invoke: /run through the ingress

```bash
curl ... -d '{"value": {"name": "Rachana, inside a real microVM"}}' .../run
```

Result (**0.9 s**):
```json
{"body":"hello Rachana, inside a real microVM from an OpenWhisk action inside a microVM"}
```

### 6. Checkpoint

```bash
grpcurl ... CreateMicroVMCheckpoint  # name fn-poc-ow-cp
```

Result: `checkpoint_id = 01a0a591-4f76-7dee-8dac-f0d239a1f21e`, **STATE_COMPLETE in 6 seconds** (iteration 1 took ~3 minutes — the dirty state here is much smaller).

### 7. Clone from the checkpoint, run with zero code delivery

```bash
grpcurl ... -d '{"micro_vm": {"name": "fn-poc-ow-clone", "team_id": 5186275,
     "checkpoint_id": "01a0a591-4f76-...", "size": {"slug": {"slug": "mv-1vcpu-256mb"}},
     "network": {"http_ingress_port": 8080}}}' ... CreateMicroVM
# → READY instantly; execution guest_ready in 4 s

curl ... -d '{"value": {"name": "clone with zero code delivery"}}' .../run
```

Result (**2.3 s**, first request after restore):
```json
{"body":"hello clone with zero code delivery from an OpenWhisk action inside a microVM"}
```

No `/init` was ever sent to the clone. The initialized action arrived inside the snapshot.

### 8. Cleanup

The clone was deleted. Kept for live demos: VM `fn-poc-ow-runtime` (`01a0a590-008a-7a7e-8d31-1ada3ba146bb`) and checkpoint `fn-poc-ow-cp` (`01a0a591-4f76-7dee-8dac-f0d239a1f21e`).

## The numbers

| Event | Time | Note |
|---|---|---|
| Image ingest (once per runtime, ever) | ~7 min | 1.1 GB public image |
| VM template READY | 7 s | from image |
| Execution guest_ready | 2 s | runtime up, listening |
| `/init` with precompiled zip, via ingress | 6.7 s | 1.1 MB payload from laptop; in-DC this is sub-second |
| `/run` invocation | 0.9 s | laptop round trip included |
| Checkpoint COMPLETE | 6 s | one-time per function version |
| Clone: create → guest_ready | 4 s | zero code delivery |
| `/run` on clone, first request | 2.3 s | restore + lazy paging |

Local measurements (OrbStack, same image) that set production rules:

| Measurement | Result | Rule |
|---|---|---|
| `/init` with source code | 8.9 s (compiles in-guest) | Never init with source |
| `/init` with precompiled zip | **87 ms** | Always compile at deploy time |
| Second `/init` on the same runtime | 403 "Cannot initialize the action more than once." | New function version = new VM + init + checkpoint. No hot-swap into a warm VM. |

## Watch-outs for the design review

1. **`/init` is once-per-lifetime** (verified with the 403). Perfect for init-once-then-checkpoint. It rules out re-initializing a warm VM with a new version.
2. **`/init` sits on the traffic port.** Anything that can reach port 8080 through the ingress can try `/init` on an uninitialized VM. Deploy-time init before routing is published mostly covers it, but it needs a deliberate security decision (especially with public ingress URLs later).
3. **Image size:** 1.1 GB because the image bundles the Go toolchain for compile-at-init — which is never needed when initing with binaries. Evaluate the slimmer `actionloop-golang` base: faster ingest, smaller rootfs, smaller checkpoints.
4. Requests to a **paused** execution still return 404 instead of auto-waking (same as iteration 1). Explicit `ResumeMicroVMExecution` works. Open question for the microVM team.

## Verdict

The OpenWhisk Go runtime is the right receiver for Functions on microVMs. The task-2 passing mechanism is unchanged and now proven twice — with a custom receiver and with the production-intended one. Customers, deploy formats, and invocation semantics carry over from today's Functions with no changes.
