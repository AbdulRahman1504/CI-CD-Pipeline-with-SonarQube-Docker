# CI/CD Pipeline on a Single AWS EC2 Server

GitHub -> (webhook) -> Jenkins -> pytest -> SonarQube (quality gate) -> Docker build -> DockerHub -> run container

Everything lives on ONE EC2 instance. Jenkins and SonarQube are installed directly
on the server as normal services. **Only the app image is built and run in Docker.**

| Component  | How it runs                              | Port |
|------------|------------------------------------------|------|
| Jenkins    | Native install (systemd service)         | 8080 |
| SonarQube  | Native install (systemd) + PostgreSQL    | 9000 |
| App        | Docker container, built by the pipeline  | 5000 |

## 0. Instance sizing (important)

Jenkins + SonarQube + PostgreSQL + Docker are memory hungry. A 1 GB `t2.micro`/`t3.micro`
will struggle badly. Check which instance types your account's Free Tier covers
(AWS console > Billing > Free Tier) and pick the largest eligible x86_64 type, ideally
**2 GB+ RAM**. Use Ubuntu 22.04/24.04 and **30 GB gp3** storage. The setup script adds
4 GB swap and caps the JVM heaps. Stop the instance when not in use.

Security group inbound rules:
- 22 (SSH) - your IP only
- 8080 (Jenkins) - your IP + GitHub (or `0.0.0.0/0` for the demo)
- 9000 (SonarQube) - your IP only
- 5000 (App) - your IP / `0.0.0.0/0`

Allocate an **Elastic IP** so the webhook URL doesn't change on restart.

## 1. Push this repo to GitHub

```bash
git init && git add . && git commit -m "Initial commit"
git branch -M main
git remote add origin https://github.com/<you>/cicd-demo-app.git
git push -u origin main
```

Edit `Jenkinsfile` and replace `YOUR_DOCKERHUB_USER` first.

## 2. Install everything on the server

```bash
ssh -i key.pem ubuntu@<EC2_IP>
git clone https://github.com/<you>/cicd-demo-app.git && cd cicd-demo-app
sudo bash ec2-setup.sh
```

The script installs swap, Java 17, PostgreSQL, **SonarQube**, **Jenkins** and Docker.
If the SonarQube download 404s, pick the current version from
sonarsource.com/products/sonarqube/downloads and run
`SONAR_VERSION=<version> sudo -E bash ec2-setup.sh`.

Verify:
```bash
systemctl status sonarqube jenkins postgresql docker --no-pager
sudo cat /var/lib/jenkins/secrets/initialAdminPassword
```

### Manual equivalent (what the script does)

1. `sudo apt install openjdk-17-jdk postgresql unzip docker.io`
2. Create DB: `sudo -u postgres psql -c "CREATE USER sonar WITH ENCRYPTED PASSWORD 'xxx';"` and `-c "CREATE DATABASE sonarqube OWNER sonar;"`
3. Set `vm.max_map_count=262144` via `/etc/sysctl.d/`
4. Download the SonarQube zip to `/opt`, create a non-root `sonarqube` user, `chown` the folder
5. Edit `/opt/sonarqube/conf/sonar.properties` (`sonar.jdbc.*`)
6. Create `/etc/systemd/system/sonarqube.service`, then `systemctl enable --now sonarqube`
7. Add the Jenkins apt repo, `apt install jenkins`, `usermod -aG docker jenkins`

## 3. SonarQube setup

1. Open `http://<EC2_IP>:9000` (wait 2-4 min). Login `admin/admin`, set a new password.
2. **Create project** > Manually > key `cicd-demo-app`, name `CI/CD Demo App`.
3. **My Account > Security > Generate Token** (Global Analysis Token). Copy it.
4. **Quality Gates**: use "Sonar way" or your own (e.g. new-code coverage >= 80%, no new bugs/vulnerabilities). Make sure it is assigned to the project.
5. **Webhook** (so Jenkins gets the gate result): *Administration > Configuration > Webhooks > Create*
   - Name: `jenkins`
   - URL: `http://localhost:8080/sonarqube-webhook/`
     (Both run on the same host, so `localhost` works.)

## 4. Jenkins configuration

**Plugins** (Manage Jenkins > Plugins > Available): `SonarQube Scanner`, `GitHub`, `Docker Pipeline`, `Role-based Authorization Strategy`.

**Credentials** (Manage Jenkins > Credentials > Global > Add):
- *Username with password*, ID `dockerhub-creds`: DockerHub username + an **access token** (Docker Hub > Account Settings > Security).
- *Secret text*, ID `sonar-token`: the SonarQube token from step 3.

**SonarQube server** (Manage Jenkins > System > SonarQube servers):
- Name `sonarqube`, URL `http://localhost:9000`, token = `sonar-token`.

**Scanner tool** (Manage Jenkins > Tools > SonarQube Scanner):
- Name `sonar-scanner`, Install automatically from Maven Central.

**Pipeline job:** New Item > Pipeline > `cicd-demo-app`:
- Build Triggers: tick **GitHub hook trigger for GITScm polling**
- Pipeline: *Pipeline script from SCM* > Git > repo URL > branch `*/main` > Script Path `Jenkinsfile`

## 5. GitHub webhook

GitHub repo > Settings > Webhooks > Add webhook:
- Payload URL: `http://<EC2_IP>:8080/github-webhook/`
- Content type: `application/json`
- Event: *Just the push event*

## 6. Secure Jenkins (new user + role-based access)

1. **Manage Jenkins > Security**: Security Realm = *Jenkins' own user database* (untick sign-up); Authorization = **Role-Based Strategy**. Save.
2. **Manage Jenkins > Users > Create User**: `dev-user` with a strong password.
3. **Manage and Assign Roles > Manage Roles**
   - `admin`: all permissions
   - `developer`: Overall/Read; Job/Read, Build, Cancel, Workspace; View/Read
   - `viewer`: Overall/Read; Job/Read
4. **Assign Roles**: your admin user -> `admin`; `dev-user` -> `developer`.
5. Log in as `dev-user`: it can build the job but cannot open *Manage Jenkins* or credentials.

## 7. Run & verify

Push a commit. Stages: Checkout > Build & Test > SonarQube Analysis > Quality Gate > Docker Build > Push to DockerHub > Deploy.

```bash
curl http://<EC2_IP>:5000/
```

To prove the quality gate works, add a bug or hardcoded password, push, and watch the *Quality Gate* stage fail. Revert to go green.

## 8. Screenshots (deliverables)

1. **SonarQube dashboard** - `http://<EC2_IP>:9000/dashboard?id=cicd-demo-app` (gate "Passed" + coverage)
2. **DockerHub tags** - `https://hub.docker.com/r/<user>/cicd-demo-app/tags`
3. **Jenkins security** - *Manage and Assign Roles* + *Users* list
4. (Bonus) Jenkins stage view all green; GitHub webhook "Recent Deliveries" 200.

## Troubleshooting

- **SonarQube won't start:** `systemctl status sonarqube`, `tail -f /opt/sonarqube/logs/sonar.log` and `es.log`. Usual causes: low RAM (add swap/bigger instance), `sysctl vm.max_map_count` not 262144, or wrong DB password in `conf/sonar.properties`.
- **SonarQube refuses to run as root:** the service already runs as the `sonarqube` user; don't start it with sudo manually.
- **Quality Gate stage hangs:** the Sonar webhook (step 3.5) is missing.
- **`permission denied` on docker.sock:** `sudo systemctl restart jenkins` after the group change.
- **Webhook timeout:** security group doesn't allow GitHub to reach 8080.
- **OOM-killed builds:** use a bigger instance, or `sudo systemctl stop sonarqube` when not scanning.
