# POC: Passing User Code to a MicroVM — What Was Done

**Date:** 2026-09-15 · **Cell:** sfo3-staging · **Team:** 5186275
**Result: the full mechanism works. User code was passed into a microVM, ran, survived pause/resume, and traveled inside a snapshot into new VMs.**

---

## The story in simple words (read this first)

The image did **not** contain the function code. The image contained only a small "mailbox" program (the receiver). The function code came later, separately. That separation is the whole trick:

- **Image** = an empty house with a mailbox → built once
- **Function code** = a letter → delivered to the mailbox after the house exists

What happened, start to finish:

1. Two tiny programs were written: the **mailbox** (receiver) and a fake customer function (**hello**).
2. Only the mailbox went into an image. The image was uploaded to a registry (DOCR).
3. The platform built a VM from that image. The VM booted with the mailbox running inside, listening. At this point the VM contained **no user code**.
4. The hello function was sent to the mailbox: one HTTP upload. The mailbox saved it and started it. **← This is how user code is passed to a microVM.**
5. The function was called → it answered `hello from user function v1`. Proof it runs inside.
6. The VM was paused, woken, and called again → it still answered, with nothing re-sent. The code stays inside through sleep.
7. A **snapshot** of the VM was taken, with the code loaded inside it.
8. A brand-new VM was built from that snapshot and called → it answered immediately, even though **nobody ever sent code to this new VM**. The code arrived inside the snapshot.

Why three VMs appear in this log:

- **VM #1** — first try. The mailbox had a small bug (the minimal image had no `/dev/null` file), so it could not start the function. Fixed in image v2. Deleted.
- **VM #2** — the fixed one. Steps 4–7 happened here. Still alive, for demos.
- **VM #3 (the clone)** — created from the snapshot only to prove step 8. Proof done. Deleted.

The outcome in one line: **user code can be passed to a microVM in two proven ways — over HTTP once at deploy time (into the mailbox), and inside a snapshot forever after.** Today's Functions sends code into a fresh container on every cold start (the >1 second problem). In this model code moves once per deploy, and starting the function later is just waking a snapshot — a fraction of a second.

## The goal

Prove, with real commands against the real platform, that user code can get into a microVM. The production design has three steps (standard image → send code once at deploy → checkpoint). The POC does all three by hand. The new control-plane service is NOT needed for the POC — the POC *is* the manual version of what that service will automate later.

## The two small programs written for the POC

Both live in `~/fn-poc/`:

1. **The receiver** (`~/fn-poc/receiver/main.go`, ~110 lines of Go) — the "mailbox" that lives inside the VM. It listens on two ports:
   - **8081 (control):** `POST /swap` accepts a binary in the request body, saves it, runs it. `GET /status` reports what is loaded.
   - **8080 (traffic):** forwards every request to the running function.
2. **The hello function** (`~/fn-poc/hellofn/main.go`, ~20 lines) — pretends to be customer code. Answers `hello from user function v1`.

Both compiled for the VM's processor (the VMs are Linux x86-64, laptops are not):

```bash
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o receiver .   # in receiver/
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o hellofn .    # in hellofn/
```

## Step 1 — Package the receiver into an image (done on the laptop, with OrbStack)

OrbStack is only the local build tool (a Docker Desktop replacement). The `Dockerfile` is 4 lines:

```dockerfile
FROM scratch
COPY receiver /receiver
EXPOSE 8080 8081
ENTRYPOINT ["/receiver"]
```

```bash
docker build --platform linux/amd64 -t registry.digitalocean.com/custom-images-dev-rbalabadra/fn-receiver:v2 .
```

## Step 2 — Push the image to a registry (DOCR, not Docker Hub)

**Why a registry at all:** the microVM platform does not accept image files. It only accepts a URL and *downloads* the image itself. An image inside OrbStack on a laptop is invisible to it.

**Why DOCR and not Docker Hub:** the first plan was a public Docker Hub repo (teammates did that). Docker Hub login failed with work credentials. So the image went to DigitalOcean's own registry (DOCR) instead:

```bash
doctl registry create custom-images-dev-rbalabadra --subscription-tier starter
doctl registry login
docker push registry.digitalocean.com/custom-images-dev-rbalabadra/fn-receiver:v2
```

Result: `v2: digest: sha256:556f8c2f... Pushed`. Verify anytime with `doctl registry repository list-v2`.

**The extra step DOCR forced:** DOCR registries are private, so the platform could not download from it ("registry requires authentication"). Fix: register a read-only pull credential with the platform (this is a supported feature, the same one real customers with private registries use):

```bash
# mint a read-only DOCR token, then:
grpcurl -cert ~/.ssh/staff.crt -key ~/.ssh/staff.key \
  -import-path proto -import-path <dir with buf/validate/validate.proto> \
  -proto microvm/v1/images.proto \
  -d '{"credential": {"team_id": 5186275, "name": "fn-poc-docr-readonly",
       "registry_host": "registry.digitalocean.com/custom-images-dev-rbalabadra"},
       "auth_token": "<read-only DOCR token>"}' \
  microvm-controller-sfo3-staging.apis.internal.digitalocean.com:443 \
  microvm.v1.RegistryCredentialService/CreateRegistryCredential
```

Result: credential `01a0a3a6-30fd-70e1-9d11-a64b6028c87d` registered.

## Step 3 — Tell the platform to import the image

```bash
grpcurl -cert ~/.ssh/staff.crt -key ~/.ssh/staff.key \
  -import-path proto -import-path <validate.proto dir> -proto microvm/v1/images.proto \
  -d '{"image": {"name": "fn-receiver-v2", "team_id": 5186275,
       "source": {"oci": {"image_ref": "registry.digitalocean.com/custom-images-dev-rbalabadra/fn-receiver:v2"}}},
       "registry_credential_id": "01a0a3a6-30fd-70e1-9d11-a64b6028c87d"}' \
  microvm-controller-sfo3-staging.apis.internal.digitalocean.com:443 \
  microvm.v1.ImageService/CreateImage
```

Result: `image_id = 01a0a3ac-a2e3-7abd-aca7-da5833786030`. The platform downloaded the image and converted it into a bootable VM disk.

## Step 4 — Create the VM and start it

Two ports declared: 8080 for traffic, 8081 for the mailbox.

```bash
grpcurl ... -proto microvm/v1/microvm.proto \
  -d '{"micro_vm": {"name": "fn-poc-receiver-v2", "team_id": 5186275,
       "image_id": "01a0a3ac-a2e3-7abd-aca7-da5833786030",
       "size": {"slug": {"slug": "mv-1vcpu-256mb"}},
       "network": {"http_ingress_port": 8080, "additional_ingress_ports": [{"port": 8081}]}}}' \
  ... microvm.v1.MicroVMService/CreateMicroVM
# → microvm_id = 01a0a3ae-4e90-760b-8e51-87b346ef5ddb, READY in ~15s

grpcurl ... -d '{"execution": {"microvm_id": "01a0a3ae-4e90-760b-8e51-87b346ef5ddb"}}' \
  ... microvm.v1.MicroVMExecutionService/CreateMicroVMExecution
# → execution_id = 01a0a3ae-ac54-7c28-b3a6-4659a7992211, guest_ready ~1s
```

## Step 5 — THE DEMO: pass the user code

One curl. The body carries the 8.6 MB function binary. The headers are only the address. The staff certificate is required (the ingress rejects plain requests with "RBAC: access denied").

```bash
curl -sS -X POST --data-binary @~/fn-poc/hellofn/hellofn \
  --cert ~/.ssh/staff.crt --key ~/.ssh/staff.key \
  -H "region: sfo3" -H "cell: staging" \
  -H "x-microvm-id: 01a0a3ae-4e90-760b-8e51-87b346ef5ddb" \
  -H "x-execution-id: 01a0a3ae-ac54-7c28-b3a6-4659a7992211" \
  -H "x-microvm-dst-port: 8081" \
  https://microvm-activator-sfo3-staging.apis.internal.digitalocean.com/swap
```

Result:
```json
{"loaded":true,"sha256":"27d88fd7b80e...","bytes":8616176}
```

Then invoke the function (same address, traffic port, no dst-port header):

```bash
curl -sS --cert ~/.ssh/staff.crt --key ~/.ssh/staff.key \
  -H "region: sfo3" -H "cell: staging" \
  -H "x-microvm-id: 01a0a3ae-..." -H "x-execution-id: 01a0a3ae-ac54-..." \
  https://microvm-activator-sfo3-staging.apis.internal.digitalocean.com/
```

Result (0.8 s):
```
hello from user function v1 | host=192.168.240.2 | time=2026-09-15T06:09:47Z
```

**User code, passed over HTTP into a Firecracker microVM, running.**

## Step 6 — Prove the code survives pause and wake

```bash
grpcurl ... PauseMicroVMExecution     # state → STATE_PAUSED
grpcurl ... ResumeMicroVMExecution
curl ... /                            # same invoke as above, NO re-upload
```

Result (0.88 s): `hello from user function v1 ...` — the code stayed in the VM's memory across the pause. Nothing was re-sent.

(One surprise: sending a request to the *paused* VM returned `Not Found` instead of waking it automatically. Explicit resume works. Question for the microVM team.)

## Step 7 — Prove the snapshot carries the code

```bash
# 1. checkpoint the loaded VM
grpcurl ... -proto microvm/v1/checkpoint.proto \
  -d '{"checkpoint": {"microvm_id": "01a0a3ae-...", "execution_id": "01a0a3ae-ac54-...", "name": "fn-poc-cp"}}' \
  ... microvm.v1.MicroVMCheckpointService/CreateMicroVMCheckpoint
# → checkpoint_id = 01a0a3b1-e47e-78a2-a5db-3dd410ea765f → poll until STATE_COMPLETE

# 2. create a BRAND NEW VM from the checkpoint (note: checkpoint_id, no image_id)
grpcurl ... -d '{"micro_vm": {"name": "fn-poc-clone", "team_id": 5186275,
     "checkpoint_id": "01a0a3b1-e47e-...", "size": {"slug": {"slug": "mv-1vcpu-256mb"}},
     "network": {"http_ingress_port": 8080, "additional_ingress_ports": [{"port": 8081}]}}}' \
  ... microvm.v1.MicroVMService/CreateMicroVM
# → READY instantly; execution guest_ready in ~2s

# 3. invoke the clone — remember: NO code was ever sent to this VM
curl ... /          # with the CLONE's microvm-id and execution-id headers
```

Result (1.4 s): `hello from user function v1 ...`

And the receiver's status on the clone:
```json
{"loaded":true,"sha256":"27d88fd7b80e..."}
```

The sha256 is **identical** to the binary uploaded to the original VM in step 5. The clone never received a POST. **The code arrived inside the snapshot.** This is the scale-from-zero path of the production design, proven.

## Results summary

| What | Time | Meaning |
|---|---|---|
| Code delivery (8.6 MB POST) | 42 s | laptop upload over VPN; once per deploy, never per request |
| Invoke, warm | 0.8 s | round trip from laptop included |
| Invoke after pause → resume | 0.88 s | code persisted, no re-upload |
| Clone from checkpoint → serving | ~2 s | brand-new VM, zero code delivery |
| Checkpoint capture | ~3 min to COMPLETE | one-time deploy cost, async |

## Resources still live (for a live team demo)

| Resource | ID |
|---|---|
| MicroVM `fn-poc-receiver-v2` (function loaded) | `01a0a3ae-4e90-760b-8e51-87b346ef5ddb` |
| Execution | `01a0a3ae-ac54-7c28-b3a6-4659a7992211` |
| Checkpoint `fn-poc-cp` | `01a0a3b1-e47e-78a2-a5db-3dd410ea765f` |
| Image `fn-receiver-v2` | `01a0a3ac-a2e3-7abd-aca7-da5833786030` |
| DOCR image | `registry.digitalocean.com/custom-images-dev-rbalabadra/fn-receiver:v2` |

The clone and the broken v1 VM were deleted.

## Gotchas found on the way (worth sharing)

1. The activator ingress requires **mTLS** (staff cert on curl), else `RBAC: access denied`.
2. A `FROM scratch` image has **no /dev/null** — Go's `exec` needs the child's stdin set explicitly (v1 receiver bug, fixed in v2).
3. Wake-on-request returned 404 for a paused execution via the header path — explicit resume works. Ask the microVM team.
4. `microvmctl` CLI bugs: `bench` subcommand `--cell` shadows the global flag; `image create` lacks `--team-id`, which breaks private-registry credential matching.
5. The macOS keychain held an old service credential for `registry.digitalocean.com` that silently overrode `doctl registry login`.

## How the POC maps to the production design

| Production design | POC version of it |
|---|---|
| Standard image per runtime | `fn-receiver:v2` image (built once) |
| New control-plane service does deploys | The grpcurl/curl commands above, run by hand |
| Checkpoint per function version | `fn-poc-cp`, and the clone proves it works |

The POC changes nothing about the design. It replaces "should work" with "works".

## Glossary — the terms used in this doc

**MicroVM** — a very small, fast virtual machine. On this platform it is also the name of the *template* object: the saved definition (image, size, ports, policies) from which real VMs are launched. Think: the recipe.

**Execution** — the actual running virtual machine, launched from a microVM template. It is the thing that serves traffic. One template can have many executions. Think: a dish cooked from the recipe.

**Firecracker** — the open-source technology (from AWS) that runs these tiny VMs. It starts VMs in milliseconds instead of minutes. The platform runs one Firecracker VM per execution.

**Image** — a frozen copy of a machine's disk: the operating files plus whatever programs were baked in. VMs boot from an image. Built with Docker, same as a container image.

**Registry / DOCR** — a warehouse on the internet where images are uploaded so other machines can download them. DOCR is DigitalOcean's own registry (`registry.digitalocean.com`). The microVM platform cannot take an image file directly — it only downloads from a registry.

**Receiver ("the mailbox")** — the small program written for this POC that lives inside every function VM. It waits for code to arrive over HTTP (`POST /swap`), saves it, runs it, and forwards traffic to it. Not a platform feature — our code.

**Ingress / activator** — the platform's front door. All HTTP traffic to any microVM enters through one address per region (`microvm-activator-<region>-<cell>...`) and gets routed to the right VM using request headers (`x-microvm-id`, `x-execution-id`).

**Pause** — what the platform does to an idle execution (default: after 5 minutes without traffic). The VM stops using CPU and stops billing, but keeps its exact state. Like closing a laptop lid.

**Resume / wake** — reopening the lid: the paused execution continues exactly where it stopped, in a few hundred milliseconds. Programs inside do not restart — they continue.

**Checkpoint (snapshot)** — a saved copy of a running VM's complete state: its memory (everything programs have loaded) AND its disk (all files), frozen at one moment. Like a save point in a video game. Two uses: (1) the platform makes one automatically when pausing, so waking is fast; (2) one can be made on demand and used as the source for brand-new VMs — which are then *born* with everything the original had, including our loaded function code.

**Spaces** — DigitalOcean's object storage (like Amazon S3): a big, cheap, durable file locker. Checkpoints are chopped into chunks and stored there. A VM being restored streams the chunks it needs, like streaming a movie instead of downloading it first.

**Clone** — a new microVM created *from a checkpoint* instead of from an image. It starts as an exact copy of the checkpointed VM. This is how one function can get many identical VMs instantly (traffic spikes), and how a function comes back after its VM was cleaned up.

**guest_ready** — the platform's flag that says "the program inside the VM is up and answering." The VM being "running" is not enough — this flag is what says traffic can be served.

**mTLS / staff certificate** — mutual TLS: both sides of a connection show certificates. All platform APIs (and the ingress) require the caller to present one; the staff certificate (`~/.ssh/staff.crt`) is the personal one used in this POC. Without it: "RBAC: access denied".

**Cold start** — the delay when a function is invoked but nothing is ready to run it. Today (containers): >1 second, because a container must be created and the code copied in. With microVMs: a few hundred milliseconds, because "starting" is just waking a snapshot that already contains everything.

**CouchDB** — the database where today's Functions stores code, read on every cold start (slow). In the new design it leaves the request path entirely: code lives in Spaces and inside checkpoints.

**gVisor** — the sandbox layer today's Functions uses to isolate customer containers from the shared kernel. Not needed in the new design: Firecracker VMs have their own kernels, which is stronger isolation.
