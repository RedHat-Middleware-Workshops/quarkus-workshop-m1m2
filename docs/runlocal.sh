#!/bin/bash -x

docker run -it --rm -p 8080:8080 -v $(pwd):/app-data \
              -e CONTENT_URL_PREFIX="file:///app-data" \
              -e WORKSHOPS_URLS="file:///app-data/_workshop.yml" \
              -e LOG_TO_STDOUT=true \
              -e ROUTE_SUBDOMAIN=".route.subdomain.com" \
              -e MASTER_URL="https://master.url.com:8443" \
              -e CHE_URL="http://che-che.master.com" \
              quay.io/osevg/workshopper

