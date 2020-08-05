#!/bin/bash
#
# Prereqs: a running ocp 4 cluster, logged in as kubeadmin
#
MYDIR="$( cd "$(dirname "$0")" ; pwd -P )"
function usage() {
    echo "usage: $(basename $0) [-c/--count usercount] -a/--admin-password admin_password"
}

# Defaults
USERCOUNT=10
ADMIN_PASSWORD=

POSITIONAL=()
while [[ $# -gt 0 ]]
do
key="$1"

case $key in
    -c|--count)
    USERCOUNT="$2"
    shift # past argument
    shift # past value
    ;;
    -a|--admin-pasword)
    ADMIN_PASSWORD="$2"
    shift # past argument
    shift # past value
    ;;
    *)    # unknown option
    echo "Unknown option: $key"
    usage
    exit 1
    ;;
esac
done
set -- "${POSITIONAL[@]}" # restore positional parameters
echo "USERCOUNT: $USERCOUNT"
echo "ADMIN_PASSWORD: $ADMIN_PASSWORD"

if [ -z "$ADMIN_PASSWORD" ] ; then
  echo "Admin password (-a) required"
  usage
  exit 1
fi

if [ ! "$(oc get clusterrolebindings)" ] ; then
  echo "not cluster-admin"
  exit 1
fi

# adjust limits for admin
if test "$(oc get crd userquota.gpte.opentlc.com --ignore-not-found)"; then
    oc delete userquota/default --ignore-not-found
fi

# get routing suffix
TMP_PROJ="dummy-$RANDOM"
oc new-project $TMP_PROJ
oc create route edge dummy --service=dummy --port=8080 -n $TMP_PROJ
ROUTE=$(oc get route dummy -o=go-template --template='{{ .spec.host }}' -n $TMP_PROJ)
HOSTNAME_SUFFIX=$(echo $ROUTE | sed 's/^dummy-'${TMP_PROJ}'\.//g')
oc delete project $TMP_PROJ
MASTER_URL=$(oc whoami --show-server)
CONSOLE_URL=$(oc whoami --show-console)
# create users
TMPHTPASS=$(mktemp)
for i in $(seq 1 $USERCOUNT); do
    htpasswd -b ${TMPHTPASS} "user$i" "pass$i"
done

# Add openshift cluster admin user
htpasswd -b ${TMPHTPASS} admin "${ADMIN_PASSWORD}"

# Create user secret in OpenShift
! oc -n openshift-config delete secret workshop-user-secret --ignore-not-found
oc -n openshift-config create secret generic workshop-user-secret --from-file=htpasswd=${TMPHTPASS}
rm -f ${TMPHTPASS}

# Set the users to OpenShift OAuth
oc -n openshift-config get oauth cluster -o yaml | \
  yq d - spec.identityProviders | \
  yq w - -s ${MYDIR}/htpass.yaml | \
  oc apply -f -

# sleep for 30 seconds for the pods to be restarted
echo "Wait for 30s for new OAuth to take effect"
sleep 30

# Make the admin as cluster admin
oc adm policy add-cluster-role-to-user cluster-admin admin

# Delete previous identity to avoid login failure after deleting any existing admin user below
oc delete identity htpassidp:admin --ignore-not-found
 
# Delete any already existing admin user to be sure it won't be in conflict with the new one provided by the configured identity provider
oc delete user admin --ignore-not-found

# become admin
oc login $MASTER_URL -u admin -p "${ADMIN_PASSWORD}" --insecure-skip-tls-verify

# create projects for users
for i in $(seq 1 $USERCOUNT); do
    PROJ="user${i}-project"
    oc new-project $PROJ --display-name="Working Project for user${i}" >&- && \
    oc label namespace $PROJ quarkus-workshop=true  && \
    oc adm policy add-role-to-user admin user${i} -n $PROJ
done

# deploy guides
oc new-project guides
oc new-app quay.io/osevg/workshopper --name=web \
      -e MASTER_URL=${MASTER_URL} \
      -e CONSOLE_URL=${CONSOLE_URL} \
      -e CHE_URL=http://codeready-che.${HOSTNAME_SUFFIX} \
      -e KEYCLOAK_URL=http://keycloak-che.${HOSTNAME_SUFFIX} \
      -e ROUTE_SUBDOMAIN=${HOSTNAME_SUFFIX} \
      -e CONTENT_URL_PREFIX="https://raw.githubusercontent.com/RedHatWorkshops/quarkus-workshop/master/docs/" \
      -e WORKSHOPS_URLS="https://raw.githubusercontent.com/RedHatWorkshops/quarkus-workshop/master/docs/_workshop.yml" \
      -e CHE_USER_NAME=userNN \
      -e CHE_USER_PASSWORD=passNN \
      -e OPENSHIFT_USER_NAME=userNN \
      -e OPENSHIFT_USER_PASSWORD=passNN \
      -e LOG_TO_STDOUT=true
oc expose svc/web

# Install Che
oc new-project che

cat <<EOF | oc apply -n che -f -
apiVersion: operators.coreos.com/v1alpha2
kind: OperatorGroup
metadata:
  name: che-operator-group
  namespace: che
  generateName: che-
  annotations:
    olm.providedAPIs: CheCluster.v1.org.eclipse.che
spec:
  targetNamespaces:
  - che
EOF

cat <<EOF | oc apply -n che -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: codeready-workspaces
  namespace: che
  labels:
    csc-owner-name: redhat-operators
    csc-owner-namespace: openshift-marketplace
spec:
  channel: latest
  installPlanApproval: Automatic
  name: codeready-workspaces
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# Wait for checluster to be a thing
echo "Waiting for CheCluster CRDs"
while [ true ] ; do
  if [ "$(oc explain checluster)" ] ; then
    break
  fi
  echo -n .
  sleep 10
done

cat <<EOF | oc apply -n che -f -
apiVersion: org.eclipse.che/v1
kind: CheCluster
metadata:
  name: codeready
  namespace: che
spec:
  server:
    cheFlavor: codeready
    tlsSupport: false
    selfSignedCert: false
    serverMemoryRequest: '2Gi'
    serverMemoryLimit: '6Gi'


  database:
    externalDb: false
    chePostgresHostName: ''
    chePostgresPort: ''
    chePostgresUser: ''
    chePostgresPassword: ''
    chePostgresDb: ''
  auth:
    openShiftoAuth: false
    externalKeycloak: false
    keycloakURL: ''
    keycloakRealm: ''
    keycloakClientId: ''
  storage:
    pvcStrategy: per-workspace
    pvcClaimSize: 1Gi
    preCreateSubPaths: true
EOF

# Wait for che to be up
echo "Waiting for Che to come up..."
while [ 1 ]; do
  STAT=$(curl -s -w '%{http_code}' -o /dev/null http://codeready-che.${HOSTNAME_SUFFIX}/dashboard/)
  if [ "$STAT" = 200 ] ; then
    break
  fi
  echo -n .
  sleep 10
done

# workaround for Che Terminal timeouts
# must be run from AWS bastion host

# sudo -u ec2-user aws configure
# Default region name [None]: us-east-1

# get load balancer name
# sudo -u ec2-user aws elb describe-load-balancers | jq  '.LoadBalancerDescriptions | map(select( .DNSName == "'$(oc get svc router-default -n openshift-ingress -o jsonpath='{.status.loadBalancer.ingress[].hostname}')'" ))' | grep LoadBalancerName

# update timeout to 5 minutes
# sudo -u ec2-user aws elb modify-load-balancer-attributes --load-balancer-name <name> --load-balancer-attributes "{\"ConnectionSettings\":{\"IdleTimeout\":300}}"

# get keycloak admin password
KEYCLOAK_USER="$(oc get secret che-identity-secret -n che -o yaml -o jsonpath='{.data.user}' | base64 -d)"
echo KEYCLOAK_USER=$KEYCLOAK_USER
KEYCLOAK_PASSWORD="$(oc get secret che-identity-secret -n che -o yaml -o jsonpath='{.data.password}' | base64 -d)"
echo KEYCLOAK_PASSWORD=$KEYCLOAK_PASSWORD

SSO_TOKEN=$(curl -s -d "username=${KEYCLOAK_USER}&password=${KEYCLOAK_PASSWORD}&grant_type=password&client_id=admin-cli" \
  -X POST http://keycloak-che.${HOSTNAME_SUFFIX}/auth/realms/master/protocol/openid-connect/token | \
  jq  -r '.access_token')

# Import realm
curl -w "\n" -v -H "Authorization: Bearer ${SSO_TOKEN}" -H "Content-Type:application/json" -d @${MYDIR}/../files/quarkus-realm.json \
  -X POST "http://keycloak-che.${HOSTNAME_SUFFIX}/auth/admin/realms"

## MANUALLY add ProtocolMapper to map User Roles to "groups" prefix for JWT claims
echo "Keycloak credentials: $KEYCLOAK_USER / $KEYCLOAK_PASSWORD"
echo "URL: http://keycloak-che.${HOSTNAME_SUFFIX}"

# Create Che users, let them view che namespace
for i in $(seq 1 $USERCOUNT) ; do
    # oc adm policy add-role-to-user view user${i} -n che
    USERNAME=user${i}
    FIRSTNAME=User${i}
    LASTNAME=Developer
    curl -w "\n" -v -H "Authorization: Bearer ${SSO_TOKEN}" -H "Content-Type:application/json" -d '{"username":"user'${i}'","enabled":true,"emailVerified": true,"firstName": "User'${i}'","lastName": "Developer","email": "user'${i}'@no-reply.com", "credentials":[{"type":"password","value":"pass'${i}'","temporary":false}]}' -X POST "http://keycloak-che.${HOSTNAME_SUFFIX}/auth/admin/realms/codeready/users"
done

# Import stack definition
SSO_CHE_TOKEN=$(curl -s -d "username=admin&password=admin&grant_type=password&client_id=admin-cli" \
  -X POST http://keycloak-che.${HOSTNAME_SUFFIX}/auth/realms/codeready/protocol/openid-connect/token | \
  jq  -r '.access_token')

curl -w "\n" -X POST --header 'Content-Type: application/json' --header 'Accept: application/json' \
    --header "Authorization: Bearer ${SSO_CHE_TOKEN}" -d @${MYDIR}/../files/stack.json \
    "http://codeready-che.${HOSTNAME_SUFFIX}/api/stack"

# MANUALLY set permissions according to
# https://access.redhat.com/documentation/en-us/red_hat_codeready_workspaces/1.2/html/administration_guide/administering_workspaces#stacks
# THEN

# Scale the cluster
WORKERCOUNT=$(oc get nodes|grep worker | wc -l)
if [ "$WORKERCOUNT" -lt 10 ] ; then
    for i in $(oc get machinesets -n openshift-machine-api -o name | grep worker| cut -d'/' -f 2) ; do
      echo "Scaling $i to 3 replicas"
      oc patch -n openshift-machine-api machineset/$i -p '{"spec":{"replicas": 3}}' --type=merge
    done
fi

# Adjust cpu limits to 500/1500
# oc patch -n che limitrange/che-core-resource-limits -p '' --type=merge

# import stack image
oc apply -n openshift -f $MYDIR/../files/stack.imagestream.yaml
oc import-image --all quarkus-stack -n openshift

# Pre-create workspaces for users
for i in $(seq 1 $USERCOUNT); do
    SSO_CHE_TOKEN=$(curl -s -d "username=user${i}&password=pass${i}&grant_type=password&client_id=admin-cli" \
        -X POST http://keycloak-che.${HOSTNAME_SUFFIX}/auth/realms/codeready/protocol/openid-connect/token | jq  -r '.access_token')

    TMPWORK=$(mktemp)
    sed 's/WORKSPACENAME/WORKSPACE'${i}'/g' $MYDIR/../files/workspace.json > $TMPWORK

    curl -w "\n" -X POST --header 'Content-Type: application/json' --header 'Accept: application/json' \
    --header "Authorization: Bearer ${SSO_CHE_TOKEN}" -d @${TMPWORK} \
    "http://codeready-che.${HOSTNAME_SUFFIX}/api/workspace?start-after-create=true&namespace=user${i}"
    rm -f $TMPWORK
done

echo
# Install the strimzi operator for all namespaces
cat <<EOF | oc apply -n openshift-operators -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  labels:
    csc-owner-name: community-operators
    csc-owner-namespace: openshift-marketplace
  name: strimzi-kafka-operator
  namespace: openshift-operators
spec:
  channel: stable
  installPlanApproval: Automatic
  name: strimzi-kafka-operator
  source: community-operators
  sourceNamespace: openshift-marketplace
EOF

# Build stack
# Put your credentials in rhsm.secret file to look like:
# RH_USERNAME=your-username
# RH_PASSWORD=your-password
#
# then:
# DOCKER_BUILDKIT=1 docker build --progress=plain --secret id=rhsm,src=rhsm.secret -t docker.io/username/che-quarkus-workshop:latest -f stack.Dockerfile .
# docker push docker.io/username/che-quarkus-workshop:1.0.0.CR1
