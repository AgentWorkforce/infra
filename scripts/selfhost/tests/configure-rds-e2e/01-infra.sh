#!/usr/bin/env bash
# Fake RDS (PostgreSQL 15, TLS verify-full hostname, non-superuser master "postgres"
# with CREATEROLE/CREATEDB + rds_superuser, like RDS) and a separate kind cluster.
set -euo pipefail
source "$(dirname "$0")/env.sh"
mkdir -p "$W/certs" "$W/pg"
cd "$W/certs"
if [[ ! -s server.crt ]]; then
  openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.crt -days 3 -subj "/CN=cfgrds test RDS CA" \
    -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign 2>/dev/null
  openssl req -newkey rsa:2048 -nodes -keyout server.key -out server.csr -subj "/CN=$RDS_HOST" 2>/dev/null
  printf 'subjectAltName=DNS:%s\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n' "$RDS_HOST" > ext.cnf
  openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 3 -extfile ext.cnf 2>/dev/null
fi
cat > "$W/pg/hba.conf" <<'HBA'
local all all trust
hostssl all all 0.0.0.0/0 scram-sha-256
HBA
cat > "$W/pg/00-rds.sh" <<RDS
#!/bin/bash
set -e
psql -v ON_ERROR_STOP=1 -U rdsadmin -d postgres <<SQL
CREATE ROLE rds_superuser NOLOGIN;
GRANT pg_monitor, pg_signal_backend, pg_read_all_settings, pg_read_all_stats TO rds_superuser WITH ADMIN OPTION;
CREATE ROLE postgres LOGIN CREATEROLE CREATEDB PASSWORD '$MASTER_PW';
GRANT rds_superuser TO postgres WITH ADMIN OPTION;
GRANT ALL ON DATABASE postgres TO rds_superuser;
SQL
RDS
chmod 755 "$W/pg/00-rds.sh"
docker network inspect kind >/dev/null 2>&1 || docker network create kind >/dev/null
if ! docker inspect cfgrds-pg >/dev/null 2>&1; then
  docker run -d --name cfgrds-pg --network kind -e POSTGRES_USER=rdsadmin -e POSTGRES_PASSWORD="$(openssl rand -hex 12)" \
    -v "$W/certs:/certs:ro" -v "$W/pg:/pgconf:ro" -v "$W/pg/00-rds.sh:/docker-entrypoint-initdb.d/00-rds.sh:ro" \
    --memory 768m --entrypoint bash pgvector/pgvector:pg${PG_MAJOR} -c '
      mkdir -p /var/lib/postgresql/ssl && cp /certs/server.crt /certs/server.key /pgconf/hba.conf /var/lib/postgresql/ssl/ &&
      chown -R postgres /var/lib/postgresql/ssl && chmod 600 /var/lib/postgresql/ssl/server.key &&
      exec docker-entrypoint.sh postgres -c ssl=on -c ssl_cert_file=/var/lib/postgresql/ssl/server.crt \
        -c ssl_key_file=/var/lib/postgresql/ssl/server.key -c hba_file=/var/lib/postgresql/ssl/hba.conf \
        -c password_encryption=scram-sha-256 -c max_connections=300' >/dev/null
fi
for i in $(seq 1 60); do docker exec cfgrds-pg pg_isready -U rdsadmin -d postgres >/dev/null 2>&1 && break; sleep 2; done
# RDS lets rds_superuser create vector; vanilla pgvector needs a superuser unless trusted.
docker exec -u root cfgrds-pg sh -c 'f=$(ls /usr/share/postgresql/*/extension/vector.control); grep -q "^trusted" "$f" || echo "trusted = true" >> "$f"' 
sleep 3
docker exec cfgrds-pg psql -U rdsadmin -d postgres -Atc "select 'master: '||rolname||' super='||rolsuper||' createrole='||rolcreaterole||' createdb='||rolcreatedb from pg_roles where rolname='postgres'"
docker exec cfgrds-pg psql -U rdsadmin -d postgres -Atc "select 'ext '||name||' trusted='||trusted from pg_available_extension_versions where name in ('vector','pg_trgm','btree_gin') and installed is false order by name, version desc" | sort -u
PG_IP="$(docker inspect -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}' cfgrds-pg)"
echo "pg ip: $PG_IP"

if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  kind create cluster --name "$CLUSTER" --kubeconfig "$KUBECONFIG" --wait 120s
fi
# Resolve the fake RDS hostname inside the cluster.
kubectl --context "$KCTX" -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' > "$W/Corefile"
if ! grep -q "$RDS_HOST" "$W/Corefile"; then
  python3 - "$W/Corefile" "$PG_IP" "$RDS_HOST" <<'PY'
import sys
p, ip, host = sys.argv[1:]
s = open(p).read()
s = s.replace("    ready\n", f"    ready\n    hosts {{\n       {ip} {host}\n       fallthrough\n    }}\n", 1)
open(p, "w").write(s)
PY
  kubectl --context "$KCTX" -n kube-system create configmap coredns --from-file=Corefile="$W/Corefile" --dry-run=client -o yaml \
    | kubectl --context "$KCTX" apply -f - >/dev/null
  kubectl --context "$KCTX" -n kube-system rollout restart deployment coredns >/dev/null
  kubectl --context "$KCTX" -n kube-system rollout status deployment coredns --timeout=120s >/dev/null
fi
# Prove TLS verify-full to the fake RDS from inside the cluster, as the master user.
kubectl --context "$KCTX" delete pod tls-probe --ignore-not-found >/dev/null
kubectl --context "$KCTX" create configmap tls-probe-ca --from-file=ca.crt="$TEST_CA" --dry-run=client -o yaml | kubectl --context "$KCTX" apply -f - >/dev/null
kubectl --context "$KCTX" run tls-probe --restart=Never --image=pgvector/pgvector:pg${PG_MAJOR} \
  --overrides='{"spec":{"volumes":[{"name":"ca","configMap":{"name":"tls-probe-ca"}}],"containers":[{"name":"tls-probe","image":"pgvector/pgvector:pg'"$PG_MAJOR"'","command":["psql","-Atc","select current_user||'"' ssl='"'||ssl from pg_stat_ssl where pid=pg_backend_pid()"],"env":[{"name":"PGHOST","value":"'"$RDS_HOST"'"},{"name":"PGUSER","value":"postgres"},{"name":"PGPASSWORD","value":"'"$MASTER_PW"'"},{"name":"PGDATABASE","value":"postgres"},{"name":"PGSSLMODE","value":"verify-full"},{"name":"PGSSLROOTCERT","value":"/ca/ca.crt"}],"volumeMounts":[{"name":"ca","mountPath":"/ca"}]}]}}' >/dev/null
kubectl --context "$KCTX" wait --for=jsonpath='{.status.phase}'=Succeeded pod/tls-probe --timeout=180s >/dev/null || true
kubectl --context "$KCTX" logs tls-probe
kubectl --context "$KCTX" delete pod tls-probe >/dev/null; kubectl --context "$KCTX" delete configmap tls-probe-ca >/dev/null
echo "infra ready"
