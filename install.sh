#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Instalator prompt_master ===${NC}"

# 0. Zależności
echo ""
echo -e "${YELLOW}Instalacja zależności...${NC}"
sudo apt update -qq
sudo apt install -y git curl ca-certificates gnupg zenity openssh-client 2>/dev/null || true

if ! command -v docker &>/dev/null; then
    echo "Instalacja Dockera..."
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sudo sh /tmp/get-docker.sh
    rm -f /tmp/get-docker.sh
fi

sudo groupadd docker 2>/dev/null || true
sudo usermod -aG docker "$USER" 2>/dev/null || true
sudo systemctl enable docker 2>/dev/null || true
sudo systemctl start docker 2>/dev/null || true
echo -e "${GREEN}✓ Git, Docker gotowe${NC}"

# 1. Deploy Key + repo
REPO_SSH="git@github.com:NoSkillSense/prompt_master.git"
INSTALL_DIR="${HOME}/prompt_master"
DEPLOY_KEY_PATH="${HOME}/.ssh/prompt_master_deploy"

mkdir -p "${HOME}/.ssh"

if [ ! -f "$DEPLOY_KEY_PATH" ]; then
    echo "Generowanie klucza Deploy Key..."
    ssh-keygen -t ed25519 -f "$DEPLOY_KEY_PATH" -N "" -C "prompt_master_install"
fi
chmod 600 "$DEPLOY_KEY_PATH"
chmod 644 "${DEPLOY_KEY_PATH}.pub"

echo ""
echo -e "${YELLOW}=== Skopiuj ten klucz do GitHub ===${NC}"
echo ""
echo -e "${GREEN}$(cat ${DEPLOY_KEY_PATH}.pub)${NC}"
echo ""
echo "1. Otwórz: https://github.com/NoSkillSense/prompt_master/settings/keys"
echo "2. Add deploy key → wklej powyższy klucz"
echo ""
read -p "Gdy dodasz klucz, naciśnij Enter..."

export GIT_SSH_COMMAND="ssh -i '$DEPLOY_KEY_PATH' -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes"

echo "Klonowanie repozytorium do ${INSTALL_DIR} (gałąź deploy)..."
if [ -d "$INSTALL_DIR" ]; then
    cd "$INSTALL_DIR"
    git remote set-url origin "$REPO_SSH" 2>/dev/null || true
    git pull origin deploy 2>/dev/null || git pull origin main 2>/dev/null || git pull origin master 2>/dev/null || true
else
    git clone -b deploy "$REPO_SSH" "$INSTALL_DIR"
    cd "$INSTALL_DIR"
fi

git -C "$INSTALL_DIR" remote set-url origin "$REPO_SSH" 2>/dev/null || true
unset GIT_SSH_COMMAND

echo -e "${GREEN}✓ Repozytorium pobrane${NC}"

# 2. Ikona + launcher
mkdir -p "${INSTALL_DIR}/scripts"
ICON_PATH="${INSTALL_DIR}/scripts/prompt-master.svg"

if [ -f "${INSTALL_DIR}/prompt-master.svg" ]; then
    cp "${INSTALL_DIR}/prompt-master.svg" "$ICON_PATH"
else
    cat > "$ICON_PATH" << 'ICON_EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128" width="128" height="128">
  <defs>
    <linearGradient id="bg" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" style="stop-color:#6366f1"/>
      <stop offset="100%" style="stop-color:#8b5cf6"/>
    </linearGradient>
  </defs>
  <rect width="128" height="128" rx="24" fill="url(#bg)"/>
  <path d="M32 44 L50 64 L32 84" stroke="white" stroke-width="8" stroke-linecap="round" stroke-linejoin="round" fill="none"/>
  <rect x="56" y="38" width="40" height="12" rx="4" fill="white" opacity="0.9"/>
  <rect x="56" y="58" width="50" height="12" rx="4" fill="white" opacity="0.6"/>
</svg>
ICON_EOF
fi

LAUNCHER_SCRIPT="${INSTALL_DIR}/scripts/start-app-fullscreen.sh"
if [ ! -f "$LAUNCHER_SCRIPT" ]; then
    cat > "$LAUNCHER_SCRIPT" << 'LAUNCHER_EOF'
#!/bin/bash
INSTALL_DIR="${HOME}/prompt_master"
DEPLOY_KEY_PATH="${HOME}/.ssh/prompt_master_deploy"
APP_PORT="8081"
APP_NAME="Prompt Master"

COMPOSE_DIR="$INSTALL_DIR"
if [ -f "${INSTALL_DIR}/docker-compose.yml" ]; then
    COMPOSE_DIR="${INSTALL_DIR}"
elif [ -f "${INSTALL_DIR}/backend/docker-compose.yml" ]; then
    COMPOSE_DIR="${INSTALL_DIR}/backend"
fi
if [ -f "${COMPOSE_DIR}/docker-compose.yml" ]; then
    DETECTED=$(grep -oP '"\K[0-9]+(?=:[0-9]+")' "${COMPOSE_DIR}/docker-compose.yml" 2>/dev/null | head -1)
    [ -n "$DETECTED" ] && APP_PORT="$DETECTED"
fi
APP_URL="http://localhost:${APP_PORT}"

log() { echo "[$(date +%H:%M:%S)] $*"; }
msg() { zenity --info --title "$APP_NAME" --text "$1" 2>/dev/null || log "$1"; }
err() { zenity --error --title "$APP_NAME" --text "$1" 2>/dev/null || { log "BŁĄD: $1"; exit 1; }; }

PROG_FD=""
[ -n "$DISPLAY" ] && command -v zenity &>/dev/null && exec 3> >(zenity --progress --title="$APP_NAME" --percentage=0 --auto-close --no-cancel 2>/dev/null) && PROG_FD=3
prog() { log "$2"; [ -n "$PROG_FD" ] && echo "$1" >&3 && echo "# $2" >&3; }

cd "$INSTALL_DIR" || { err "Nie znaleziono katalogu: $INSTALL_DIR"; exit 1; }

prog 5 "[1/6] Docker..."
if ! systemctl is-active --quiet docker 2>/dev/null; then
    prog 8 "Uruchamiam Docker..."
    sudo systemctl start docker 2>/dev/null
    for i in $(seq 1 15); do systemctl is-active --quiet docker 2>/dev/null && break; prog 10 "Czekam... ($i/15)"; sleep 1; done
fi

prog 18 "[2/6] .env..."
ENV_FILE=".env"
ENV_EXAMPLE=""
[ -f ".env.example" ] && ENV_EXAMPLE=".env.example"
[ -f "env.example" ] && [ -z "$ENV_EXAMPLE" ] && ENV_EXAMPLE="env.example"
[ -f "../.env.example" ] && [ -z "$ENV_EXAMPLE" ] && ENV_EXAMPLE="../.env.example"
if [ ! -f "$ENV_FILE" ] && [ -n "$ENV_EXAMPLE" ]; then
    cp "$ENV_EXAMPLE" "$ENV_FILE"
    sed -i 's/^KIE_API_KEY=.*/KIE_API_KEY=/' "$ENV_FILE" 2>/dev/null || true
    sed -i 's/^OPENROUTER_API_KEY=.*/OPENROUTER_API_KEY=/' "$ENV_FILE" 2>/dev/null || true
fi

prog 28 "[3/6] Repo..."
HAD_CHANGES=false
if [ -d ".git" ] && [ -f "$DEPLOY_KEY_PATH" ]; then
    export GIT_SSH_COMMAND="ssh -i '$DEPLOY_KEY_PATH' -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes"
    BEFORE=$(git rev-parse HEAD 2>/dev/null || true)
    git fetch origin deploy 2>/dev/null || git fetch origin 2>/dev/null || true
    git pull origin deploy 2>/dev/null || git pull origin main 2>/dev/null || git pull origin master 2>/dev/null || true
    unset GIT_SSH_COMMAND
    AFTER=$(git rev-parse HEAD 2>/dev/null || true)
    [ "$BEFORE" != "$AFTER" ] && HAD_CHANGES=true
fi

cd "$COMPOSE_DIR" || { err "Nie znaleziono docker-compose."; exit 1; }

if [ "$HAD_CHANGES" = true ]; then
    prog 38 "[4/6] Budowanie Docker (wykryto zmiany)..."
    if ! docker compose build 2>&1; then
        sudo docker compose build 2>&1
    fi
    prog 70 "Build zakończony"
else
    prog 45 "[4/6] Brak zmian – pomijam build"
fi

prog 72 "[5/6] Uruchamianie..."
if ! docker compose up -d 2>/dev/null; then
    sudo docker compose up -d 2>/dev/null || { err "Nie można uruchomić Dockera."; exit 1; }
fi

prog 82 "[6/6] Oczekiwanie..."
for i in $(seq 1 45); do
    curl -s "$APP_URL" >/dev/null 2>&1 && break
    prog $((82 + (i * 13) / 45)) "Czekam ($i/45)"
    sleep 2
done

prog 98 "Otwieram przeglądarkę..."
if command -v chromium-browser &>/dev/null; then
    chromium-browser --kiosk "$APP_URL" --noerrdialogs 2>/dev/null &
elif command -v chromium &>/dev/null; then
    chromium --kiosk "$APP_URL" --noerrdialogs 2>/dev/null &
elif command -v google-chrome &>/dev/null; then
    google-chrome --kiosk "$APP_URL" --noerrdialogs 2>/dev/null &
elif command -v firefox &>/dev/null; then
    firefox -kiosk "$APP_URL" 2>/dev/null &
else
    xdg-open "$APP_URL" 2>/dev/null || sensible-browser "$APP_URL" 2>/dev/null || msg "Otwórz: $APP_URL"
fi

prog 100 "Gotowe."
[ -n "$PROG_FD" ] && exec 3>&-
log "Gotowe."
[ -t 0 ] 2>/dev/null && read -r -p "Naciśnij Enter aby zamknąć..."
LAUNCHER_EOF
    chmod +x "$LAUNCHER_SCRIPT"
    echo -e "${GREEN}✓ Utworzono start-app-fullscreen.sh${NC}"
else
    chmod +x "$LAUNCHER_SCRIPT"
fi

# Skrypt restart – zatrzymaj i uruchom od zera
RESTART_SCRIPT="${INSTALL_DIR}/scripts/start-app-restart.sh"
if [ ! -f "$RESTART_SCRIPT" ]; then
    cat > "$RESTART_SCRIPT" << 'RESTART_EOF'
#!/bin/bash
INSTALL_DIR="${HOME}/prompt_master"
log() { echo "[$(date +%H:%M:%S)] $*"; }
err() { zenity --error --title "Prompt Master" --text "$1" 2>/dev/null || { log "BŁĄD: $1"; exit 1; }; }
cd "$INSTALL_DIR" || { err "Nie znaleziono: $INSTALL_DIR"; exit 1; }
COMPOSE_DIR="$INSTALL_DIR"
[ -f "${INSTALL_DIR}/docker-compose.yml" ] || COMPOSE_DIR="${INSTALL_DIR}/backend"
log "=== Restart – zatrzymuję kontenery ==="
cd "$COMPOSE_DIR" || exit 1
docker compose down 2>/dev/null || sudo docker compose down 2>/dev/null || true
log "Uruchamiam pełny start..."
exec "${INSTALL_DIR}/scripts/start-app-fullscreen.sh"
RESTART_EOF
    chmod +x "$RESTART_SCRIPT"
    echo -e "${GREEN}✓ Utworzono start-app-restart.sh${NC}"
else
    chmod +x "$RESTART_SCRIPT"
fi

# 3. PromptMaster.desktop
DESKTOP_ENTRY="${HOME}/.local/share/applications/PromptMaster.desktop"
mkdir -p "${HOME}/.local/share/applications"
mkdir -p "${HOME}/Desktop"

if [ -f "${INSTALL_DIR}/PromptMaster.desktop" ]; then
    sed "s|{{INSTALL_DIR}}|${INSTALL_DIR}|g" "${INSTALL_DIR}/PromptMaster.desktop" > "$DESKTOP_ENTRY"
else
    cat > "$DESKTOP_ENTRY" << EOF
[Desktop Entry]
Type=Application
Name=Prompt Master
Comment=Uruchom Prompt Master (fullscreen)
Exec=${INSTALL_DIR}/scripts/start-app-fullscreen.sh
Icon=${ICON_PATH}
Categories=Application;Development;
Terminal=true
StartupNotify=true
Keywords=prompt;ai;docker;
EOF
fi

cp "$DESKTOP_ENTRY" "${HOME}/Desktop/PromptMaster.desktop"
chmod +x "${HOME}/Desktop/PromptMaster.desktop"
gio set "${HOME}/Desktop/PromptMaster.desktop" metadata::trusted true 2>/dev/null || true

# Ikona restart – gdy coś poszło nie tak
if [ -f "${INSTALL_DIR}/PromptMasterRestart.desktop" ]; then
    sed "s|{{INSTALL_DIR}}|${INSTALL_DIR}|g" "${INSTALL_DIR}/PromptMasterRestart.desktop" > "${HOME}/.local/share/applications/PromptMasterRestart.desktop"
else
    cat > "${HOME}/.local/share/applications/PromptMasterRestart.desktop" << EOF
[Desktop Entry]
Type=Application
Name=Prompt Master (Restart)
Comment=Zatrzymaj i uruchom od zera – gdy coś poszło nie tak
Exec=${INSTALL_DIR}/scripts/start-app-restart.sh
Icon=${ICON_PATH}
Categories=Application;Development;
Terminal=true
StartupNotify=true
Keywords=prompt;ai;docker;restart;
EOF
fi
cp "${HOME}/.local/share/applications/PromptMasterRestart.desktop" "${HOME}/Desktop/PromptMasterRestart.desktop"
chmod +x "${HOME}/Desktop/PromptMasterRestart.desktop"
gio set "${HOME}/Desktop/PromptMasterRestart.desktop" metadata::trusted true 2>/dev/null || true

update-desktop-database "${HOME}/.local/share/applications" 2>/dev/null || true

echo -e "${GREEN}✓ PromptMaster.desktop i PromptMasterRestart.desktop na pulpicie${NC}"

# 4. Usługa systemd
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
mkdir -p "$SYSTEMD_USER_DIR"
USER_UID=$(id -u)

cat > "${SYSTEMD_USER_DIR}/prompt-master.service" << EOF
[Unit]
Description=Prompt Master - kiosk przy starcie sesji
After=graphical-session.target docker.service
Wants=docker.service
PartOf=graphical-session.target

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=DISPLAY=:0
Environment=XDG_RUNTIME_DIR=/run/user/${USER_UID}
ExecStart=${LAUNCHER_SCRIPT}

[Install]
WantedBy=graphical-session.target
EOF

systemctl --user daemon-reload 2>/dev/null || true
systemctl --user enable prompt-master.service 2>/dev/null || true
echo -e "${GREEN}✓ Usługa systemd prompt-master (start przy logowaniu)${NC}"

# 5. Opcjonalnie uruchom teraz
echo ""
if [ -f "${INSTALL_DIR}/docker-compose.yml" ] || [ -f "${INSTALL_DIR}/backend/docker-compose.yml" ]; then
    COMPOSE_DIR="${INSTALL_DIR}"
    [ -f "${INSTALL_DIR}/docker-compose.yml" ] || COMPOSE_DIR="${INSTALL_DIR}/backend"
    echo "Uruchomić aplikację teraz? [y/N]"
    read -r RUN_APP
    if [[ "$RUN_APP" =~ ^[yY] ]]; then
        cd "$COMPOSE_DIR"
        [ ! -f ".env" ] && [ -f ".env.example" ] && cp .env.example .env
        [ ! -f ".env" ] && [ -f "env.example" ] && cp env.example .env
        docker compose up -d --build 2>/dev/null || sudo docker compose up -d --build
        echo -e "${GREEN}✓ Aplikacja uruchomiona${NC}"
    fi
fi

echo ""
echo -e "${GREEN}=== Instalacja zakończona ===${NC}"
echo "Repo: ${INSTALL_DIR}"
echo "Uruchom: PromptMaster.desktop lub PromptMasterRestart.desktop (gdy coś poszło nie tak)"
echo ""
echo -e "${YELLOW}Wyloguj się i zaloguj ponownie, żeby docker działał bez sudo.${NC}"
