# syntax = docker/dockerfile:experimental

FROM registry.access.redhat.com/codeready-workspaces/stacks-java-rhel8:1.2

USER root

RUN wget -O /tmp/oc.tar.gz https://mirror.openshift.com/pub/openshift-v4/clients/oc/4.1/linux/oc.tar.gz && cd /usr/bin && tar -xvzf /tmp/oc.tar.gz && chmod a+x /usr/bin/oc && rm -f /tmp/oc.tar.gz

RUN wget -O /tmp/graalvm.tar.gz https://github.com/oracle/graal/releases/download/vm-19.0.2/graalvm-ce-linux-amd64-19.0.2.tar.gz && cd /usr/local && tar -xvzf /tmp/graalvm.tar.gz && rm -rf /tmp/graalvm.tar.gz
ENV GRAALVM_HOME="/usr/local/graalvm-ce-19.0.2"
RUN ${GRAALVM_HOME}/bin/gu install native-image

RUN wget -O /tmp/mvn.tar.gz http://www.eu.apache.org/dist/maven/maven-3/3.6.0/binaries/apache-maven-3.6.0-bin.tar.gz

RUN tar xzf /tmp/mvn.tar.gz && rm -rf /tmp/mvn.tar.gz && mkdir /usr/local/maven && mv apache-maven-3.6.0/ /usr/local/maven/ && alternatives --install /usr/bin/mvn mvn /usr/local/maven/apache-maven-3.6.0/bin/mvn 1

RUN --mount=type=secret,id=rhsm username="$(grep RH_USERNAME /run/secrets/rhsm|cut -d= -f2)" && password="$(grep RH_PASSWORD /run/secrets/rhsm|cut -d= -f2)" && subscription-manager register --username $username --password $password --auto-attach && yum install -y gcc zlib-devel && yum install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm && yum install -y siege jq && subscription-manager remove --all && subscription-manager unregister

USER jboss

ENV MAVEN_OPTS="-Xmx4G -Xss128M -XX:MetaspaceSize=1G -XX:MaxMetaspaceSize=2G -XX:+CMSClassUnloadingEnabled"
ENV PATH="/usr/local/maven/apache-maven-3.6.0/bin:${PATH}"

RUN cd /tmp && mkdir project && cd project && mvn io.quarkus:quarkus-maven-plugin:0.19.1:create -DprojectGroupId=org.acme -DprojectArtifactId=footest -Dextensions="quarkus-agroal,quarkus-arc,quarkus-hibernate-orm,quarkus-hibernate-orm-panache,quarkus-jdbc-h2,quarkus-jdbc-postgresql,quarkus-kubernetes,quarkus-scheduler,quarkus-smallrye-fault-tolerance,quarkus-smallrye-health,quarkus-smallrye-opentracing" && mvn clean compile package && mvn clean && cd / && rm -rf /tmp/project
RUN cd /tmp && mkdir project && cd project && mvn io.quarkus:quarkus-maven-plugin:0.19.1:create -DprojectGroupId=org.acme -DprojectArtifactId=footest -Dextensions="quarkus-smallrye-reactive-streams-operators,quarkus-smallrye-reactive-messaging,quarkus-smallrye-reactive-messaging-kafka,quarkus-swagger-ui,quarkus-vertx,quarkus-kafka-client, quarkus-smallrye-metrics,quarkus-smallrye-openapi" && mvn clean compile package && mvn clean compile package -Pnative && mvn clean && cd / && rm -rf /tmp/project

RUN siege && sed -i 's/^connection = close/connection = keep-alive/' $HOME/.siege/siege.conf && sed -i 's/^benchmark = false/benchmark = true/' $HOME/.siege/siege.conf

RUN echo '-w "\n"' > $HOME/.curlrc

USER root
RUN chown -R jboss /home/jboss/.m2
RUN chmod -R a+w /home/jboss/.m2
USER jboss
