command -v snap >/dev/null 2>&1 || return 0

# update packages
update_list="$(LANG=C snap refresh --list 2>&1)"
if [[ $update_list != "All snaps up to date." ]]; then
    echo $update_list
    echo -n "Refresh snaps? [y/N] "
    if read -q; then
        echo
        _aptu_sudo snap refresh
    else
        echo "\nSkipping refreshing snaps."
    fi
fi
# remove old packages
LANG=C snap list --all | awk '/disabled/{print $1, $3}' |
    while read snapname revision; do
        echo "snap removing $snapname : $revision"
        _aptu_sudo snap remove "$snapname" --revision="$revision"
    done
