# NIPON CI/CD

CI/CD pipeline for the **NIPON** real-estate microservices platform. On every
merge to `main` of `kmoreti/nippon`, this project builds, tests, quality-gates,
and auto-deploys NIPON to the **k3s** cluster.

```
   merge to NIPON main
            │  (poll / webhook)
            ▼
   ┌──────────────────────────────────────────────────────────┐
   │  Jenkins (this repo's docker-compose)                       │
   │                                                            │
   │  1. checkout NIPON @ main                                   │
   │  2. Maven build  (mvn -T1C clean package)                  │
   │  3. Tests          (mvn test)                               │
   │  4. Coverage       (JaCoCo report-aggregate)                │
   │  5. SonarQube analysis + quality gate (fail on red)         │
   │  6. build + push images → 192.168.68.120:5000              │
   │  7. deploy to k3s (kustomize, pin to build SHA)            │
   └──────────────────────────────────────────────────────────┘
```

## Components

| Container   | Image                     | Role                                             |
|-------------|---------------------------|--------------------------------------------------|
| `jenkins`   | `jenkins/jenkins:lts-jdk21` | CI/CD controller (privileged, mounts Docker sock) |
| `sonarqube` | `sonarqube:lts-community`  | static analysis + coverage quality gate          |
| `sonar-db`  | `postgres:16`             | SonarQube metadata store                         |

## Layout

```
nippon-cicd/
├── docker-compose.yml        # jenkins + sonarqube + sonar-db
├── jenkins/
│   ├── init.groovy           # first-boot: install plugins + (re)create the job
│   └── jobs/nippon-cicd/
│       └── config.xml        # the Jenkins Pipeline job (polls NIPON, script from NIPON SCM)
├── scripts/
│   ├── seed.sh               # wait for Jenkins, create job, kick a build
│   └── fetch-kubeconfig.sh   # optional: pull k3s kubeconfig to a laptop
├── .env.sample               # copy to .env, fill in secrets
└── README.md

# The pipeline itself lives in the NIPON repo, so a merge to its `main` is what
# triggers the build:
nippon/
├── jenkins/
│   ├── Jenkinsfile               # the pipeline (stages below)
│   └── scripts/deploy-to-k3s.sh  # runs ON the node: kustomize apply @ SHA
```

## Quick start

```bash
cp .env.sample .env          # fill REGISTRY, K3S_NODE, GITHUB_TOKEN, SONAR_TOKEN
docker compose up -d         # jenkins :8080  |  sonarqube :9000
./scripts/seed.sh            # create the job + kick the first build
# jenkins  → http://localhost:8080   (admin/admin)
# sonar    → http://localhost:9000   (admin/admin)
```

On first boot `jenkins/init.groovy` installs the pipeline plugins and creates the
`nippon-cicd` job from `jenkins/jobs/nippon-cicd/config.xml` (and re-applies it
on every boot). The job polls NIPON `main` and pulls the `Jenkinsfile` from
**NIPON** (`nippon/jenkins/Jenkinsfile`), so committing a pipeline change to
NIPON updates the job on its next run.

## Pipeline stages

| # | Stage                | What it does                                                        |
|---|----------------------|---------------------------------------------------------------------|
| 1 | Checkout NIPON       | `git clone --depth 1 --branch main` (token via `NIPON_GH_TOKEN`)    |
| 2 | Build                | `mvn -B -T1C -DskipTests clean package` → fat jars                  |
| 3 | Tests                | `mvn -B -T1C test` (Testcontainers use the host Docker daemon)      |
| 4 | Coverage             | JaCoCo `report-aggregate` across all modules                        |
| 5 | SonarQube            | `sonar-maven-plugin:sonar` → publish metrics/coverage to SonarQube   |
| 6 | Quality gate         | fail the build if the SonarQube quality gate is red                 |
| 7 | Build & push images  | per-service `docker build` + `docker push` to `192.168.68.120:5000` |
| 8 | Deploy to k3s        | SSH to the node, `kustomize build | k3s kubectl apply` @ build SHA   |

Stages 3–6 are skippable with the `SKIP_TESTS` parameter (emergency hotfix path);
stage 8 is gated on `DEPLOY=true` and on the built SHA differing from the last
deployed one, so a no-op poll never churns the cluster.

## Triggering on a merge to main

Jenkins runs on a private LAN, so a GitHub **webhook** cannot reach
`127.0.0.1:8080` and the job uses a **poll trigger** (`*/10 * * * *`) instead:
every 10 minutes it checks NIPON `main` and only builds when the HEAD commit
advanced. To switch to webhooks (faster, no polling), expose Jenkins on a public
URL, enable the GitHub webhook receiver, and add a webhook on `kmoreti/nippon`:

```
Payload URL:  https://<jenkins-public>/github-webhook/
Events:       "Push events", "Pull requests"
```

## Deploying to k3s

`nippon/jenkins/scripts/deploy-to-k3s.sh` runs **on the k3s node** (the pipeline
pipes it over SSH). It pins every `nippon/<service>` image to the built SHA via
`kustomize --image` and applies it:

```
kustomize build deploy/k8s --image nippon/security-service=<registry>/…:SHA … \
  | k3s kubectl apply --server-side --force -f -
```

The node resolves the registry via `/etc/rancher/k3s/registries.yaml`
(`docker.io` + `192.168.68.120:5000` → `http://192.168.68.120:5000`, insecure).
The deployed SHA is recorded to `/var/lib/nippon/deployed_sha` for audit + rollback.

## Secrets

All secrets live in `.env` (git-ignored) and are injected into the Jenkins
container via the `environment:` block: `GITHUB_TOKEN` (clone NIPON),
`SONAR_TOKEN` (SonarQube analysis), `K3S_SSH_KEY` (deploy over SSH). The k3s
kubeconfig and SSH key are mounted from `jenkins/` (also git-ignored).
