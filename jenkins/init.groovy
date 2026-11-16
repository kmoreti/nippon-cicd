/*
 * NIPON CI/CD — Jenkins first-boot bootstrap.
 *
 * Mounted to /usr/share/jenkins/ref/init.groovy.d/init.groovy and copied into
 * jenkins_home on first boot, so it runs once. It creates the `nippon-cicd`
 * Pipeline job from the mounted config.xml. The jenkins/jenkins:lts-jdk21 image
 * already bundles git + workflow-cps + workflow-job, so no update-center install
 * is needed (and the LAN has no public update-center access).
 */
import jenkins.model.Jenkins
import java.util.logging.Logger

log = Logger.getLogger('nippon-cicd-init')

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
