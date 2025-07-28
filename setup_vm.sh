#!/bin/bash

# Скрипт для автоматической настройки новой ВМ, установки Docker и Jenkins.
# Устанавливает Jenkins с пользователем 'admin' и паролем 'admin' для удобства тестирования.
# ВНИМАНИЕ: НЕ ИСПОЛЬЗУЙТЕ В ПРОДАКШЕНЕ С ТАКИМИ ПАРОЛЯМИ!

# Выход при любой ошибке
set -e

echo "--- Начинаем автоматическую настройку ВМ ---"

# --- 1. Обновление системных пакетов ---
echo "--- Обновление системных пакетов ---"
sudo apt update
sudo apt upgrade -y
sudo apt autoremove -y

echo "--- Системные пакеты обновлены ---"

# --- 2. Установка Docker ---
echo "--- Установка Docker и необходимых зависимостей ---"

# Установка пакетов, необходимых для использования репозитория Docker через HTTPS
sudo apt install -y apt-transport-https ca-certificates curl gnupg lsb-release

# Добавление официального GPG ключа Docker
echo "Добавление GPG ключа Docker..."
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
if [ $? -ne 0 ]; then
    echo "Ошибка при добавлении GPG ключа Docker. Проверьте подключение к интернету или права."
    exit 1
fi

# Добавление стабильного репозитория Docker
echo "Добавление репозитория Docker..."
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
if [ $? -ne 0 ]; then
    echo "Ошибка при добавлении репозитория Docker. Проверьте подключение к интернету или права."
    exit 1
fi

# Обновление индекса пакетов APT с новым репозиторием Docker
echo "Обновление списка пакетов после добавления репозитория Docker..."
sudo apt update

# Установка Docker Engine
echo "Установка Docker Engine..."
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
if [ $? -ne 0 ]; then
    echo "Ошибка при установке Docker Engine. Проверьте подключение к интернету или права."
    exit 1
fi

# Добавление текущего пользователя в группу 'docker' для выполнения команд без sudo
echo "Добавление текущего пользователя в группу 'docker'..."
sudo usermod -aG docker "$USER"

# Включение и запуск службы Docker
echo "Включение и запуск службы Docker..."
sudo systemctl enable docker
sudo systemctl start docker

# Проверка статуса Docker после попытки запуска
if sudo systemctl is-active --quiet docker; then
    echo "--- Docker успешно установлен и запущен ---"
else
    echo "--- Ошибка: Служба Docker не запущена после установки. Попытка перезапуска ВМ ---"
    echo "Внимание: скрипт перезагрузит ВМ для запуска Docker. Вам нужно будет снова запустить скрипт после перезагрузки."
    sudo reboot
    exit 0 # Выходим, чтобы скрипт перезапустился после ребута
fi


echo "Для того чтобы изменения группы 'docker' вступили в силу, вам может понадобиться перезайти в систему или выполнить 'newgrp docker'."

# --- 3. Установка и запуск Jenkins в Docker с фиксированным паролем ---
echo "--- Установка и запуск Jenkins в Docker с пользователем admin/admin ---"

# Создание каталога для данных Jenkins (для постоянства данных)
echo "Создание каталога для данных Jenkins (/var/jenkins_home)..."
sudo mkdir -p /var/jenkins_home
# Установка владельца (Jenkins user ID inside container is 1000)
# Это важно, чтобы Jenkins мог писать в эту директорию
sudo chown -R 1000:1000 /var/jenkins_home

# Создание каталога для инициализирующих Groovy-скриптов
INIT_SCRIPTS_DIR="/var/jenkins_home/init.groovy.d"
sudo mkdir -p "$INIT_SCRIPTS_DIR"

# Создание Groovy-скрипта для создания пользователя 'admin' с паролем 'admin'
INIT_SCRIPT_FILE="$INIT_SCRIPTS_DIR/create-admin-user.groovy"
sudo bash -c "cat <<EOF > '$INIT_SCRIPT_FILE'
import jenkins.model.*
import hudson.security.*

def instance = Jenkins.getInstance()

// Ensure security is enabled if it's not already
if (!instance.isUseSecurity()) {
    instance.setSecurityRealm(new HudsonPrivateSecurityRealm(false))
    instance.setAuthorizationStrategy(new GlobalMatrixAuthorizationStrategy())
    instance.save()
}

// Check if user 'admin' already exists
def adminUser = instance.getSecurityRealm().getUser('admin')
if (adminUser == null) {
    // Create new user 'admin' with password 'admin'
    def hudsonUser = instance.getSecurityRealm().createAccount('admin', 'admin')
    hudsonUser.save()
    println 'Jenkins: User \"admin\" created with password \"admin\"'
} else {
    // If user 'admin' exists, update its password (optional, but good for idempotent script runs)
    adminUser.setPassword('admin')
    adminUser.save()
    println 'Jenkins: User \"admin\" already exists. Password updated to \"admin\"'
}

// Add 'admin' user to global administer permissions if not already there
def strategy = instance.getAuthorizationStrategy()
if (strategy instanceof GlobalMatrixAuthorizationStrategy) {
    if (!strategy.hasPermission(adminUser.getId(), Jenkins.ADMINISTER)) {
        strategy.add(Jenkins.ADMINISTER, adminUser.getId())
        instance.setAuthorizationStrategy(strategy) // Re-set strategy to apply changes
        instance.save()
        println 'Jenkins: Admin user granted ADMINISTER permission.'
    }
}

// Disable setup wizard to go directly to login (optional but makes sense for automated setup)
System.setProperty('jenkins.install.runSetupWizard', 'false')
println 'Jenkins: Setup wizard disabled.'
EOF"
sudo chown -R 1000:1000 "$INIT_SCRIPTS_DIR" # Установка владельца для скрипта

# Проверка, запущен ли уже Jenkins, и остановка/удаление, если да
if sudo docker ps -a --format '{{.Names}}' | grep -q "^jenkins_master$"; then
    echo "Контейнер 'jenkins_master' уже существует. Останавливаем и удаляем его."
    sudo docker stop jenkins_master || true
    sudo docker rm jenkins_master || true
fi

# Загрузка образа Jenkins LTS (Long Term Support)
echo "Загрузка образа Jenkins LTS (jenkins/jenkins:lts)..."
sudo docker pull jenkins/jenkins:lts
if [ $? -ne 0 ]; then
    echo "Ошибка при загрузке образа Jenkins. Проверьте подключение к интернету."
    exit 1
fi

# Запуск контейнера Jenkins
echo "Запуск контейнера Jenkins..."
sudo docker run \
  -d \
  -p 8080:8080 \
  -p 50000:50000 \
  -v /var/jenkins_home:/var/jenkins_home \
  --restart unless-stopped \
  --name jenkins_master \
  jenkins/jenkins:lts

if [ $? -ne 0 ]; then
    echo "Ошибка при запуске контейнера Jenkins."
    exit 1
fi

echo "--- Jenkins успешно запущен в Docker ---"
echo "--- Настройка ВМ завершена! ---"

echo "************************************************************************"
echo "Jenkins будет доступен по адресу: http://<IP_адрес_вашей_ВМ>:8080"
echo " "
echo "Внимание! Для тестовой среды пользователь 'admin' создан с паролем 'admin'."
echo "КРАЙНЕ РЕКОМЕНДУЕТСЯ СМЕНИТЬ ЭТОТ ПАРОЛЬ ПОСЛЕ ПЕРВОГО ВХОДА."
echo " "
echo "Если Docker команды не работают без sudo, ВЫЙДИТЕ И ЗАЙДИТЕ СНОВА в SSH-сессию"
echo "или выполните 'newgrp docker'."
echo "************************************************************************"
