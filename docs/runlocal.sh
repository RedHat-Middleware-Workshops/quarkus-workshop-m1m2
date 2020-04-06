#!/bin/bash -x

cd /Users/jfalkner/ws/quarkus-workshop/docs
docker run -it -p 8080:8080 --rm -v $(pwd):/app-data \
-e CHE_URL='http://codeready-codeready.apps.cluster-blr-f777.blr-f777.example.opentlc.com' \
-e CHE_USER_PASSWORD='r3dh4t1!' \
-e CONSOLE_URL='https://console-openshift-console.apps.cluster-blr-f777.blr-f777.example.opentlc.com' \
-e CONTENT_URL_PREFIX="file:///app-data/" \
-e KEYCLOAK_URL='http://keycloak-codeready.apps.cluster-blr-f777.blr-f777.example.opentlc.com' \
-e LOG_TO_STDOUT='true' \
-e MASTER_URL='https://api.cluster-blr-f777.blr-f777.example.opentlc.com:6443' \
-e OPENSHIFT_USER_PASSWORD='r3dh4t1!' \
-e ROUTE_SUBDOMAIN='apps.cluster-blr-f777.blr-f777.example.opentlc.com' \
-e WORKSHOPS_URLS="file:///app-data/_workshop.yml" \
    quay.io/jamesfalkner/workshopper

