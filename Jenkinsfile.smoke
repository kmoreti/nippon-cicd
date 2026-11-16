// Minimal smoke-test pipeline — validates the Jenkins controller can run a
// workflow. Real pipeline is restored once this is confirmed green.
pipeline {
  agent any

  options {
    timestamps()
    timeout(min: 20)
  }

  environment {
    REGISTRY = "192.168.68.120:5000"
  }

  stages {
    stage('hello') {
      steps {
        echo 'hello from NIPON CI/CD'
        sh 'echo shell-ok; uname -a'
      }
    }
  }

  post {
    success { echo 'SMOKE TEST GREEN' }
    failure { echo 'SMOKE TEST FAILED' }
  }
}
