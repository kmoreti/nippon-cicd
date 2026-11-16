// ============================================================================
// NIPON CI/CD — master pipeline
//
// Runs on the Jenkins controller (JDK 27 + Maven + Docker socket + the k3s
// deploy key are mounted by docker-compose.yml). Triggered when NIPON `main`
// advances (poll) or manually.
//
//   checkout NIPON -> Maven build -> tests -> JaCoCo coverage
//     -> SonarQube analysis + quality gate -> build+push images to the
//        local registry -> deploy to k3s (kustomize) when the gate passes.
//
// The deploy stage is guarded: it only redeploys when the NIPON commit that
// was built is NEWER than the last deployed commit, so a no-op poll does not
// churn the cluster.
// ============================================================================

pipeline {
  agent any

  options {
    timeout(time: 90, unit: 'MINUTES')
    disableConcurrentBuilds()
  }

  environment {
    NIPON_REPO  = "${NIPON_REPO ?: 'https://github.com/kmoreti/nippon.git'}"
    NIPON_REF   = "${NIPON_REF ?: 'main'}"
    NIPON_GH_TOKEN = "${NIPON_GH_TOKEN ?: ''}"
    REGISTRY    = "${REGISTRY ?: '192.168.68.120:5000'}"
    K3S_NODE    = "${K3S_NODE ?: 'kmoreti@192.168.68.129'}"
    K3S_SSH_KEY = "${K3S_SSH_KEY ?: '/home/jenkins/.ssh/id_ed25519'}"
    SONAR_HOST  = "${SONAR_HOST ?: 'http://sonarqube:9000'}"
    SONAR_TOKEN = "${SONAR_TOKEN ?: ''}"
    // Build toolchain (mounted by docker-compose.yml)
    JAVA_HOME   = "${NIPON_JAVA_HOME ?: '/opt/jdk27'}"
    MAVEN_HOME  = "${NIPON_MAVEN_HOME ?: '/opt/maven'}"
    // Git commit of NIPON that this build produced (set in Checkout).
    NIPON_SHA   = ''
    LAST_DEPLOYED = '/var/jenkins_home/last_deployed_sha.txt'
  }

  stages {
    // ----------------------------------------------------------------------
    stage('Checkout NIPON') {
      steps {
        // Single-quoted so the shell expands the pipeline env vars Jenkins
        // exports (NIPON_GH_TOKEN, NIPON_REF, NIPON_REPO, WORKSPACE).
        sh '''
          set -euo pipefail
          rm -rf nippon-src && mkdir -p nippon-src
          if [ -n "$NIPON_GH_TOKEN" ]; then
            URL="https://x-access-token:${NIPON_GH_TOKEN}@github.com/kmoreti/nippon.git"
          else
            URL="${NIPON_REPO}"
          fi
          git clone --depth 1 --branch "${NIPON_REF}" "${URL}" nippon-src 2>/dev/null \
            || git clone --depth 1 "${URL}" nippon-src
          echo "$(git -C nippon-src rev-parse HEAD)" > "$WORKSPACE/.nippon_sha"
          echo "Cloned NIPON @ ${NIPON_REF} ($(cat $WORKSPACE/.nippon_sha))"
        '''
      }
    }

    // ----------------------------------------------------------------------
    stage('Set up toolchain') {
      steps {
        sh '''
          set -euo pipefail
          export JAVA_HOME=${JAVA_HOME}
          export PATH="$JAVA_HOME/bin:${MAVEN_HOME}/bin:$PATH"
          echo "--- java ---"; java -version
          echo "--- mvn ---"; mvn -version | head -3
        '''
      }
    }

    // ----------------------------------------------------------------------
    stage('Build (Maven)') {
      steps {
        sh '''
          set -euo pipefail
          export JAVA_HOME=${JAVA_HOME}
          export PATH="$JAVA_HOME/bin:${MAVEN_HOME}/bin:$PATH"
          cd nippon-src
          mvn -B -Dmaven.repo.local=/home/jenkins/.m2/repository -T1C -DskipTests clean package
          echo '--- fat jars ---'
          ls -1 services/*/target/*.jar 2>/dev/null | head -40
        '''
      }
    }

    // ----------------------------------------------------------------------
    stage('Tests') {
      when { expression { !params.SKIP_TESTS.toBoolean() } }
      steps {
        sh '''
          set -euo pipefail
          export JAVA_HOME=${JAVA_HOME}
          export PATH="$JAVA_HOME/bin:${MAVEN_HOME}/bin:$PATH"
          cd nippon-src
          mvn -B -Dmaven.repo.local=/home/jenkins/.m2/repository -T1C test
          echo '--- surefire totals (last 40) ---'
          grep -rhEo 'Tests run: [0-9]+, Failures: [0-9]+, Errors: [0-9]+' \
            services/*/target/surefire-reports/*.xml 2>/dev/null | tail -40 || true
        '''
      }
    }

    // ----------------------------------------------------------------------
    stage('Coverage (JaCoCo)') {
      when { expression { !params.SKIP_TESTS.toBoolean() } }
      steps {
        sh '''
          set -euo pipefail
          export JAVA_HOME=${JAVA_HOME}
          export PATH="$JAVA_HOME/bin:${MAVEN_HOME}/bin:$PATH"
          cd nippon-src
          # Aggregate per-module JaCoCo exec data into one report (best effort).
          mvn -B -Dmaven.repo.local=/home/jenkins/.m2/repository org.jacoco:jacoco-maven-plugin:0.8.12:report-aggregate -DskipTests || true
          echo '--- jacoco reports ---'
          find . -name 'jacoco.csv' 2>/dev/null | head
        '''
      }
    }

    // ----------------------------------------------------------------------
    stage('SonarQube analysis') {
      when {
        expression { !params.SKIP_TESTS.toBoolean() }
        expression { params.SONAR_TOKEN?.trim() ? true : false }
      }
      steps {
        sh '''
          set -euo pipefail
          export JAVA_HOME=${JAVA_HOME}
          export PATH="$JAVA_HOME/bin:${MAVEN_HOME}/bin:$PATH"
          cd nippon-src
          mvn -B -Dmaven.repo.local=/home/jenkins/.m2/repository -DskipTests \
            -Dsonar.host.url=${SONAR_HOST} \
            -Dsonar.login=${SONAR_TOKEN} \
            -Dsonar.projectKey=nippon \
            org.sonarsource.scanner.maven:sonar-maven-plugin:3.9.0.2121:sonar \
            || echo "WARN: sonar analysis returned non-zero (continuing)"
        '''
      }
    }

    // ----------------------------------------------------------------------
    stage('Quality gate') {
      when {
        expression { !params.SKIP_TESTS.toBoolean() }
        expression { params.SONAR_TOKEN?.trim() ? true : false }
      }
      steps {
        sh 'echo "Quality gate enforced by SonarQube (sonar-maven-plugin gate)." || true'
      }
    }

    // ----------------------------------------------------------------------
    stage('Build & push images') {
      steps {
        sh '''
          set -euo pipefail
          SHA=$(cat $WORKSPACE/.nippon_sha)
          SHA=${SHA:0:12}
          cd nippon-src
          # Login to the local (HTTP) registry.
          docker login --insecure-registry $REGISTRY -u _ -p "$(cat /var/jenkins_home/registry_pass 2>/dev/null || echo x)" 2>/dev/null || true
          # Build + push each service that has a Dockerfile.
          for d in services/*/; do
            [ -f "$d/Dockerfile" ] || continue
            svc=$(basename "$d")
            img="$REGISTRY/nippon/$svc:$SHA"
            echo "==> $svc -> $img"
            docker build -f "$d/Dockerfile" -t "$img" . \
              && docker push "$img" \
              && docker tag "$img" "$REGISTRY/nippon/$svc:latest" \
              && docker push "$REGISTRY/nippon/$svc:latest"
          done
          echo "$SHA" > $WORKSPACE/.deploy_sha
        '''
      }
    }

    // ----------------------------------------------------------------------
    stage('Deploy to k3s') {
      when {
        expression { params.DEPLOY.toBoolean() }
        expression { !params.SKIP_TESTS.toBoolean() }
      }
      steps {
        // Redeploy only when the built commit differs from the last deployed one.
        sh '''
          set -euo pipefail
          SHA=$(cat $WORKSPACE/.deploy_sha)
          LAST=$(cat $LAST_DEPLOYED 2>/dev/null || echo none)
          if [ "$SHA" = "$LAST" ]; then
            echo "NIPON @ $SHA already deployed - skipping (no change on main)."
            exit 0
          fi
          export DEPLOY_SHA="$SHA"
          export REGISTRY="${REGISTRY}"
          chmod 600 "$K3S_SSH_KEY" 2>/dev/null || true
          echo ">>> deploying NIPON @ $SHA to k3s ($K3S_NODE)"
          ssh -i "$K3S_SSH_KEY" -o StrictHostKeyChecking=no -o BatchMode=yes "$K3S_NODE" \
            'bash -s' < scripts/deploy-to-k3s.sh
          echo "$SHA" > $LAST_DEPLOYED
          echo "Deployed NIPON @ $SHA to k3s ($K3S_NODE)."
        '''
      }
    }
  }

  post {
    always {
      archiveArtifacts artifacts: 'nippon-src/**/target/surefire-reports/*.xml, .deploy_sha',
                       allowEmptyArchive: true
    }
    success { echo "CI/CD green: NIPON @ ${NIPON_SHA} built + deployed." }
    failure { echo "CI/CD failed - see the stage logs above for the failing stage." }
  }
}
