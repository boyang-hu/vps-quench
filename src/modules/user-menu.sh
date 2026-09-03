# ── 用户与 SSH 访问管理子菜单 ──────────────────────────────
user_management_menu() {
    while true; do
        local CUR_PORT CUR_PWD CUR_PUBKEY AUTH_LABEL ROOT_LOGIN CHOICE
        CUR_PORT=$(get_config Port)
        CUR_PWD=$(get_config PasswordAuthentication)
        CUR_PUBKEY=$(get_config PubkeyAuthentication)
        ROOT_LOGIN=$(get_config PermitRootLogin)
        if [ "$CUR_PWD" = no ] && [ "$CUR_PUBKEY" = yes ]; then AUTH_LABEL="仅密钥"
        elif [ "$CUR_PWD" = yes ]; then AUTH_LABEL="允许密码"
        else AUTH_LABEL="未确认"; fi

        print_header "用户与 SSH 访问管理"
        status_pair "用户" "$(user_count) · 管理员 $(user_admin_count)" "active" \
                    "SSH" "${CUR_PORT:-22} · $AUTH_LABEL" "active"
        status_pair "root SSH" "${ROOT_LOGIN:-未确认}" "$([ "$ROOT_LOGIN" = no ] && echo active || echo warning)" \
                    "当前用户" "$(user_current_actor)" "active"
        echo ""
        menu_div
        menu_pair "1" "查看用户与权限" "2" "创建用户"
        menu_pair "3" "管理 sudo 权限" "4" "修改/锁定密码"
        menu_pair "5" "管理用户公钥" "6" "删除用户"
        menu_pair "7" "SSH 登录策略" "8" "修改 SSH 端口"
        menu_pair "9" "SSH 状态与检查" "w" "推荐安全向导"
        menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
        menu_div
        echo ""
        read -rp "$(ui_prompt '选择操作 [0-9 / w]: ')" CHOICE

        case "$CHOICE" in
            1) user_show_list; ui_pause ;;
            2) user_create; ui_pause ;;
            3) user_admin_manage; ui_pause ;;
            4) user_password_manage; ui_pause ;;
            5) user_ssh_keys_manage ;;
            6) user_delete; ui_pause ;;
            7) set_login_mode; ui_pause ;;
            8) change_port; ui_pause ;;
            9) ssh_security_status; ui_pause ;;
            w|W) user_recommended_wizard; ui_pause ;;
            0) return ;;
            00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}
