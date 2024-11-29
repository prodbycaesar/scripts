#!/bin/zsh

# variables
work_dir="/Users/julius/Documents/Homelab/scripts/ansible"
vault_pass="$work_dir/secrets/.vault_pass.txt"
inventory_file="$work_dir/hosts"
ansible_playbook="$work_dir/vm_config.ansible.yml"
log_file="$work_dir/script.log"
ssh_password=$(< "$vault_pass")
host_addr=("$@")

#logging
echo "script started at $(date)" | tee -a "$log_file"

# validate ips
is_valid_ip() {
    local ip=$1
    if [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        for octet in $(echo "$ip" | tr '.' ' '); do
            if ((octet < 0 || octet > 255)); then
                return 1
            fi
        done
        return 0
    fi
    return 1
}
#check if ips are provided
if [ "${#host_addr[@]}" -eq 0 ]; then
    echo "no ip provided. provide at least one." | tee -a "$log_file"
    exit 1
fi

#ensure inventory file exists
touch "$inventory_file"

#add ssh keys
add_ssh_key() {
    local ip=$1

    # add host key to known_hosts
    echo "adding host key for $ip to known_hosts..." | tee -a "$log_file"
    if ! ssh-keyscan -H "$ip" >> ~/.ssh/known_hosts 2>>"$log_file"; then
        echo "failed to scan host key for $ip. skipping." | tee -a "$log_file"
        return
    fi

    # Add SSH key to remote host
    echo "adding ssh key to $ip..." | tee -a "$log_file"
    if sshpass -p "$ssh_password" ssh-copy-id root@"$ip" 2>>"$log_file"; then
        echo "ssh key added successfully to $ip." | tee -a "$log_file"
    else
        echo "failed to add ssh key to $ip. Skipping." | tee -a "$log_file"
    fi
}

#update inventory file
update_inventory() {
    local ip=$1
    if ! grep -q "^$ip$" "$inventory_file"; then
        echo "$ip" >>"$inventory_file"
        echo "added $ip to inventory file." | tee -a "$log_file"
    else
        echo "$ip already exists in inventory file." | tee -a "$log_file"
    fi
}

#process each ip
for ip in "${host_addr[@]}"; do
    if is_valid_ip "$ip"; then
        echo "$ip is a valid ip." | tee -a "$log_file"
        add_ssh_key "$ip"
        update_inventory "$ip"
    else
        echo "$ip is not a valid ip. skipping." | tee -a "$log_file"
    fi
done

# remove duplicate entries from inventory
sort -u "$inventory_file" -o "$inventory_file"
echo "inventory file cleaned and updated." | tee -a "$log_file"

# execute ansible playbook
echo "executing ansible playbook..." | tee -a "$log_file"
if ansible-playbook --vault-password-file "$vault_pass" --ssh-extra-args='-o StrictHostKeyChecking=no' -i "$inventory_file" --forks 10 "$ansible_playbook"; then
    echo "ansible playbook executed successfully." | tee -a "$log_file"
else
    echo "ansible playbook execution failed." | tee -a "$log_file"
    exit 1
fi