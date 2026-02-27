#!/bin/bash
# =================================================================
# logs.sh — Логи, logrotate, cron автоочистка и SSL обновление
# =================================================================

clearLogs() {
    echo -e "${cyan}Очистка логов...${reset}"
    for f in /var/log/xray/access.log /var/log/xray/error.log \
              /var/log/nginx/access.log /var/log/nginx/error.log \
              /var/log/psiphon/psiphon.log \
              /var/log/tor/notices.log; do
        [ -f "$f" ] && : > "$f"
    done
    journalctl --vacuum-size=100M &>/dev/null
    echo "${green}Логи очищены.${reset}"
}

setupLogrotate() {
    cat > /etc/logrotate.d/xray << 'EOF'
/var/log/xray/*.log {
    daily
    rotate 7
    missingok
    notifempty
    compress
    delaycompress
    dateext
    sharedscripts
    postrotate
        systemctl kill -s USR1 xray 2>/dev/null || true
    endscript
}
EOF
    echo "${green}Авто-ротация логов настроена.${reset}"
}

# SSL автообновление
setupSslCron() {
    cat > /etc/cron.d/acme-renew << 'EOF'
# SSL автообновление — каждые 35 дней в 03:00
0 3 */35 * * root /root/.acme.sh/acme.sh --cron --home /root/.acme.sh --pre-hook "/usr/local/bin/vwn open-80" --post-hook "/usr/local/bin/vwn close-80" >> /var/log/acme_cron.log 2>&1
EOF
    chmod 644 /etc/cron.d/acme-renew
    echo "${green}Автообновление SSL включено.${reset}"
}

removeSslCron() {
    rm -f /etc/cron.d/acme-renew
    echo "${green}Автообновление SSL отключено.${reset}"
}

checkSslCronStatus() {
    [ -f /etc/cron.d/acme-renew ] && echo "${green}ВКЛЮЧЕНО${reset}" || echo "${red}ВЫКЛЮЧЕНО${reset}"
}

manageSslCron() {
    while true; do
        clear
        echo -e "${cyan}=== Управление автообновлением SSL ===${reset}"
        echo -e "Статус: $(checkSslCronStatus)"
        echo ""
        echo -e "${green}1.${reset} Включить"
        echo -e "${green}2.${reset} Выключить"
        echo -e "${green}3.${reset} Показать задачу"
        echo -e "${green}0.${reset} Назад"
        read -rp "Выберите: " choice
        case $choice in
            1) setupSslCron; read -r ;;
            2) removeSslCron; read -r ;;
            3) cat /etc/cron.d/acme-renew 2>/dev/null || echo "Нет задачи"; read -r ;;
            0) break ;;
        esac
    done
}

# Автоочистка логов
setupLogClearCron() {
    cat > /usr/local/bin/clear-logs.sh << 'EOF'
#!/bin/bash
for f in /var/log/xray/access.log /var/log/xray/error.log \
          /var/log/nginx/access.log /var/log/nginx/error.log; do
    [ -f "$f" ] && : > "$f"
done
journalctl --vacuum-size=100M &>/dev/null
EOF
    chmod +x /usr/local/bin/clear-logs.sh

    cat > /etc/cron.d/clear-logs << 'EOF'
# Очистка логов — каждое воскресенье в 04:00
0 4 * * 0 root /usr/local/bin/clear-logs.sh
EOF
    chmod 644 /etc/cron.d/clear-logs
    echo "${green}Автоочистка логов настроена (воскр. 04:00).${reset}"
}

removeLogClearCron() {
    rm -f /etc/cron.d/clear-logs /usr/local/bin/clear-logs.sh
    echo "${green}Автоочистка логов отключена.${reset}"
}

checkLogClearCronStatus() {
    [ -f /etc/cron.d/clear-logs ] && echo "${green}ВКЛЮЧЕНО${reset}" || echo "${red}ВЫКЛЮЧЕНО${reset}"
}

manageLogClearCron() {
    while true; do
        clear
        echo -e "${cyan}=== Управление автоочисткой логов ===${reset}"
        echo -e "Статус: $(checkLogClearCronStatus)"
        echo ""
        echo -e "${green}1.${reset} Включить"
        echo -e "${green}2.${reset} Выключить"
        echo -e "${green}3.${reset} Показать задачу"
        echo -e "${green}0.${reset} Назад"
        read -rp "Выберите: " choice
        case $choice in
            1) setupLogClearCron; read -r ;;
            2) removeLogClearCron; read -r ;;
            3) cat /etc/cron.d/clear-logs 2>/dev/null || echo "Нет задачи"; read -r ;;
            0) break ;;
        esac
    done
}
