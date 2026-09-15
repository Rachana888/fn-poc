# gRPC Guide: Interacting with the MicroVM Platform

Task 3 of the Functions × MicroVM project. Every RPC below marked ✅ was exercised for real during the task-2 POC (2026-09-15, sfo3-staging). Shapes and errors come from the actual calls, not from reading docs.

---

## 1. The basics

**Protocol:** gRPC over mTLS. No REST, no OpenAPI. Every call presents a client certificate.

**Endpoint (one per cell):**
```
microvm-controller-<region>-<cell>.apis.internal.digitalocean.com:443
```
Example: `microvm-controller-sfo3-staging.apis.internal.digitalocean.com:443`. There is no cell field in any request body — the hostname selects the cell.

**Auth:**
- Humans: Turtle staff certificate. `staff-cert create --ttl 90` writes `~/.ssh/staff.crt` and `~/.ssh/staff.key`. The API load balancer accepts the `<user>.microvm.staff.digitalocean.com` SAN.
- Services (the future invoker): a Sammy-issued service certificate with SANs registered in the MicroVM API load balancer config. This registration is a to-do for productionization.

**Team scoping:** every object belongs to a `team_id` (Functions POC used `5186275`). Lookups, lists, and credential matching are all scoped to the caller's team. Forgetting `team_id` does not error — it silently matches nothing (bit the POC once, see §7).

**Proto files:** `proto/microvm/v1/` in the microvm repo — `microvm.proto`, `images.proto`, `checkpoint.proto`, `ingress.proto`. Generated Go stubs: `gen/microvm/v1` (import `github.internal.digitalocean.com/digitalocean/microvm/gen/microvm/v1`). The future invoker imports these directly.

**Three ways to call:**
1. **Go stubs** — for services (see the code example in the platform wiki, `docs/usage/code-example`).
2. **grpcurl** — for scripts and exploration. Run from the microvm repo root; `images.proto` and `checkpoint.proto` also need `buf/validate/validate.proto` on a second `-import-path` (grab it from github.com/bufbuild/protovalidate).
3. **microvmctl** — the CLI wrapper (`./bin/microvmctl`). Convenient but has two known bugs (§7).

grpcurl template used throughout the POC:
```bash
grpcurl -cert ~/.ssh/staff.crt -key ~/.ssh/staff.key \
  -import-path proto [-import-path <dir-with-buf/validate>] \
  -proto microvm/v1/<file>.proto \
  -d '<json>' \
  microvm-controller-sfo3-staging.apis.internal.digitalocean.com:443 \
  microvm.v1.<Service>/<Method>
```

Note: the server does NOT support gRPC reflection — the proto files are mandatory.

---

## 2. MicroVMService — VM templates ✅

The microVM object is a template; executions launch from it.

| RPC | Used in POC | Notes |
|---|---|---|
| `CreateMicroVM` | ✅ | See fields below. Returns immediately with `STATE_CREATING`; poll `GetMicroVM` until `STATE_READY` (~15 s from an image, instant from a checkpoint). |
| `GetMicroVM` | ✅ | Takes an id oneof: `{"microvm_id": "..."}` or `{"name": "..."}`. |
| `ListMicroVMs` | ✅ | Filter: `{"team_id": N}`; supports `labels`, `page_size`, `page_token`. |
| `DeleteMicroVM` | ✅ | Also deletes all executions. Returns before cleanup finishes. |

`CreateMicroVM` — the fields that mattered in the POC:
```json
{"micro_vm": {
  "name": "fn-poc-receiver-v2",              // [a-z0-9-], 1-63 chars, unique per cell
  "team_id": 5186275,                         // required
  "image_id": "01a0a3ac-...",                 // oneof source: image_id OR checkpoint_id
  "size": {"slug": {"slug": "mv-1vcpu-256mb"}},  // REQUIRED even with checkpoint_id
  "network": {
    "http_ingress_port": 8080,                // main traffic port (default 80)
    "additional_ingress_ports": [{"port": 8081}]  // up to 5; unlisted ports are rejected at the edge
  },
  "environment": {"KEY": "value"},            // env vars for the guest (config-sized only)
  "execution_policy": {                       // all optional
    "auto_resume_on_request": true,           // default true
    "execution_idle_timeout": "300s",         // default 5m, HARD CEILING 4h
    "min_warm_executions": 0,
    "max_executions": 0
  }
}}
```
Validation errors observed: `micro_vm.size.slug is required` (even for checkpoint clones); idle timeout above 4h fails with InvalidArgument.

---

## 3. MicroVMExecutionService — running VMs ✅

| RPC | Used in POC | Notes |
|---|---|---|
| `CreateMicroVMExecution` | ✅ | `{"execution": {"microvm_id": "..."}}`. Poll list until `guest_ready: true` — `STATE_RUNNING` alone is not enough to serve traffic. |
| `ListMicroVMExecutions` | ✅ | `{"microvm_id": "..."}`. The poll target. |
| `GetMicroVMExecution` | — | `microvm_id` + `execution_id`. |
| `PauseMicroVMExecution` | ✅ | State → `STATE_PAUSED` in ~1 s. Captures a checkpoint; memory stays resident on the host. |
| `ResumeMicroVMExecution` | ✅ | Async: the RPC returns after *starting* the resume (~300 ms), not after the guest is ready. Time `guest_ready`, not the RPC. |

Key learning: **resume worked on a 2-day-paused execution** despite an internal doc saying 24 h is the limit — but plan for recreate-from-checkpoint anyway.

---

## 4. ImageService + RegistryCredentialService ✅

| RPC | Used in POC | Notes |
|---|---|---|
| `CreateImage` | ✅ | Synchronous: pulls the OCI image, flattens to a bootable disk, uploads to Spaces. ~25 s for a 5 MB image; use a 10-minute RPC deadline for real images. Failures are NOT auto-retried. |
| `GetImage` / `ListImages` | ✅ | Straightforward. |
| `CreateRegistryCredential` | ✅ | For private registries (DOCR/GHCR): a token is enough. `registry_host` may be repo-scoped (`registry.digitalocean.com/custom-images-dev-rbalabadra`) — longest prefix wins. Token accepted only on create, never echoed back. |
| `List/Get/DeleteRegistryCredential` | — | Metadata only; never returns tokens. |

`CreateImage` with a private registry — both of these are required or the pull fails with `FailedPrecondition: registry requires authentication`:
```json
{"image": {"name": "fn-receiver-v2", "team_id": 5186275,
  "source": {"oci": {"image_ref": "registry.digitalocean.com/.../fn-receiver:v2"}}},
 "registry_credential_id": "01a0a3a6-..."}
```
Auto-match of credentials by registry host works only when the request carries the right `team_id` (§7, CLI bug).

---

## 5. MicroVMCheckpointService ✅

| RPC | Used in POC | Notes |
|---|---|---|
| `CreateMicroVMCheckpoint` | ✅ | `{"checkpoint": {"microvm_id": ..., "execution_id": ..., "name": ...}}`. Returns immediately in `STATE_CREATING`; capture + upload runs in background. |
| `GetMicroVMCheckpoint` | ✅ | Requires **both** `microvm_id` and `checkpoint_id` (checkpoint_id alone → `InvalidArgument: microvm_id is required`). |
| `ListMicroVMCheckpoints` | — | Per microVM. |
| `DeleteMicroVMCheckpoint` | — | Checkpoints also carry an optional TTL. |

States: `STATE_CREATING → STATE_UPLOADING → STATE_COMPLETE` (POC: ~3 min). Only a `STATE_COMPLETE` checkpoint can be used as a `CreateMicroVM` source.

---

## 6. Not gRPC, but part of "interacting": the data plane

Invoking the guest is plain HTTPS, not gRPC — but it needs mTLS and exact headers:

```bash
curl --cert ~/.ssh/staff.crt --key ~/.ssh/staff.key \
  -H "region: sfo3" -H "cell: staging" \
  -H "x-microvm-id: <id>" -H "x-execution-id: <id>" \
  [-H "x-microvm-dst-port: 8081"] \
  https://microvm-activator-<region>-<cell>.apis.internal.digitalocean.com/<path>
```

- No client cert → `RBAC: access denied`. Missing region/cell → HTTP 400.
- `x-microvm-dst-port` selects an additional ingress port; omitting it targets the main port.
- **Open issue:** a request to a *paused* execution returned `404 Not Found` instead of auto-waking it (policy `auto_resume_on_request: true`). Explicit `ResumeMicroVMExecution` works. Ask the microVM team whether wake-on-request needs a different path (possibly `MicroVMIngressService` URLs).

**MicroVMIngressService** (`ingress.proto`) — not yet exercised: publishes a public per-microVM hostname (`<label>.<region>.sandbox|microdroplet.ondigitalocean.com`) through Oceanus, bound to an execution, PAT-authenticated. Likely the production invoke path; the first candidate for task 4 investigation.

---

## 7. Gotchas (all hit for real)

1. **microvmctl `image create` lacks `--team-id`** → the request goes out unscoped → private-registry credentials never match → misleading `FailedPrecondition`. Workaround: grpcurl with explicit `team_id` + `registry_credential_id`. (CLI bug to report.)
2. **microvmctl bench subcommands' local `--cell` flag shadows the global one** → endpoint/headers never derive. Workaround: pass `--endpoint` in full plus `--region`/`--cell` separately. (CLI bug to report.)
3. **grpcurl needs `buf/validate/validate.proto`** for `images.proto`/`checkpoint.proto` — not vendored in the repo; fetch the current one from github.com/bufbuild/protovalidate (older copies fail on `IGNORE_IF_ZERO_VALUE`).
4. **No server reflection** — always pass `-proto` + `-import-path`.
5. **`GetMicroVMCheckpoint` needs `microvm_id` too**, not just the checkpoint id.
6. **`size.slug` is required even when creating from a checkpoint.**
7. **Resume/Create RPCs are async** — completion signals are `guest_ready` (executions), `STATE_READY` (templates), `STATE_COMPLETE` (checkpoints). Always poll the state, never trust the RPC returning.
8. **Delete returns before cleanup** — do not recreate the same name immediately after a delete.

## 8. Coverage map for this task

Exercised end to end: MicroVMService (4/4 RPCs), MicroVMExecutionService (4/5), ImageService (3/3 used), RegistryCredentialService (1/4, the important one), MicroVMCheckpointService (2/4).
Not yet exercised: `MicroVMIngressService` (all), checkpoint list/delete, credential list/delete, `GetMicroVMExecution`. None block Functions integration; the ingress service is the one worth a dedicated look (task 4 overlap).
