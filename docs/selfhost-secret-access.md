# Restricting who can read the install's Secrets

Applies to every Kubernetes install (GKE, EKS, AKS).

## Why this matters

Two of the install's Secrets hold a **database administrator** URL for HoopDb,
the sessions database. It is the Cloud SQL `cloudsqlsuperuser` login on Google
Cloud and the RDS master login on AWS:

| Secret | Key | Read by |
| --- | --- | --- |
| `agent-relay-secrets` | `HOOPDB_MIGRATION_URL` | The HoopDb migration Job (`<release>-worker-migrate`) on install and upgrade, and the one-off operator Jobs in the install guide |
| `search-indexer-owner` | `RELAYHISTORY_PIPELINE_CONSUMER_SECRET` | The search indexer bootstrap Job and the output facts bootstrap Job |

No long-running pod reads either key: the services use their own least-privilege
logins. But `agent-relay-secrets` also holds keys the running services do
need, and Kubernetes RBAC grants access to a whole Secret, not to one key. So
**anyone who can read Secrets in the namespace can read every session
transcript and change the schema**, with a login that bypasses the database's
own permissions.

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
- Rotate the administrator password after the people who held it change.
  Changing the password in the cloud does not change the two Secret keys
  above, and the next upgrade's migration and bootstrap Jobs fail with an
  authentication error until both hold the new URL. So rotation is three
  steps:
  1. Change the password. Google Cloud: raise `admin_user.password_version`
     for the postgres module in Terraform and apply. AWS: RDS rotates a
     managed master password by itself (every 7 days by default).
  2. Write the new URL into **both** keys,
     `agent-relay-secrets/HOOPDB_MIGRATION_URL` and
     `search-indexer-owner/RELAYHISTORY_PIPELINE_CONSUMER_SECRET` (JSON:
     `{"hoopdb_url": "<url>"}`), the same way you created the Secrets:
     `kubectl`, helm-secrets, or your secret store with External Secrets
     Operator. Only the password part of the URL changes. On AWS,
     `rds-setup.sh refresh-admin` rewrites the two local credential files
     with the current password, and `agent-relay-upgrade.sh --rds-setup`
     also patches the two keys in the cluster before each upgrade; without
     that flag, publish the files yourself.
  3. Check before upgrading:

     ```sh
     kubectl -n agent-relay get secret agent-relay-secrets -o jsonpath='{.data.HOOPDB_MIGRATION_URL}' | base64 -d | sed -E 's#(://[^:]+):[^@]+@#\1:<password>@#'
     ```

     prints the URL with the password hidden; compare the user and host,
     and confirm the Secret's `metadata.managedFields` time (or your secret
     store's sync time) is after the rotation.

## What this does not fix

The administrator URL still sits in the cluster between upgrades, although
only install-time Jobs use it. Removing it is tracked in
[AgentWorkforce/infra#480](https://github.com/AgentWorkforce/infra/issues/480).
