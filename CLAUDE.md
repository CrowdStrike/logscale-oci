# OCI LogScale CI/CD Pipeline - Agent Notes

## No Cross-Cloud References — Absolute Rule

This is a standalone OCI deployment. Never introduce:
- References to other cloud providers' implementations (AWS, Azure, GCP LogScale deployments)
- Pattern comparisons like "Following the same pattern as AWS/GCP" or "Consistent with Azure"
- Internal infrastructure names (Argo hostnames, worker IDs, internal domains)
- Sister pipeline details or deployment topologies from other repos
- Timing/performance comparisons against other cloud providers' DR implementations

**What IS allowed:**
- OCI's own S3-compatible API (the env vars `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` are LogScale's actual config names — that's not a cross-cloud reference)
- "External vantage points" for OCI Health Checks (without naming which clouds host them)
- LogScale upstream documentation references that happen to mention S3

**Why:** This repo is open-source reference architecture. Cross-cloud comparisons leak internal implementation details, create maintenance burden when sister repos diverge, and confuse users who only deploy on OCI.

## Handover rules

When changes are needed in the Argo CI/CD repo (gitlab-logscale-cicd) — workflow templates, tfvars, worker configs, or any CICD pipeline logic — do not attempt them here. Instead, write the required changes to a plan file at `.claude/plans/logscale-cicd.md` so the next session working in that repo can pick them up.

This includes changes made HERE that have CICD implications:
- New or renamed Terraform variables that the pipeline must pass via tfvars
- New modules or resources that need pipeline steps (CRDs, health checks, etc.)
- Provider or auth changes that affect how the workflow runs Terraform
- Verification steps the pipeline should perform after deploying

When you add a variable, module, or provider change in this repo, always check whether the CICD pipeline needs a corresponding update and write it to the plan file.

## Inbound Plan File

At session start, read the plan file from the CICD repo:
```
../gitlab-logscale-cicd/.claude/plans/logscale-oci.md
```

This file contains actionable items identified by the CICD pipeline session. Each item has a description, fix, and verification steps.

**Rules:**
- Read the plan file at the start of every session
- After implementing an item, delete that item's section from the plan file
- Do not add status markers or history — just delete completed items
- If the plan file exceeds 100 lines, flag it to the user before proceeding
- If the plan file doesn't exist or is empty, there's nothing to pick up

## Project Overview

This repo deploys OCI infrastructure + LogScale for CrowdStrike's reference architecture.
Two-phase pipeline fix: PR #1 = normal operation, PR #2 = DR pipeline support.

## PR #1: Fix Pipeline for Normal Operation (In Progress)

### Changes Made

**OCI Repo (`gitlab-logscale-oci`):**
- [x] `main.tf:234` - Changed logscale module source from GitLab SSH to GitHub HTTPS
- [x] `main.tf` - Added DR section navigation comments
- [x] Verified bastion skip (`provision_bastion = false`) works cleanly
- [x] Verified allow list enforcement (0.0.0.0/0 blocked for control plane, bastion, LB)

**CICD Repo (`gitlab-logscale-cicd`):**
- [x] `oci-worker-deployment.yaml` - Added `logscale-versions` ConfigMap volume
- [x] Added `HUMIO_OPERATOR_VERSION` and `LOGSCALE_IMAGE_VERSION` env vars
- [x] Added source override sed (GitHub → GitLab) in terraform-init
- [x] Added cert-manager version extraction in terraform-init
- [x] Added `install-manual-crds` step (cert-manager + Humio Operator CRDs)
- [x] Added `deploy-pre-install` step
- [x] Added `deploy-logscale-crds` step
- [x] Added `deploy-logscale` step
- [x] Added `verify-oke-health` step
- [x] Added `verify-logscale-health` step
- [x] Added `verify-kafka-health` step

### Still TODO for PR #1
- [ ] Verify `logscale-versions` ConfigMap has `*_OCI_INFRASTRUCTURE` keys on live cluster
- [ ] Test pipeline end-to-end
- [ ] Review: prepare-workspace extraction (deferred to follow-up PR)

## PR #2: DR Pipeline Support (Future)

- Add DR-specific pipeline steps (global-dns, dr-failover-function)
- Add `dr` parameter to workflow template
- Add primary/standby workspace selection
- Test DR failover end-to-end

## Key File References

| File | Purpose |
|------|---------|
| `main.tf` | Module orchestration - logscale source, DR conditionals |
| `variables.tf` | All input variables (1000+ lines) |
| `locals.tf` | DR state resolution, network config, naming |
| `validation.tf` | Security validation (0.0.0.0/0 blocking) |
| `modules/oci/core/main.tf` | VCN, subnets, NSGs, bastion resources |
| `modules/oci/oke/` | OKE cluster and node pools |
| `modules/oci/storage/` | Object Storage (S3-compatible) |
| `modules/kubernetes/pre-install/` | Namespace, external-dns, encryption secrets |
| `modules/oci/global-dns/` | DR: DNS steering policy (active only) |
| `modules/oci/dr-failover-function/` | DR: Automated failover (standby only) |

## Architecture Notes

- **Module order**: core → bastion(optional) → storage → oke → pre-install → logscale → global-dns(DR) → dr-failover(DR) → cert-manager-webhook(optional)
- **DR modes**: `var.dr = ""` (normal), `"active"` (primary), `"standby"` (secondary)
- **LogScale source**: GitHub HTTPS in code, pipeline sed overrides to internal GitLab
- **Allow lists**: Pipeline injects from whitelisted-ips ConfigMap, validation.tf enforces

## Known Issues

- `install-module` has inline hacks: removes validation.tf, generates SSH keys, replaces 0.0.0.0/0 with sed, forces ENHANCED_CLUSTER
- These should be fixed in the Terraform modules themselves, not the pipeline
- OCI worker image (0.1.1) may need updates for CRD installation tools (kubectl, curl)
