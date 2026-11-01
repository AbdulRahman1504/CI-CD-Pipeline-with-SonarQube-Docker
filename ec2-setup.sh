#!/usr/bin/env bash
# One-shot setup for Ubuntu 22.04/24.04 (x86_64) on a single AWS EC2 instance.
#
# Installed DIRECTLY on the server (no containers):
#   - Swap, kernel limits
#   - Java 17, PostgreSQL
#   - SonarQube Community Build  (systemd service, port 9000)
#   - Jenkins                    (systemd service, port 8080)
# Docker is installed ONLY so the pipeline can build/push/run the app image.
#
# Run as:  sudo bash ec2-setup.sh
# Optional: SONAR_VERSION=<version> sudo -E bash ec2-setup.sh
set -euo pipefail

if [ "$EUID" -ne 0 ]; then echo "Run with sudo"; exit 1; fi

# Check https://www.sonarsource.com/products/sonarqube/downloads/ for the latest
# Community Build and override with SONAR_VERSION if this one is no longer available.
SONAR_VERSION="${SONAR_VERSION:-25.9.0.112764}"
SONAR_DB_PASS="${SONAR_DB_PASS:-$(openssl rand -hex 12)}"

echo "==> 1/7 Swap (SonarQube + Jenkins need more RAM than free-tier boxes have)"
if ! swapon --show | grep -q swapfile; then
  fallocate -l 4G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

echo "==> 2/7 Kernel limits required by SonarQube's embedded Elasticsearch"
cat >/etc/sysctl.d/99-sonarqube.conf <<EOF
vm.max_map_count=262144
fs.file-max=65536
EOF
sysctl --system >/dev/null
cat >/etc/security/limits.d/99-sonarqube.conf <<EOF
sonarqube   -   nofile   131072
sonarqube   -   nproc    8192
EOF

echo "==> 3/7 Base packages (Java 17, PostgreSQL, Python, Docker for app image only)"
apt-get update -y
apt-get install -y ca-certificates curl gnupg git unzip openssl fontconfig \
  openjdk-17-jdk postgresql postgresql-contrib \
  python3 python3-venv python3-pip docker.io
systemctl enable --now docker postgresql

echo "==> 4/7 PostgreSQL database for SonarQube"
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='sonar'" | grep -q 1; then
  sudo -u postgres psql -c "CREATE USER sonar WITH ENCRYPTED PASSWORD '${SONAR_DB_PASS}';"
  sudo -u postgres psql -c "CREATE DATABASE sonarqube OWNER sonar;"
  echo "${SONAR_DB_PASS}" > /root/sonar-db-pass.txt
  chmod 600 /root/sonar-db-pass.txt
  echo "    DB password saved to /root/sonar-db-pass.txt"
else
  echo "    sonar DB user already exists - reusing (password from /root/sonar-db-pass.txt)"
  SONAR_DB_PASS="$(cat /root/sonar-db-pass.txt)"
fi

echo "==> 5/7 SonarQube ${SONAR_VERSION} (native install)"
id sonarqube >/dev/null 2>&1 || useradd --system --home-dir /opt/sonarqube --shell /usr/sbin/nologin sonarqube
if [ ! -d "/opt/sonarqube-${SONAR_VERSION}" ]; then
  cd /tmp
  curl -fL -o sonarqube.zip "https://binaries.sonarsource.com/Distribution/sonarqube/sonarqube-${SONAR_VERSION}.zip"
  unzip -q sonarqube.zip -d /opt
  mv "/opt/sonarqube-${SONAR_VERSION}" "/opt/sonarqube-${SONAR_VERSION}.tmp" 2>/dev/null || true
  mv "/opt/sonarqube-${SONAR_VERSION}.tmp" "/opt/sonarqube-${SONAR_VERSION}"
  rm -f sonarqube.zip
fi
ln -sfn "/opt/sonarqube-${SONAR_VERSION}" /opt/sonarqube

# Configure DB + keep JVM heaps small for a small instance
CONF=/opt/sonarqube/conf/sonar.properties
if ! grep -q '^# --- managed by ec2-setup.sh' "$CONF"; then
cat >>"$CONF" <<EOF

# --- managed by ec2-setup.sh ---
sonar.jdbc.username=sonar
sonar.jdbc.password=${SONAR_DB_PASS}
sonar.jdbc.url=jdbc:postgresql://localhost/sonarqube
sonar.web.host=0.0.0.0
sonar.web.port=9000
sonar.web.javaOpts=-Xmx512m -Xms128m -XX:+HeapDumpOnOutOfMemoryError
sonar.ce.javaOpts=-Xmx512m -Xms128m -XX:+HeapDumpOnOutOfMemoryError
sonar.search.javaOpts=-Xmx512m -Xms512m -XX:MaxDirectMemorySize=256m -XX:+HeapDumpOnOutOfMemoryError
EOF
fi
chown -R sonarqube:sonarqube "/opt/sonarqube-${SONAR_VERSION}"

cat >/etc/systemd/system/sonarqube.service <<EOF
[Unit]
Description=SonarQube service
After=syslog.target network.target postgresql.service

[Service]
Type=forking
ExecStart=/opt/sonarqube/bin/linux-x86-64/sonar.sh start
ExecStop=/opt/sonarqube/bin/linux-x86-64/sonar.sh stop
User=sonarqube
Group=sonarqube
Restart=always
LimitNOFILE=131072
LimitNPROC=8192
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now sonarqube

echo "==> 6/7 Jenkins (native install)"
install -d /etc/apt/keyrings
curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key -o /etc/apt/keyrings/jenkins-keyring.asc
echo "deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" > /etc/apt/sources.list.d/jenkins.list
apt-get update -y
apt-get install -y jenkins
# Jenkins needs the Docker socket only to build/push/run the app image
usermod -aG docker jenkins
mkdir -p /etc/systemd/system/jenkins.service.d
cat >/etc/systemd/system/jenkins.service.d/override.conf <<EOF
[Service]
Environment="JAVA_OPTS=-Djava.awt.headless=true -Xmx512m -Xms128m"
EOF
systemctl daemon-reload
systemctl enable --now jenkins
systemctl restart jenkins

echo "==> 7/7 Done"
echo
echo "Jenkins    : http://<EC2_PUBLIC_IP>:8080"
echo "  Unlock password : sudo cat /var/lib/jenkins/secrets/initialAdminPassword"
echo "SonarQube  : http://<EC2_PUBLIC_IP>:9000   (login admin / admin; first start takes 2-4 min)"
echo "  Status/logs     : systemctl status sonarqube ;  tail -f /opt/sonarqube/logs/sonar.log"
echo "App        : http://<EC2_PUBLIC_IP>:5000   (after the first successful pipeline run)"
