# W1 steps 4-7 commands as run (helm = ~/bin/helm3, v3.22.1; KUBECONFIG=$RUN/kubeconfig)
Files: lbc-iam/iam_policy.json (upstream v3.6.3), iam-own/trust-pods.json, iam-own/eso-policy.json, manifests/*.yaml
No custom values files; all values via --set.

kubectl annotate sc gp2 storageclass.kubernetes.io/is-default-class=false --overwrite
kubectl apply -f manifests/storageclass-ar-proof-gp3.yaml

helm3 repo add eks https://aws.github.io/eks-charts && helm3 repo update eks
# chart aws-load-balancer-controller 3.6.3, appVersion v3.6.3
aws iam create-policy --policy-name ar-proof-lbc-policy --policy-document file://lbc-iam/iam_policy.json --tags Key=owner,Value=$TAG_OWNER Key=purpose,Value=$TAG_PURPOSE
aws iam create-role --role-name ar-proof-lbc --assume-role-policy-document file://iam-own/trust-pods.json --tags ...
aws iam attach-role-policy --role-name ar-proof-lbc --policy-arn $LBC_POLICY_ARN
aws eks create-pod-identity-association --cluster-name $CLUSTER --namespace kube-system --service-account aws-load-balancer-controller --role-arn arn:aws:iam::$ACCT:role/ar-proof-lbc --tags owner=$TAG_OWNER,purpose=$TAG_PURPOSE
helm3 upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller --version 3.6.3 -n kube-system \
  --set clusterName=$CLUSTER --set region=$AWS_REGION --set vpcId=$VPC_ID --set serviceAccount.name=aws-load-balancer-controller --wait --timeout 5m

aws iam create-policy --policy-name ar-proof-eso-ssm --policy-document file://iam-own/eso-policy.json --tags ...
aws iam create-role --role-name ar-proof-eso --assume-role-policy-document file://iam-own/trust-pods.json --tags ...
aws iam attach-role-policy --role-name ar-proof-eso --policy-arn arn:aws:iam::$ACCT:policy/ar-proof-eso-ssm
aws eks create-pod-identity-association --cluster-name $CLUSTER --namespace external-secrets --service-account external-secrets --role-arn arn:aws:iam::$ACCT:role/ar-proof-eso --tags owner=$TAG_OWNER,purpose=$TAG_PURPOSE
helm3 repo add external-secrets https://charts.external-secrets.io && helm3 repo update external-secrets
helm3 upgrade --install external-secrets external-secrets/external-secrets -n external-secrets --create-namespace --version 2.15.0 --set installCRDs=true --wait --timeout 5m

kubectl apply -f manifests/namespaces.yaml   # agent-relay, ar-proof-setup, labels owner/purpose
