
FROM jenkins/jenkins:lts

USER root

ARG MAVEN_VERSION=3.9.11

# Install Docker CLI and tools needed to download Maven.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       docker.io \
       curl \
       tar \
    && rm -rf /var/lib/apt/lists/*

# Install official Apache Maven distribution.
RUN curl -fsSL \
      "https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz" \
      -o /tmp/maven.tar.gz \
    && mkdir -p /opt/maven \
    && tar -xzf /tmp/maven.tar.gz \
       --strip-components=1 -C /opt/maven \
    && rm /tmp/maven.tar.gz \
    && chmod +x /opt/maven/bin/mvn

# Install Eclipse Temurin JDK 27
RUN mkdir -p /opt/jdk27 \
    && curl -fL \
       "https://api.adoptium.net/v3/binary/latest/27/ga/linux/x64/jdk/hotspot/normal/eclipse" \
       -o /tmp/jdk.tar.gz \
    && tar -xzf /tmp/jdk.tar.gz \
       --strip-components=1 -C /opt/jdk27 \
    && rm /tmp/jdk.tar.gz \
    && test -x /opt/jdk27/bin/java \
    && /opt/jdk27/bin/java -version

ENV MAVEN_HOME=/opt/maven
ENV NIPON_JAVA_HOME=/opt/jdk27
ENV PATH="${MAVEN_HOME}/bin:${PATH}"

# Verify both installations
RUN /opt/jdk27/bin/java -version \
    && /opt/maven/bin/mvn --version

USER jenkins
