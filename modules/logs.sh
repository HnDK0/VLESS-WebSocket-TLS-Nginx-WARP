#!/bin/bash
# =================================================================
# logs.sh — Логи, logrotate, cron автоочистка и SSL обновление
# =================================================================

# Полный список лог-файлов всех компонентов
_LOG_FILES=(
    /var/log/xray/access.log
    /var/log/xray/error.log
    /var/log/xray/reality-error.log
    /var/log/nginx/access.log
    /var/log/nginx/error.log
    /var/log/psiphon/psiphon.log
    /var/log/tor/notices.log
    /var/log/acme_cron.log
)

clearLogs() {
    echo -e "${cyan}$(msg logs_clearing)${reset}"
    local total_before=0 total_after=0 f size
    for f in "${_LOG_FILES[@]}"; do
        [ -f "$f" ] || continue
        size=$(stat -c%s "$f" 2>/dev/null || echo 0)
        total_before=$((total_before + size))
        : > "$f"
    done
    journalctl --vacuum-size=50M &>/dev/null
    journalctl --vacuum-time=7d &>/dev/null
    total_after=0
    for f in "${_LOG_FILES[@]}"; do
        [ -f "$f" ] || continue
        size=$(stat -c%s "$f" 2>/dev/null || echo 0)
        total_after=$((total_after + size))
    done
    local freed=$(( (total_before - total_after) / 1024 ))
    echo "${green}$(msg logs_cleared) ($(msg logs_freed): ${freed} KB)${reset}"
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
        systemctl kill -s USR1 xray-reality 2>/dev/null || true
    endscript
}

/var/log/nginx/*.log {
    daily
    rotate 7
    missingok
    notifempty
    compress
    delaycompress
    dateext
    sharedscripts
    postrotate
        systemctl reload nginx 2>/dev/null || true
    endscript
}

/var/log/psiphon/*.log
/var/log/tor/*.log {
    weekly
    rotate 4
    missingok
    notifempty
    compress
    delaycompress
}
EOF
    echo "${green}$(msg logrotate_ok)${reset}"
}

# SSL автообновление
setupSslCron() {
    cat > /etc/cron.d/acme-renew << 'EOF'
# SSL автообновление — каждые 35 дней в 03:00
0 3 */35 * * root /root/.acme.sh/acme.sh --cron --home /root/.acme.sh --pre-hook "/usr/local/bin/vwn open-80" --post-hook "/usr/local/bin/vwn close-80" >> /var/log/acme_cron.log 2>&1
EOF
    chmod 644 /etc/cron.d/acme-renew
    echo "${green}$(msg ssl_cron_enabled)${reset}"
}

removeSslCron() {
    rm -f /etc/cron.d/acme-renew
    echo "${green}$(msg ssl_cron_disabled)${reset}"
}

checkSslCronStatus() {
    [ -f /etc/cron.d/acme-renew ] && echo "${green}$(msg enabled)${reset}" || echo "${red}$(msg disabled)${reset}"
}

manageSslCron() {
    while true; do
        clear
        echo -e "${cyan}$(msg ssl_cron_title)${reset}"
        echo -e "$(msg status): $(checkSslCronStatus)"
        echo ""
        echo -e "${green}1.${reset} $(msg cron_enable)"
        echo -e "${green}2.${reset} $(msg cron_disable)"
        echo -e "${green}3.${reset} $(msg cron_show)"
        echo -e "${green}0.${reset} $(msg back)"
        read -rp "$(msg choose)" choice
        case $choice in
            1) setupSslCron; read -r ;;
            2) removeSslCron; read -r ;;
            3) cat /etc/cron.d/acme-renew 2>/dev/null || echo "$(msg cron_no_task)"; read -r ;;
            0) break ;;
        esac
    done
}

# Автоочистка логов
setupLogClearCron() {
    cat > /usr/local/bin/clear-logs.sh << 'EOF'
#!/bin/bash
for f in \
    /var/log/xray/access.log \
    /var/log/xray/error.log \
    /var/log/xray/reality-error.log \
    /var/log/nginx/access.log \
    /var/log/nginx/error.log \
    /var/log/psiphon/psiphon.log \
    /var/log/tor/notices.log \
    /var/log/acme_cron.log; do
    [ -f "$f" ] && : > "$f"
done
journalctl --vacuum-size=50M &>/dev/null
journalctl --vacuum-time=7d &>/dev/null
EOF
    chmod +x /usr/local/bin/clear-logs.sh

    cat > /etc/cron.d/clear-logs << 'EOF'
# Очистка логов — каждое воскресенье в 04:00
0 4 * * 0 root /usr/local/bin/clear-logs.sh
EOF
    chmod 644 /etc/cron.d/clear-logs
    echo "${green}$(msg log_cron_enabled)${reset}"
}

removeLogClearCron() {
    rm -f /etc/cron.d/clear-logs /usr/local/bin/clear-logs.sh
    echo "${green}$(msg log_cron_disabled)${reset}"
}

checkLogClearCronStatus() {
    [ -f /etc/cron.d/clear-logs ] && echo "${green}$(msg enabled)${reset}" || echo "${red}$(msg disabled)${reset}"
}

manageLogClearCron() {
    while true; do
        clear
        echo -e "${cyan}$(msg log_cron_title)${reset}"
        echo -e "$(msg status): $(checkLogClearCronStatus)"
        echo ""
        echo -e "${green}1.${reset} $(msg cron_enable)"
        echo -e "${green}2.${reset} $(msg cron_disable)"
        echo -e "${green}3.${reset} $(msg cron_show)"
        echo -e "${green}0.${reset} $(msg back)"
        read -rp "$(msg choose)" choice
        case $choice in
            1) setupLogClearCron; read -r ;;
            2) removeLogClearCron; read -r ;;
            3) cat /etc/cron.d/clear-logs 2>/dev/null || echo "$(msg cron_no_task)"; read -r ;;
            0) break ;;
        esac
    done
}
