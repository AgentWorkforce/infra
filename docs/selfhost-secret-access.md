# Restricting who can read the install's Secrets

Applies to every Kubernetes install (GKE, EKS, AKS).

## Why this matters

Two long-lived Secrets hold the dedicated `hoopdb_owner` URL for HoopDb, the
sessions database. That login is not a provider administrator, superuser, role
creator or database creator, but it owns the HoopDb database and its objects:

| Secret | Key | Read by |
| --- | --- | --- |
| `agent-relay-secrets` | `HOOPDB_MIGRATION_URL` | The HoopDb migration Job (`<release>-worker-migrate`) on install and upgrade, and the one-off operator Jobs in the install guide |
| `search-indexer-owner` | `RELAYHISTORY_PIPELINE_CONSUMER_SECRET` | The search indexer bootstrap Job and the output facts bootstrap Job |
| `hoopdb-admin-jobs` (existing administrator-owned installs only, temporary) | Both keys above | Migration/bootstrap and guide Jobs while an operator has explicitly prepared the Secret |

No long-running pod reads either key: the services use their own least-privilege
logins. But `agent-relay-secrets` also holds keys the running services do
need, and Kubernetes RBAC grants access to a whole Secret, not to one key. So
**anyone who can read Secrets in the namespace can read every session
transcript and change the schema**. On a legacy administrator-owned install,
the temporary `hoopdb-admin-jobs` URL is the Cloud SQL administrator, RDS
master or Azure/CNPG superuser and has still broader authority. The setup and
upgrade flows delete it after the dependent Jobs succeed; it must receive the
same RBAC protection while it exists.

The other Secrets hold runtime logins, signing keys and the encryption master
key. They need the same care; the administrator URL is simply the worst one to
lose.

## What to do

### 1. Give the namespace to the install, and to nobody else

Run nothing else in the install's namespace (`agent-relay` in the guides).
These permissions all expose the Secrets, because each lets the holder read a
Secret or run a pod that mounts one:

| Permission in the namespace | Why it exposes the Secrets |
| --- | --- |
| `get`, `list` or `watch` on `secrets` | Reads the values. `list` and `watch` return every Secret; `resourceNames` does not limit them |
| `create` on `pods`, or `create`/`update`/`patch` on `deployments`, `jobs`, `cronjobs`, `statefulsets`, `daemonsets`, `replicasets` | A new pod can mount any Secret in its namespace |
| `create` on `pods/exec` or `pods/attach` | A shell in a running pod reads what that pod mounts |
| The built-in `admin` and `edit` ClusterRoles, and `cluster-admin` | Include all of the above |

The built-in **`view`** ClusterRole does not include Secrets, exec or
workload changes. Bind people who only need to look at pods, logs and events
to `view`.

### 2. Bind only the people who install and upgrade

Create one Role for the operators who run `helm upgrade` and the guide's
Jobs, and bind it to a group from your identity provider. Everyone else gets
`view` or nothing.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: agent-relay-operator
  namespace: agent-relay
rules:
  # Helm reads and writes its release records as Secrets, so an operator who
  # upgrades the install needs Secrets in this namespace.
  - apiGroups: [""]
    resources: [secrets, configmaps, services, serviceaccounts, persistentvolumeclaims]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [""]
    resources: [pods, pods/log, events]
    verbs: [get, list, watch]
  - apiGroups: [apps]
    resources: [deployments, statefulsets, replicasets]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [batch]
    resources: [jobs, cronjobs]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [networking.k8s.io]
    resources: [ingresses, networkpolicies]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [policy]
    resources: [poddisruptionbudgets]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [autoscaling]
    resources: [horizontalpodautoscalers]
    verbs: [get, list, watch, create, update, patch, delete]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: agent-relay-operators
  namespace: agent-relay
subjects:
  - kind: Group
    name: agent-relay-operators@example.com   # GKE: a Google Group; EKS: a group from your access entries
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: agent-relay-operator
  apiGroup: rbac.authorization.k8s.io
---
# People who only need to look: pods, logs and events, no Secrets, no exec.
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: agent-relay-viewers
  namespace: agent-relay
subjects:
  - kind: Group
    name: agent-relay-viewers@example.com
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: view
  apiGroup: rbac.authorization.k8s.io
```

Add the kinds your values turn on (for example `backendconfigs` and
`managedcertificates` on GKE, or `externalsecrets`); `helm upgrade` names any
kind it is refused. This Role is a starting point, not a tested minimum.

The chart's own ServiceAccounts need no change. With managed databases (the
GKE and EKS guides), the charts create no Role in the install's namespace:
pods receive their keys as mounted files or environment variables. Two
optional setups do create one: durable actors (its control plane may `get`
Secrets and manage pods in its separate sandbox namespace), and the
in-cluster CloudNativePG profiles (a bootstrap Job that may `exec` into the
database pod).

### 3. Remember the cloud's own roles

Cluster RBAC is not the only way in. A cloud role that grants the Kubernetes
API also grants its Secrets:

- **GKE:** `roles/container.admin`, `roles/container.developer`, and the
  basic `roles/owner` and `roles/editor` roles can all read Secrets in every
  namespace. Grant people `roles/container.clusterViewer` (enough to fetch
  credentials) and give access through RBAC bindings to Google Groups.
- **EKS:** the access policies `AmazonEKSClusterAdminPolicy`,
  `AmazonEKSAdminPolicy` and `AmazonEKSEditPolicy` read Secrets;
  `AmazonEKSViewPolicy` does not. Scope access entries to the namespace.

### 4. Check who has access now

```sh
NS=agent-relay
# Can this person read Secrets, or start a pod that mounts them?
for verb_resource in "get secrets" "list secrets" "create pods" "create pods/exec" "create jobs.batch" "patch deployments.apps"; do
  printf '%-28s %s\n' "$verb_resource" "$(kubectl -n $NS auth can-i $verb_resource --as <user> --as-group <group>)"
done
# Every binding that reaches the namespace.
kubectl -n $NS get rolebindings -o custom-columns='BINDING:.metadata.name,ROLE:.roleRef.name,SUBJECTS:.subjects[*].name'
kubectl get clusterrolebindings -o custom-columns='BINDING:.metadata.name,ROLE:.roleRef.name,SUBJECTS:.subjects[*].name' | grep -E 'cluster-admin|admin|edit'
```

Those commands list Kubernetes bindings only. Access granted by the cloud
does not appear in them, so list it as well:

```sh
# EKS: access entries and the policies attached to each, with their scope.
CLUSTER=<cluster name>
for arn in $(aws eks list-access-entries --cluster-name $CLUSTER --query 'accessEntries[]' --output text); do
  echo "== $arn"
  aws eks list-associated-access-policies --cluster-name $CLUSTER --principal-arn "$arn" \
    --query 'associatedAccessPolicies[].[policyArn,accessScope.type,join(`,`,accessScope.namespaces)]' --output text
done
# An install made with this repository's AWS foundation Terraform has cluster-wide
# AmazonEKSClusterAdminPolicy entries for its operator principals: expect them here.

# GKE: who holds a project role that reaches every namespace.
gcloud projects get-iam-policy <project id> --flatten='bindings[].members' \
  --filter='bindings.role:(roles/owner OR roles/editor OR roles/container.admin OR roles/container.developer OR roles/container.clusterAdmin)' \
  --format='table(bindings.role,bindings.members)'
```

**Done when:** only your install operators answer `yes`, and every subject
in the Kubernetes lists and every principal in the cloud list is one you
expect. For each EKS entry check two things: what the policy permits
(`AmazonEKSViewPolicy` cannot read Secrets at any scope; the admin and edit
policies can), and whether its scope is `cluster` or lists the install's
namespace.

### 5. Record reads

Turn on audit logging for Secret reads so an unexpected one is visible:

- **GKE:** enable Data Access audit logs (`DATA_READ`) for the Kubernetes
  Engine API, then query all three read paths (`kubectl get secrets -o yaml`
  is a `list`, not a `get`):
  `protoPayload.methodName=("io.k8s.core.v1.secrets.get" OR "io.k8s.core.v1.secrets.list" OR "io.k8s.core.v1.secrets.watch") AND protoPayload.resourceName:"namespaces/agent-relay"`.
- **EKS:** enable the `audit` control plane log type and search the audit
  stream for `"resource":"secrets"` with `"namespace":"agent-relay"` and a
  `verb` of `get`, `list` or `watch`.

### 6. Also worth doing

- Encrypt Secrets at rest with your own key: application-layer secrets
  encryption with a Cloud KMS key on GKE, envelope encryption with a KMS key
  on EKS. It protects etcd and its backups, not the
  Kubernetes API, so it does not replace the steps above.
- Rotate database credentials after the people who held them change. On fresh
  installs the setup state and both long-lived keys must keep the same
  `hoopdb_owner` password. On an existing administrator-owned install, rotate
  the provider administrator normally, then rerun the platform setup helper's
  `pre`/`prepare-admin-jobs` flow immediately before the next upgrade; it
  creates `hoopdb-admin-jobs` from the current credential and removes it after
  success. Never copy that administrator URL back into either long-lived key.

## What this does not fix

The long-lived `hoopdb_owner` URL can still read and change HoopDb because it
owns the database objects; RBAC and audit logging remain necessary. Existing
administrator-owned databases also remain administrator-owned until the
ownership-transfer follow-up under
[AgentWorkforce/infra#480](https://github.com/AgentWorkforce/infra/issues/480),
but their administrator URL is present in Kubernetes only while the temporary
Job Secret exists.
