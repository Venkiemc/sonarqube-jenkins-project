#!/bin/bash
set -euxo pipefail

# Backup and safely update sysctl settings
cp /etc/sysctl.conf /root/sysctl.conf_backup
echo "vm.max_map_count=262144" >> /etc/sysctl.conf
echo "fs.file-max=65536" >> /etc/sysctl.conf
sysctl -p

# Set user limits properly
cp /etc/security/limits.conf /root/sec_limit.conf_backup
echo "sonarqube   -   nofile   65536" >> /etc/security/limits.conf
echo "sonarqube   -   nproc    4096" >> /etc/security/limits.conf

# Install Java
apt-get update -y
apt-get install openjdk-21-jdk -y

# Install PostgreSQL
wget -q https://www.postgresql.org/media/keys/ACCC4CF8.asc -O - | apt-key add -
sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt/ $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
apt-get update -y
apt-get install postgresql postgresql-contrib -y
systemctl enable postgresql
systemctl start postgresql

# Setup PostgreSQL user and DB for SonarQube
echo "postgres:admin123" | chpasswd
runuser -l postgres -c "createuser sonar"
runuser -l postgres -c "psql -c \"ALTER USER sonar WITH ENCRYPTED PASSWORD 'admin123';\""
runuser -l postgres -c "psql -c \"CREATE DATABASE sonarqube OWNER sonar;\""
runuser -l postgres -c "psql -c \"GRANT ALL PRIVILEGES ON DATABASE sonarqube TO sonar;\""
systemctl restart postgresql

# Install SonarQube
mkdir -p /sonarqube/
cd /sonarqube/
curl -O https://binaries.sonarsource.com/Distribution/sonarqube/sonarqube- 26.4.0.121862.zip
apt-get install unzip -y
unzip -o sonarqube- 26.4.0.121862.zip -d /opt/
mv /opt/sonarqube- 26.4.0.121862/ /opt/sonarqube

# Create user and assign ownership
groupadd sonar
useradd -c "SonarQube - User" -d /opt/sonarqube/ -g sonar sonar
chown -R sonar:sonar /opt/sonarqube/

# Configure SonarQube
cp /opt/sonarqube/conf/sonar.properties /root/sonar.properties_backup
cat <<EOT > /opt/sonarqube/conf/sonar.properties
sonar.jdbc.username=sonar
sonar.jdbc.password=admin123
sonar.jdbc.url=jdbc:postgresql://localhost/sonarqube
sonar.web.host=0.0.0.0
sonar.web.port=9000
sonar.web.javaAdditionalOpts=-server
sonar.search.javaOpts=-Xmx512m -Xms512m -XX:+HeapDumpOnOutOfMemoryError
sonar.log.level=INFO
sonar.path.logs=logs
EOT

# Setup SonarQube systemd service
cat <<EOT > /etc/systemd/system/sonarqube.service
[Unit]
Description=SonarQube service
After=syslog.target network.target

[Service]
Type=forking
ExecStart=/opt/sonarqube/bin/linux-x86-64/sonar.sh start
ExecStop=/opt/sonarqube/bin/linux-x86-64/sonar.sh stop
User=sonar
Group=sonar
Restart=always
LimitNOFILE=65536
LimitNPROC=4096

[Install]
WantedBy=multi-user.target
EOT

systemctl daemon-reload
systemctl enable sonarqube.service

# Install and configure NGINX as reverse proxy
apt-get install nginx -y
rm -f /etc/nginx/sites-enabled/default
rm -f /etc/nginx/sites-available/default

cat <<'EOT' > /etc/nginx/sites-available/sonarqube
server {
    listen 80;
    server_name sonarqube.groophy.in;

    access_log  /var/log/nginx/sonar.access.log;
    error_log   /var/log/nginx/sonar.error.log;

    proxy_buffers 16 64k;
    proxy_buffer_size 128k;

    location / {
        proxy_pass  http://127.0.0.1:9000;
        proxy_next_upstream error timeout invalid_header http_500 http_502 http_503 http_504;
        proxy_redirect off;

        proxy_set_header    Host            $host;
        proxy_set_header    X-Real-IP       $remote_addr;
        proxy_set_header    X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header    X-Forwarded-Proto http;
    }
}
EOT

ln -s /etc/nginx/sites-available/sonarqube /etc/nginx/sites-enabled/sonarqube
systemctl enable nginx

# Allow necessary ports
ufw allow 80,9000,9001/tcp || true

# Optionally start services (uncomment if you want to start on boot)
systemctl start sonarqube
systemctl start nginx

# Optional: reboot commented for safety
# echo "System rebooting in 30 sec..."
# sleep 30
# reboot
