# DR Failover Function (OCI)

This module deploys the OCI Function used to automate LogScale DR failover on the standby cluster.
It also creates the supporting ONS topic, monitoring alarm, IAM policies, and optional Kubernetes RBAC.

Notes:
- Failover cooldown is persisted on the `humio-operator` Deployment via annotation to survive function cold starts.
- The function can update the OCI DNS steering policy with the standby ingress IP during failover.
