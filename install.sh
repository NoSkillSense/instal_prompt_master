#!/bin/bash
set -e

# Kolory dla outputu
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Instalator prompt_master ===${NC}"

# 0. Instalacja zależności (git, Docker, Docker Compose itp.)
echo ""
echo -e "${YELLOW}Instalacja zależności systemowych...${NC}"

sudo apt update -qq
sudo apt install -y git curl ca-certificates gnupg zenity openssh-client 2>/dev/null || true

# Docker - sprawdź czy już zainstalowany
if ! command -v docker &>/dev/null; then
    echo "Instalacja Dockera (oficjalny skrypt get.docker.com)..."
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sudo sh /tmp/get-docker.sh
    rm -f /tmp/get-docker.sh
fi

# Użytkownik w grupie docker (bez sudo do dockera)
sudo groupadd docker 2>/dev/null || true
sudo usermod -aG docker "$USER" 2>/dev/null || true
sudo systemctl enable docker 2>/dev/null || true
sudo systemctl start docker 2>/dev/null || true

echo -e "${GREEN}✓ Git, Docker, Docker Compose gotowe${NC}"

# 1. Pobieranie repozytorium – Deploy Key (SSH)
REPO_SSH="git@github.com:NoSkillSense/prompt_master.git"
INSTALL_DIR="${HOME}/prompt_master"
DEPLOY_KEY_PATH="${HOME}/.ssh/prompt_master_deploy"

mkdir -p "${HOME}/.ssh"

# Generuj klucz jeśli nie istnieje
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
echo "2. Kliknij 'Add deploy key'"
echo "3. Title: np. 'Mój komputer'"
echo "4. Wklej powyższy klucz (Ctrl+Shift+V)"
echo "5. Zaznacz 'Allow read access' → Add key"
echo ""
read -p "Gdy dodasz klucz, naciśnij Enter..."

export GIT_SSH_COMMAND="ssh -i '$DEPLOY_KEY_PATH' -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes"

echo "Klonowanie repozytorium do ${INSTALL_DIR} (gałąź deploy)..."
if [ -d "$INSTALL_DIR" ]; then
    echo "Katalog istnieje. Aktualizuję..."
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

# 2. Konfiguracja Ubuntu - nie zawieszaj przy zamknięciu klapki
echo ""
echo -e "${YELLOW}Konfiguracja Ubuntu: tryb bez zawieszania przy zamkniętej klapce...${NC}"

LOGIND_CONF="/etc/systemd/logind.conf"
LOGIND_BACKUP="${LOGIND_CONF}.bak.$(date +%Y%m%d)"

if [ -f "$LOGIND_CONF" ]; then
    # Backup
    sudo cp "$LOGIND_CONF" "$LOGIND_BACKUP" 2>/dev/null || true
    
    # Zmiana HandleLidSwitch - zamknięcie klapki NIE zawiesza
    sudo sed -i 's/^#*HandleLidSwitch=.*/HandleLidSwitch=ignore/' "$LOGIND_CONF"
    if ! grep -q "^HandleLidSwitch=" "$LOGIND_CONF"; then
        echo "HandleLidSwitch=ignore" | sudo tee -a "$LOGIND_CONF" > /dev/null
    fi
    
    # Opcjonalnie: HandleLidSwitchExternalPower - gdy podłączony zasilacz
    sudo sed -i 's/^#*HandleLidSwitchExternalPower=.*/HandleLidSwitchExternalPower=ignore/' "$LOGIND_CONF" 2>/dev/null || true
    
    sudo systemctl restart systemd-logind
    echo -e "${GREEN}✓ Zamknięcie klapki nie będzie zawieszać systemu${NC}"
else
    echo -e "${RED}Nie znaleziono ${LOGIND_CONF} - może to nie jest systemd?${NC}"
fi

# 3. Skrypt do mirrorowania ekranu (uruchamiany ręcznie po podłączeniu zewnętrznego monitora)
MIRROR_SCRIPT="${INSTALL_DIR}/scripts/mirror-display.sh"
mkdir -p "${INSTALL_DIR}/scripts"

cat > "$MIRROR_SCRIPT" << 'MIRROR_EOF'
#!/bin/bash
# Mirror wyświetlacza - ekran zewnętrzny odzwierciedla laptop
# Uruchom po podłączeniu monitora zewnętrznego
# UWAGA: Wymaga X11 (na Wayland xrandr nie działa)

if [ "$XDG_SESSION_TYPE" = "wayland" ]; then
    echo "Wayland: Ustaw mirror w Ustawieniach → Ekran"
    exit 1
fi

# Znajdź podłączone wyjścia (np. HDMI-1, DP-1, eDP-1 - wbudowany)
OUTPUTS=$(xrandr --query | grep " connected" | cut -d' ' -f1)

if [ -z "$OUTPUTS" ]; then
    echo "Brak wykrytych wyświetlaczy"
    exit 1
fi

# Pierwszy = zwykle wbudowany, drugi = zewnętrzny
PRIMARY=$(echo "$OUTPUTS" | head -1)
SECONDARY=$(echo "$OUTPUTS" | sed -n '2p')

if [ -z "$SECONDARY" ]; then
    echo "Podłącz monitor zewnętrzny i uruchom ponownie"
    exit 1
fi

# Pobierz preferowaną rozdzielczość drugiego ekranu (zewnętrznego)
MODE=$(xrandr --query | grep -A1 "^\s*${SECONDARY}" | grep -oP '\d+x\d+' | head -1)
[ -z "$MODE" ] && MODE="1920x1080"

# Tryb mirror - oba ekrany pokazują to samo
xrandr --output "$PRIMARY" --mode "$MODE" --primary 2>/dev/null || xrandr --output "$PRIMARY" --auto --primary
xrandr --output "$SECONDARY" --mode "$MODE" --same-as "$PRIMARY" 2>/dev/null || xrandr --output "$SECONDARY" --same-as "$PRIMARY"

echo "Mirror włączony: $PRIMARY <-> $SECONDARY"
MIRROR_EOF

chmod +x "$MIRROR_SCRIPT"
echo -e "${GREEN}✓ Utworzono skrypt mirror-display.sh w ${INSTALL_DIR}/scripts/${NC}"

# 3b. Ikona – własna SVG (lub z repo jeśli istnieje)
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

# 3c. Launcher start-app-fullscreen.sh – z repo lub utwórz jeśli brak (np. starsza gałąź deploy)
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

msg() { zenity --info --title "$APP_NAME" --text "$1" 2>/dev/null || notify-send "$APP_NAME" "$1" 2>/dev/null || echo "$1"; }
err() { zenity --error --title "$APP_NAME" --text "$1" 2>/dev/null || notify-send "$APP_NAME" "$1" --urgency=critical 2>/dev/null || echo "Błąd: $1"; }

cd "$INSTALL_DIR" || { err "Nie znaleziono katalogu: $INSTALL_DIR"; exit 1; }

if ! systemctl is-active --quiet docker 2>/dev/null; then
    msg "Uruchamiam Dockera..."
    sudo systemctl start docker 2>/dev/null
    sleep 2
fi

ENV_FILE=".env"
ENV_EXAMPLE=""
[ -f ".env.example" ] && ENV_EXAMPLE=".env.example"
[ -f "env.example" ] && [ -z "$ENV_EXAMPLE" ] && ENV_EXAMPLE="env.example"
[ -f "../.env.example" ] && [ -z "$ENV_EXAMPLE" ] && ENV_EXAMPLE="../.env.example"

if [ ! -f "$ENV_FILE" ] && [ -n "$ENV_EXAMPLE" ]; then
    cp "$ENV_EXAMPLE" "$ENV_FILE"
    if command -v zenity &>/dev/null; then
        RESULT=$(zenity --forms --title "$APP_NAME - Konfiguracja" --text "Wpisz klucze API (możesz pominąć i uzupełnić później):" \
            --add-entry "KIE API Key (kie.ai)" --add-entry "OpenRouter API Key (openrouter.ai)" 2>/dev/null)
        if [ -n "$RESULT" ]; then
            KIE=$(echo "$RESULT" | cut -d'|' -f1 | tr -d '\n\r')
            OPENROUTER=$(echo "$RESULT" | cut -d'|' -f2 | tr -d '\n\r')
            [ -n "$KIE" ] && sed -i "s|^KIE_API_KEY=.*|KIE_API_KEY=$KIE|" "$ENV_FILE" 2>/dev/null
            [ -n "$OPENROUTER" ] && sed -i "s|^OPENROUTER_API_KEY=.*|OPENROUTER_API_KEY=$OPENROUTER|" "$ENV_FILE" 2>/dev/null
        fi
    fi
    msg "Konfiguracja zapisana. Możesz edytować $ENV_FILE gdy potrzeba."
fi

HAD_CHANGES=false
if [ -d ".git" ] && [ -f "$DEPLOY_KEY_PATH" ]; then
    export GIT_SSH_COMMAND="ssh -i '$DEPLOY_KEY_PATH' -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes"
    BEFORE=$(git rev-parse HEAD 2>/dev/null || true)
    git fetch origin deploy 2>/dev/null || git fetch origin 2>/dev/null || true
    git pull origin deploy 2>/dev/null || git pull origin main 2>/dev/null || git pull origin master 2>/dev/null || true
    AFTER=$(git rev-parse HEAD 2>/dev/null || true)
    unset GIT_SSH_COMMAND
    [ "$BEFORE" != "$AFTER" ] && HAD_CHANGES=true
fi

cd "$COMPOSE_DIR" || { err "Nie znaleziono docker-compose."; exit 1; }

if [ "$HAD_CHANGES" = true ]; then
    docker compose build 2>/dev/null || sudo docker compose build 2>/dev/null || true
fi

if ! docker compose up -d 2>/dev/null; then
    sudo docker compose up -d 2>/dev/null || { err "Nie można uruchomić Dockera. Zainstaluj: ./install.sh"; exit 1; }
fi

for i in $(seq 1 45); do
    curl -s "$APP_URL" >/dev/null 2>&1 && break
    sleep 2
done

if command -v chromium-browser &>/dev/null; then
    chromium-browser --kiosk "$APP_URL" --noerrdialogs 2>/dev/null &
elif command -v chromium &>/dev/null; then
    chromium --kiosk "$APP_URL" --noerrdialogs 2>/dev/null &
elif command -v google-chrome &>/dev/null; then
    google-chrome --kiosk "$APP_URL" --noerrdialogs 2>/dev/null &
elif command -v firefox &>/dev/null; then
    firefox -kiosk "$APP_URL" 2>/dev/null &
else
    xdg-open "$APP_URL" 2>/dev/null || sensible-browser "$APP_URL" 2>/dev/null || msg "Otwórz w przeglądarce: $APP_URL"
fi
LAUNCHER_EOF
    chmod +x "$LAUNCHER_SCRIPT"
    echo -e "${GREEN}✓ Utworzono start-app-fullscreen.sh${NC}"
else
    chmod +x "$LAUNCHER_SCRIPT"
fi

# Plik PromptMaster.desktop – z repo lub utwórz
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
Comment=Uruchom Prompt Master w przeglądarce (fullscreen)
Exec=${INSTALL_DIR}/scripts/start-app-fullscreen.sh
Icon=${ICON_PATH}
Categories=Application;Development;
Terminal=false
StartupNotify=true
Keywords=prompt;ai;docker;
EOF
fi

cp "$DESKTOP_ENTRY" "${HOME}/Desktop/PromptMaster.desktop"
chmod +x "${HOME}/Desktop/PromptMaster.desktop"
gio set "${HOME}/Desktop/PromptMaster.desktop" metadata::trusted true 2>/dev/null || true
update-desktop-database "${HOME}/.local/share/applications" 2>/dev/null || true

echo -e "${GREEN}✓ PromptMaster.desktop na pulpicie – fullscreen, auto-update przy starcie${NC}"

# 3d. Usługa systemd – start przy logowaniu
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
mkdir -p "$SYSTEMD_USER_DIR"
USER_UID=$(id -u)

cat > "${SYSTEMD_USER_DIR}/prompt-master.service" << EOF
[Unit]
Description=Prompt Master - kiosk fullscreen przy starcie sesji
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
echo -e "${GREEN}✓ Usługa systemd prompt-master – start przy logowaniu do sesji graficznej${NC}"

# 4. Automatyczne uruchomienie mirror przy logowaniu (opcjonalnie)
echo ""
echo "Czy dodać automatyczne mirrorowanie przy logowaniu? (gdy podłączony monitor) [y/N]"
read -r ADD_AUTOSTART

if [[ "$ADD_AUTOSTART" =~ ^[yY] ]]; then
    AUTOSTART_DIR="${HOME}/.config/autostart"
    mkdir -p "$AUTOSTART_DIR"
    cat > "${AUTOSTART_DIR}/mirror-display.desktop" << EOF
[Desktop Entry]
Type=Application
Name=Mirror Display
Exec=${MIRROR_SCRIPT}
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=3
EOF
    echo -e "${GREEN}✓ Mirror będzie uruchamiany przy logowaniu${NC}"
fi

# 5. Uruchomienie aplikacji (Docker Compose)
echo ""
if [ -f "${INSTALL_DIR}/docker-compose.yml" ] || [ -f "${INSTALL_DIR}/backend/docker-compose.yml" ]; then
    COMPOSE_DIR="${INSTALL_DIR}"
    [ -f "${INSTALL_DIR}/docker-compose.yml" ] || COMPOSE_DIR="${INSTALL_DIR}/backend"
    echo "Czy uruchomić aplikację? (docker compose up -d) [y/N]"
    read -r RUN_APP
    if [[ "$RUN_APP" =~ ^[yY] ]]; then
        cd "$COMPOSE_DIR"
        if [ ! -f ".env" ]; then
            if [ -f ".env.example" ]; then cp .env.example .env; echo -e "${YELLOW}Skopiowano .env.example → .env (uzupełnij klucze API!)${NC}"
            elif [ -f "env.example" ]; then cp env.example .env; echo -e "${YELLOW}Skopiowano env.example → .env (uzupełnij klucze API!)${NC}"
            fi
        fi
        if docker compose up -d --build 2>/dev/null; then
            echo -e "${GREEN}✓ Aplikacja uruchomiona${NC}"
        else
            sudo docker compose up -d --build && echo -e "${GREEN}✓ Aplikacja uruchomiona (użyto sudo - wyloguj się aby docker działał bez sudo)${NC}"
        fi
    fi
fi

echo ""
echo -e "${GREEN}=== Instalacja zakończona ===${NC}"
echo "Repo: ${INSTALL_DIR}"
echo ""
echo "Uruchomienie: kliknij 'PromptMaster.desktop' na pulpicie – fullscreen, auto-update"
echo "  (lub uruchomi się automatycznie przy logowaniu – usługa systemd)"
echo ""
echo "Docker: docker compose ps | docker compose logs -f"
echo "Ręczne mirror: ${MIRROR_SCRIPT}"
echo ""
echo "Po zamknięciu klapki z podłączonym monitorem - system dalej działa."
echo "Uruchom ${MIRROR_SCRIPT} aby włączyć tryb lustrzany."
echo ""
echo -e "${YELLOW}Uwaga: Wyloguj się i zaloguj ponownie, żeby docker działał bez sudo.${NC}"
echo "Uwaga: Na Wayland mirror ustaw ręcznie w: Ustawienia → Ekran"
