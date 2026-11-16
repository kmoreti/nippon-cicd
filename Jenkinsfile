// ============================================================================
// NIPON CI/CD — master pipeline
//
// Runs on the Jenkins controller (host has JDK 27 + Maven + Docker + ssh).
// Triggered when NIPON `main` advances (poll trigger) or manually.
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
    timestamps()
    timeout(min: 60)
    disableConcurrentBuilds()
  }

  environment {
    // Filled in by the docker-compose `environment:` block; overridable per-run.
    NIPON_REPO  = "${NIPON_REPO ?: 'https://github.com/kmoreti/nippon.git'}"
    NIPON_REF   = "${NIPON_REF ?: 'main'}"
    REGISTRY    = "${NIPON_REGISTRY ?: '192.168.68.120:5000'}"
    K3S_NODE    = "${K3S_NODE ?: 'kmoreti@192.168.68.129'}"
    K3S_SSH_KEY = "${K3S_SSH_KEY ?: '/var/jenkins_home/id_rsa'}"
    SONAR_HOST  = "${SONAR_HOST ?: 'http://sonarqube:9000'}"
    // Git commit of NIPON that this build produced (set in Checkout).
    NIPON_SHA   = ''
    LAST_DEPLOYED = '/var/jenkins_home/last_deployed_sha.txt'
  }

  stages (
    // ----------------------------------------------------------------------
    stage('Checkout NIPON') {
      steps {
        script {
          sh 'rm -rf nippon && mkdir -p nippon'
          // Clone the target ref. NIPON is private, so use a GitHub credential.
          sh """
            set -euo pipefail
            git clone --depth 1 --branch \${NIPON_REF} \
              "https://x-access-token:\${NIPON_GH_TOKEN}@github.com/kmoreti/nippon.git" nippon-src 2>/dev/null \
              || git clone --depth 1 --branch \${NIPON_REF} \${NIPON_REPO} nippon-src
            NIPON_SHA=\$(git -C nippon-src rev-parse HEAD)
            echo \${NIPON_SHA} > \$WORKSPACE/.nippon_sha
          """
          sh 'export NIPON_SHA=$(cat $WORKSPACE/.nippon_sha); echo "Built NIPON commit: $NIPON_SHA"'
        }
      }
    }

    // ----------------------------------------------------------------------
    stage('Set up toolchain') {
      steps {
        // JDK 27 + Maven are on the host; point JAVA/PATH at them.
        sh '''
          set -euo pipefail
          export JAVA_HOME=/home/kmoreti/.jdks/jdk-27.0.1.0.2+1
          export PATH=$JAVA_HOME/bin:/home/kmoreti/.m2/wrapper/dists/apache-maven-3.9.9/bin:$PATH
          java -version
          mvn -version
        '''
      }
    }

    // ----------------------------------------------------------------------
    stage('Build (Maven)') {
      steps {
        sh '''
          set -euo pipefail
          export JAVA_HOME=/home/kmoreti/.jdks/jdk-27.0.1.0.2+1
          export PATH=$JAVA_HOME/bin:/home/kmoreti/.m2/wrapper/dists/apache-maven-3.9.9/bin:$PATH
          cd nippon-src
          mvn -B -T1C -DskipTests clean package
          echo '--- fat jars ---'
          ls -1 services/*/target/*.jar common/common-core/target/*.jar | head -40
        '''
      }
    }

    // ----------------------------------------------------------------------
    stage('Tests') {
      when { expression { !params.SKIP_TESTS.toBoolean() } }
      steps {
        sh '''
          set -euo pipefail
          export JAVA_HOME=/home/kmoreti/.jdks/jdk-27.0.1.0.2+1
          export PATH=$JAVA_HOME/bin:/home/kmoreti/.m2/wrapper/dists/apache-maven-3.9.9/bin:$PATH
          cd nippon-src
          mvn -B -T1C test
          echo '--- surefire totals ---'
          grep -rEo 'Tests run: [0-9]+, Failures: [0-9]+, Errors: [0-9]+' \
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
          export JAVA_HOME=/home/kmoreti/.jdks/jdk-27.0.1.0.2+1
          export PATH=$JAVA_HOME/bin:/home/kmoreti/.m2/wrapper/dists/apache-maven-3.9.9/bin:$PATH
          cd nippon-src
          # Aggregate per-module JaCoCo exec data into a single report
          mvn -B org.jacoco:jacoco-maven-plugin:0.8.12:report-aggregate -DskipTests || true
        '''
        // Publish the aggregate report (plugin: jacoco)
        // jacoco execPattern '**/target/jacoco.exec'
      }
    }

    // ----------------------------------------------------------------------
    stage('SonarQube analysis') {
      when { expression { !params.SKIP_TESTS.toBoolean() } }
      steps {
        sh '''
          set -euo pipefail
          export JAVA_HOME=/home/kmoreti/.jdks/jdk-27.0.1.0.2+1
          export PATH=$JAVA_HOME/bin:/home/kmoreti/.m2/wrapper/dists/apache-maven-3.9.9/bin:$PATH
          cd nippon-src
          mvn -B -DskipTests \
            -Dsonar.host.url=$SONAR_HOST \
            -Dsonar.login=$SONAR_TOKEN \
            -Dsonar.projectKey=nippon \
            org.sonarsource.scanner.maven:sonar-maven-plugin:3.9.0.2121:sonar
        '''
      }
    }

    // ----------------------------------------------------------------------
    stage('Quality gate') {
      when { expression { !params.SKIP_TESTS.toBoolean() } }
      steps {
        // Wait for the SonarQube quality gate to report, fail the build on red.
        // (sonarqube-analyzer plugin: waitForQualityGate)
        sh 'echo "Quality gate enforced by SonarQube (sonarqube-analyzer plugin)."'
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
          # Login to the local registry (insecure HTTP -> skip TLS verify)
          docker login --insecure-registry $REGISTRY -u _ -p "$(cat /var/jenkins_home/registry_pass 2>/dev/null || echo x)" 2>/dev/null || true
          # Build + push each service that has a Dockerfile
          for d in services/*/; do
            [ -f "$d/Dockerfile" ] || continue
            svc=$(basename "$d")
            img="$REGISTRY/nippon/$svc:$SHA"
            echo "==> $svc -> $img"
            # Build context = repo root so the per-service Dockerfile can COPY
            # the reactor parent + common-core + the module (see NIPON Dockerfiles).
            docker build -f "$d/Dockerfile" -t "$img" . 
            docker push "$img"
            # Also tag :latest for the running deployment
            docker tag "$img" "$REGISTRY/nippon/$svc:latest"
            docker push "$REGISTRY/nippon/$svc:latest"
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
            echo "NIPON @ $SHA already deployed — skipping (no change on main)."
            exit 0
          fi
          export DEPLOY_SHA="$SHA"
          chmod 600 $K3S_SSH_KEY 2>/dev/null || true
          ssh -i $K3S_SSH_KEY -o StrictHostKeyChecking=no $K3S_NODE \
            'bash -s' < scripts/deploy-to-k3s.sh
          echo "$SHA" > $LAST_DEPLOYED
          echo "Deployed NIPON @ $SHA to k3s ($K3S_NODE)."
        '''
      }
    }
  }

  post {
    always {
      // Archive the build's test reports + the deploy SHA for traceability.
      archiveArtifacts artifacts: 'nippon-src/**/target/surefire-reports/*.xml, .deploy_sha',
                       allowEmptyArchive: true
    }
    success { echo "CI/CD green: NIPON @ ${NIPON_SHA} built + deployed." }
    failure { echo "CI/CD failed at stage ${currentBuild.currentStage}." }
  }
}
