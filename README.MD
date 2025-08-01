# Template System

This folder contains the template system for Proxmox VM deployment, including scripts for template creation, instance initialization, and runtime management.

## Folder Structure

```
root/                        # Files to be installed in /DATA/AppData/casaos/apps/yundera
├── .env                     # Environment configuration template
├── compose-template.yml     # Docker Compose template
└── scripts/
    ├── os-init/             # Scripts for instance-specific initialization
    ├── self-check/          # Scripts for runtime monitoring and maintenance
    ├── tools/               # Utility scripts for VM management
    ├── template-init.sh     # Script for creating the Yundera template
    └── self-check-reboot.sh # Script for self-check and reboot
```

## Script Categories

### template-init.sh
Script used to create the template from a base Ubuntu OS installation and prepare the system for Proxmox template conversion.

### self-check-reboot.sh
Script used to perform a self-check of the system and reboot if necessary. This script is designed to run at startup only.

### os-init/
Scripts for one-time initialization specific to each VM instance after cloning from the template.

### self-check/
Scripts designed to run at startup (called by `self-check-reboot.sh`) and periodically for system maintenance (called by `settings-dashboard/src/backend/server/SelfCheck/SelfCheck.ts`).

See `template-setup/root/scripts/self-check/README.md` for more details.

### tools/
Utility scripts for VM diagnostics and management.

## Configuration Files

- **`.env`**: Environment variables specific to each user, used to derive the `compose.yml` from the `compose-template.yml` (customize with domain, credentials, etc.)

## Usage Context

This folder is designed to be:

1. Used during VM template creation (template-init scripts)
2. Deployed to `/DATA/AppData/casaos/apps/yundera` on each VM instance
3. Utilized for ongoing system maintenance and self-healing operations

## Update Process
This folder is intended to evolve after the template is created. 

at runtime, the `self-check` scripts will be updated to ensure the system remains healthy and up-to-date.
here is the main steps
'ensure-template-version.sh', # Ensure the template version is up-to-date by getting the server reference template file
'ensure-user-docker-compose-updated.sh', # Ensure the user's Docker Compose file is updated with the latest template and user .env changes
'ensure-user-compose-pulled.sh', # pull the latest Docker images for the user's Docker Compose file this will use the version defined in the template to ensure it up to date
'ensure-user-compose-stack-up.sh' # Ensure the user's Docker Compose stack is up and running with the latest images and configurations
after that a more detailed self-check will be performed by on of the container in the stack ensuring file integrity and such.

## Update Process

The template system is designed to evolve continuously after initial template creation. Updates ensure that all VM instances remain current with the latest configurations and security patches.

### Update Triggers

The update process is triggered by:
1. **System reboot** - via the reboot script
2. **Periodic self-update** - by the admin container in the Docker stack

### Update Workflow

Both triggers follow the same four-step process:

1. **`self-check/ensure-template-version.sh`**
   Ensuring the template version is current by downloading the latest reference template file from the server.

2. **`self-check/ensure-user-docker-compose-updated.sh`**
   Updates the user's Docker Compose file with the latest template and Incorporates any changes from the user's `.env` file

3. **`self-check/ensure-user-compose-pulled.sh`**
   Pulls the latest Docker images for the user's Docker Compose file and uses version definitions from the template to ensure consistency

4. **`self-check/ensure-user-compose-stack-up.sh`**
   Ensures the user's Docker Compose stack is running and updated by appling latest images and configurations

### Post-Update Verification

After the main update process completes, detailed self-checks are performed by containers within the stack to verify:
- File integrity
- Service health
- Configuration consistency
- System security status

This two-tier approach ensures both infrastructure updates and application-level validation.
