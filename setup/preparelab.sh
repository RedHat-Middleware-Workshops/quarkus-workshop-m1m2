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

# get routing suffix
TMP_PROJ="dummy-$RANDOM"
oc new-project $TMP_PROJ
oc create route edge dummy --service=dummy --port=8080 -n $TMP_PROJ
ROUTE=$(oc get route dummy -o=go-template --template='{{ .spec.host }}' -n $TMP_PROJ)
HOSTNAME_SUFFIX=$(echo $ROUTE | sed 's/^dummy-'${TMP_PROJ}'\.//g')
oc delete project $TMP_PROJ
MASTER_URL=$(oc whoami --show-server)

# create users
TMPHTPASS=$(mktemp)
for i in {1..$USERCOUNT} ; do
    htpasswd -b ${TMPHTPASS} "user$i" "pass$i"
done

# Add openshift cluster admin user
htpasswd -b ${TMPHTPASS} admin "${ADMIN_PASSWORD}"

# Create user secret in OpenShift
! oc -n openshift-config delete secret workshop-user-secret
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

# create projects for users
for i in {1..$USERCOUNT} ; do
    PROJ="user${i}-project"
    oc new-project $PROJ --display-name="Working Project for user${i}" >&- && \
    oc label namespace $PROJ quarkus-workshop=true  && \
    oc adm policy add-role-to-user admin user${i} -n $PROJ
done

# deploy guides
oc new-project guides
oc new-app quay.io/osevg/workshopper --name=web \
      -e ROUTE_SUBDOMAIN=${HOSTNAME_SUFFIX} \
      -e MASTER_URL=${MASTER_URL} \
      -e CHE_URL=http://codeready-che.${ROUTE_SUBDOMAIN} \
      -e WORKSHOPS_URLS="https://raw.githubusercontent.com/openshift-evangelists/workshopper-template/master/_workshop.yml" \
      -e LOG_TO_STDOUT=true 
oc expose svc/web

# Install Che
oc new-project che
cat <<EOF | oc apply -n openshift-marketplace -f -
apiVersion: operators.coreos.com/v1
kind: CatalogSourceConfig
metadata:
  name: installed-redhat-che
  namespace: openshift-marketplace
spec:
  targetNamespace: che
  packages: codeready-workspaces
EOF

cat <<EOF | oc apply -n che -f -
apiVersion: operators.coreos.com/v1alpha2
kind: OperatorGroup
metadata:
  name: che-operator-group
  namespace: che
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
    csc-owner-name: installed-redhat-che
    csc-owner-namespace: openshift-marketplace
spec:
  channel: final
  installPlanApproval: Automatic
  name: eclipse-che
  source: installed-community-che
  sourceNamespace: che
  startingCSV: crwoperator.v1.2.0
EOF

cat <<EOF | oc apply -n che -f -
apiVersion: org.eclipse.che/v1
kind: CheCluster
metadata:
  name: codereadyt
  namespace: che
spec:
  server:
    tlsSupport: false
    selfSignedCert: false
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
  STAT=$(curl -w '%{http_code}' -o /dev/null http://codeready-che.${HOSTNAME_SUFFIX}/dashboard/)
  if [ "$STAT" = 200 ] ; then
    break
  fi
  echo -n .
  sleep 10
done

# workaround for PVC problem
oc get --export cm/custom -n che -o yaml | yq w - 'data.CHE_INFRA_KUBERNETES_PVC_WAIT__BOUND' \"false\" | oc apply -f - -n che
oc scale -n che deployment/che --replicas=0
oc scale -n che deployment/che --replicas=1

# Add custom stack manually

# Add che users
# ./kcadm.sh config credentials --server http://$KEYCLOAK_SERVICE_HOST:$KEYCLOAK_SERVICE_PORT_HTTP/auth --realm codeready 

# Scale the cluster
WORKERCOUNT=$(oc get nodes|grep worker | wc -l)
if [ "$WORKERCOUNT" -lt 10 ] ; then
    for i in $(oc get machinesets -n openshift-machine-api -o name | grep worker| cut -d'/' -f 2) ; do
      echo "Scaling $i to 3 replicas"
      oc patch -n openshift-machine-api machineset/$i -p '{"spec":{"replicas": 3}}' --type=merge
    done
fi

# Pre-pull some images

# Build stack
# docker build --build-arg RH_USERNAME='YOURUSERNAME' --build-arg RH_PASSWORD='YOURPASSWORD' -t docker.io/schtool/che-quarkus-odo:j4k -f stack.Dockerfile .