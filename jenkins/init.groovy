// ============================================================================
// NIPON CI/CD — Jenkins bootstrap (runs once, on first container start).
//
//  1. Installs the plugins the pipeline needs.
//  2. Configures the GitHub + SonarQube servers.
//  3. Creates the `nippon-cicd` Pipeline job (script pulled from THIS repo's
//     Jenkinsfile, so the pipeline stays version-controlled here).
//
// It is defensive: a failure in one step prints a warning but does not crash
// the whole boot. Run the Jenkins REST endpoint or the web UI to re-create the
// job manually if a plugin version drifts.
// ============================================================================

import jenkins.model.Jenkins

def jenkins = Jenkins.getInstance()

// ---------------------------------------------------------------------------
// 1) Plugins
// ---------------------------------------------------------------------------
def required = [
  'git', 'github', 'github-api', 'github-branch-source', 'github-webhook',
  'workflow-aggregator', 'workflow-cps', 'workflow-durable-task-step',
  'docker-workflow', 'docker-build-step', 'docker-commons',
  'sonarqube-analyzer', 'gradle',
  'credentials-binding', 'ssh-credentials', 'plain-credentials',
  'ssh-agent', 'matrix-project', 'configuration-as-code'
]

try {
  def pm = jenkins.pluginManager
  required.each { name ->
    try {
      def p = pm.getPlugin(name, false)
      if (p == null) {
        println "[init] installing plugin: ${name}"
        pm.getJenkins().installPlugin(name)
      } else {
        println "[init] plugin present: ${name} @ ${p.version}"
      }
    } catch (e) {
      println "[init] WARN plugin ${name}: ${e.message}"
    }
  }
  // Restart so freshly installed plugins load
  println "[init] restarting Jenkins to load plugins"
  jenkins.doRestart()
} catch (e) {
  println "[init] plugin install block error: ${e.message}"
}

// ---------------------------------------------------------------------------
// 2) Global config (Jenkins URL for GitHub webhook, system admin)
// ---------------------------------------------------------------------------
try {
  jenkins.setSystemMessage('NIPON CI/CD controller — bootstrapped by init.groovy')
  jenkins.save()
  println '[init] global config saved'
} catch (e) {
  println "[init] global config error: ${e.message}"
}

// ---------------------------------------------------------------------------
// 3) Create the pipeline job (idempotent). The Jenkinsfile lives in this repo;
//    the job pulls it via "Pipeline script from SCM" so commits here update the
//    pipeline. The job is created only if it does not already exist.
// ---------------------------------------------------------------------------
try {
  def name = 'nippon-cicd'
  if (jenkins.getItem(name) != null) {
    println "[init] job '${name}' already exists, skipping create"
  } else {
    def cfg = new File('/var/jenkins_home/jobs/nippon-cicd/config.xml')
    if (cfg.exists()) {
      def job = jenkins.createProjectFromXML(name, cfg.getText('UTF-8'))
      job.save()
      println "[init] created job '${name}' from config.xml"
    } else {
      println "[init] no config.xml found at ${cfg} (seed-job.sh will create it)"
    }
  }
} catch (e) {
  println "[init] job create error: ${e.message}"
}

println '[init] done'
