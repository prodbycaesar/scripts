#!/bin/zsh

#variables
work_dir="/Users/julius/Documents/Homelab/scripts/ansible"
vault_pass="$work_dir/secrets/.vault_pass.txt"
inventory_file="$work_dir/hosts"
ansible_playbook="$work_dir/vm_config.ansible.yml"
log_file="$work_dir/script.log"
ssh_password=$(< "$vault_pass")
domain="caesarlabs.org"

#remote bind9 variables
raspberry_pi="pi.caesarlabs.org"
bind9_container="bind9"
zone_file="/etc/bind/db.caesarlab.cc"

#logging
echo "Script started at $(date)" | tee -a "$log_file"

#validate ips
is_valid_ip() {
    local ip=$1
    echo "Validating IP: '$ip'" | tee -a "$log_file"

    if [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        for octet in $(echo "$ip" | tr '.' ' '); do
            if ((octet < 0 || octet > 255)); then
                echo "Octet $octet is out of range." | tee -a "$log_file"
                return 1
            fi
        done
        echo "IP $ip is valid." | tee -a "$log_file"
        return 0
    fi
    echo "IP $ip does not match regex." | tee -a "$log_file"
    return 1
}

#update bind9 dns
update_bind9_dns() {
    local ip=$1
    local fqdn=$2
    local shortname=${fqdn%%.*}

    echo "Updating bind9 DNS for $shortname ($ip) on Raspberry Pi..." | tee -a "$log_file"

    #add a-entry
    ssh root@"$raspberry_pi" "docker exec $bind9_container bash -c 'echo \"$shortname IN A $ip\" >> $zone_file'"

    #validate entry and reload
    ssh root@"$raspberry_pi" <<EOF
    docker exec $bind9_container bash -c "named-checkzone caesarlabs.org $zone_file"
    docker exec $bind9_container bash -c "rndc reload"
EOF

    if [[ $? -eq 0 ]]; then
        echo "DNS updated successfully for $shortname ($ip)." | tee -a "$log_file"
    else
        echo "Failed to update DNS for $shortname ($ip)." | tee -a "$log_file"
    fi
}

#set hostname and update /etc/hosts
set_remote_hostname() {
    local fqdn=$1
    local shortname=$2
    local ip=$3

    echo "Setting hostname $fqdn on $ip..." | tee -a "$log_file"
    ssh -o StrictHostKeyChecking=no root@"$ip" <<EOF
    hostnamectl set-hostname $fqdn
    sed -i '/127.0.0.1 $fqdn/d' /etc/hosts
    sed -i '/127.0.0.1 $shortname/d' /etc/hosts
    sed -i '/$ip $fqdn/d' /etc/hosts
    echo "$ip $fqdn $shortname" >> /etc/hosts
EOF

    if [[ $? -eq 0 ]]; then
        echo "Hostname $fqdn successfully set on $ip." | tee -a "$log_file"
    else
        echo "Failed to set hostname $fqdn on $ip." | tee -a "$log_file"
    fi
}

#update inventory file
update_inventory() {
    local fqdn=$1
    local ip=$2
    if ! grep -q "^$fqdn ansible_host=$ip$" "$inventory_file"; then
        echo "$fqdn ansible_host=$ip" >>"$inventory_file"
        echo "Added $fqdn ansible_host=$ip to inventory file." | tee -a "$log_file"
    else
        echo "$fqdn ansible_host=$ip already exists in inventory file." | tee -a "$log_file"
    fi
}

#ensure arguments are provided in pairs
if (( $# % 2 != 0 )); then
    echo "Error: Arguments must be provided as pairs of IP and Hostname." | tee -a "$log_file"
    exit 1
fi

#ensure inventory file exists
touch "$inventory_file"

#add ssh keys
add_ssh_key() {
    local ip=$1

    echo "Adding host key for $ip to known_hosts..." | tee -a "$log_file"
    if ! ssh-keyscan -H "$ip" >> ~/.ssh/known_hosts 2>>"$log_file"; then
        echo "Failed to scan host key for $ip. Skipping." | tee -a "$log_file"
        return
    fi

    echo "Adding SSH key to $ip..." | tee -a "$log_file"
    if sshpass -p "$ssh_password" ssh-copy-id root@"$ip" 2>>"$log_file"; then
        echo "SSH key added successfully to $ip." | tee -a "$log_file"
    else
        echo "Failed to add SSH key to $ip. Skipping." | tee -a "$log_file"
    fi
}

#process ip - hostname pair
for ((i = 1; i <= $#; i += 2)); do
    ip=$(echo "${@[$i]}" | xargs)
    hostname=$(echo "${@[$i+1]}" | xargs)
    fqdn="${hostname}.${domain}"

    if is_valid_ip "$ip"; then
        echo "$ip is a valid IP." | tee -a "$log_file"
        set_remote_hostname "$fqdn" "$hostname" "$ip"
        add_ssh_key "$ip"
        update_inventory "$fqdn" "$ip"
        update_bind9_dns "$ip" "$fqdn"
    else
        echo "$ip is not a valid IP. Skipping." | tee -a "$log_file"
    fi
done

#remove duplicate entries from inventory
sort -u "$inventory_file" -o "$inventory_file"
echo "Inventory file cleaned and updated." | tee -a "$log_file"

#insert [linux] prefix if available
if ! grep -q "^\[linux\]$" "$inventory_file"; then
    temp_file=$(mktemp)
    echo -e "[linux]\n" > "$temp_file"
    cat "$inventory_file" >> "$temp_file"
    mv "$temp_file" "$inventory_file"
fi

#execute ansible playbook
echo "Executing Ansible playbook..." | tee -a "$log_file"
if ansible-playbook --vault-password-file "$vault_pass" --ssh-extra-args='-o StrictHostKeyChecking=no' -i "$inventory_file" --forks 10 "$ansible_playbook"; then
    echo "Ansible playbook executed successfully." | tee -a "$log_file"
else
    echo "Ansible playbook execution failed." | tee -a "$log_file"
    exit 1
fi
