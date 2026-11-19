/*
 * NIPON CI/CD — Jenkins first-boot bootstrap.
 *
 * Mounted to /usr/share/jenkins/ref/init.groovy.d/init.groovy and run on every
 * boot. It (1) creates the GitHub token credential the job needs to clone the
 * PRIVATE kmoreti/nippon repo, and (2) creates/updates the `nippon-cicd`
 * Pipeline job from the mounted config.xml. The jenkins/jenkins:lts-jdk21 image
 * already bundles git + workflow-cps + workflow-job, so no update-center install
 * is needed (and the LAN has no public update-center access).
 */
import jenkins.model.Jenkins
import com.cloudbees.plugins.credentials.SystemCredentialsProvider
import com.cloudbees.plugins.credentials.CredentialsScope
import com.cloudbees.plugins.credentials.domains.Domain
import com.cloudbees.plugins.credentials.impl.UsernamePasswordCredentialsImpl
import java.util.logging.Logger

log = Logger.getLogger('nippon-cicd-init')

// --- 1) GitHub token credential so the job can clone the PRIVATE nippon repo ---
// The job's SCM points at kmoreti/nippon.git (private), so a job-level checkout
// needs a token. It comes from the NIPON_GH_TOKEN env var (the .env GITHUB_TOKEN
// injected by docker-compose). Created as a GLOBAL System credential.
try {
    def token = System.getenv('NIPON_GH_TOKEN')
    if (token && token.trim()) {
        def store = SystemCredentialsProvider.getInstance().getStore()
        def domain = Domain.global()
        def id = 'nippon-gh-token'
        def existing = store.getCredentials(domain).find { it.id == id }
        def cred = new UsernamePasswordCredentialsImpl(
            CredentialsScope.GLOBAL, id,
            'NIPON GitHub token (clone private kmoreti/nippon)',
            'x-access-token', token)
        if (existing != null) {
            store.updateCredentials(domain, existing, cred)
            log.info("updated credential ${id}")
        } else {
            store.addCredentials(domain, cred)
            log.info("created credential ${id}")
        }
    } else {
        log.warning('NIPON_GH_TOKEN not set; skipping nippon-gh-token credential')
    }
} catch (Exception e) {
    log.warning("credential creation failed: ${e.message}")
}

// --- 1b) SonarQube login credential for the analysis ---
// This SonarQube 9.9.8 build accepts the default admin:admin login, but its
// user-token API 401s, so the analysis authenticates with admin:admin via a
// GLOBAL username/password credential the pipeline binds at run time.
try {
    def store = SystemCredentialsProvider.getInstance().getStore()
    def domain = Domain.global()
    def id = 'sonar-admin'
    def existing = store.getCredentials(domain).find { it.id == id }
    def cred = new UsernamePasswordCredentialsImpl(
        CredentialsScope.GLOBAL, id,
        'NIPON SonarQube admin (analysis login)',
        'admin', 'admin')
    if (existing != null) {
        store.updateCredentials(domain, existing, cred)
        log.info("updated credential ${id}")
    } else {
        store.addCredentials(domain, cred)
        log.info("created credential ${id}")
    }
} catch (Exception e) {
    log.warning("sonar-admin credential creation failed: ${e.message}")
}

// --- 2) git safe.directory so checkout doesn't fail with "dubious
// ownership" (the pipeline build runs as root, but the workspace .git is
// owned by the jenkins user; trust all workspaces via the system config) ---
try {
    def proc = new ProcessBuilder('sh', '-c', 'git config --system --add safe.directory "*"')
        .redirectErrorStream(true).start()
    proc.waitFor()
    log.info("git safe.directory=* (avoids dubious-ownership on checkout)")
} catch (Exception e) {
    log.warning("git safe.directory setup failed: ${e.message}")
}

// --- 3) the pipeline job from the mounted config.xml ---
try {
    def cfg = '/opt/nippon/jobs/nippon-cicd/config.xml'
    def f = new File(cfg)
    if (!f.exists()) {
        log.warning("no config.xml at ${cfg}; job will be created by scripts/seed.sh")
        return
    }
    def jenkins = Jenkins.get()
    def name = 'nippon-cicd'
    if (jenkins.getItem(name) == null) {
        log.info("creating pipeline job ${name} from ${cfg}")
        jenkins.createProjectFromXML(name, f.text)
        log.info("job ${name} created")
    } else {
        // keep the job's config in sync with the repo
        log.info("job ${name} exists; updating from ${cfg}")
        jenkins.getItem(name).updateByXml(f.text)
    }
} catch (Exception e) {
    log.warning("init.groovy job creation failed: ${e.message} (seed.sh is the fallback)")
}
